# -*- coding: utf-8 -*-
"""
Carga de NF-e e geração de movimento do Kardex.

Princípio: na dúvida, NÃO gera movimento. Item que não casou vai para a fila de
pendências; CFOP não classificado bloqueia a linha. Um Kardex com furo visível é
auditável; um Kardex com número inventado, não.

Este módulo é só a porta de entrada do servidor local e da linha de comando. A
gravação é toda do banco, em `importar_nfe` e `registrar_evento`, uma chamada
por arquivo e dentro de uma transação — o mesmo caminho do Vercel.

Até a versão 0.3 a gravação era feita daqui, uma chamada por item e por
movimento. Três problemas, que só apareceram com uso real:

  · sem transação: o servidor local reinicia quando o código muda, e uma nota
    interrompida no meio ficava com parte dos itens — e a próxima importação a
    pulava como "já importada";
  · lento: uma pasta de 249 notas levava mais de uma hora;
  · duplicado: a mesma regra existia aqui e no banco, e uma correção feita num
    lado só fazia os dois caminhos darem estoques diferentes para a mesma nota.

Convenção de sinal em `movimento`:
  soma            +qtd em ind_prop 0
  baixa           -qtd em ind_prop 0
  para_terceiros  -qtd em ind_prop 0  e  +qtd em ind_prop 1  (continua nosso)
  de_terceiros    +qtd em ind_prop 0  e  -qtd em ind_prop 1
  simbolico       nenhuma linha (não move físico)
  fora_escopo     nenhuma linha (não é estoque)
"""
import getpass
import json
import os

from . import carga_json, db, nfe as pnfe


def nossos_cnpjs(con=None):
    con = con or db.conecta()
    return {r["cnpj"] for r in con.consulta("select cnpj from estabelecimento")}


class ResultadoNFe:
    def __init__(self, arquivo, situacao, chave=None, nfe_id=None,
                 movimentos=0, pendencias=0, avisos=None):
        self.arquivo = arquivo
        self.situacao = situacao
        self.chave = chave
        self.nfe_id = nfe_id
        self.movimentos = movimentos
        self.pendencias = pendencias
        self.avisos = avisos or []

    def dict(self):
        return {"arquivo": self.arquivo, "situacao": self.situacao, "chave": self.chave,
                "nfe_id": self.nfe_id, "movimentos": self.movimentos,
                "pendencias": self.pendencias, "avisos": self.avisos}


def _chama(con, funcao, payload):
    """Uma função do banco com o JSON do arquivo. Devolve o jsonb como dict."""
    r = con.consulta(f"select {funcao}(%s::jsonb) as r", (carga_json.como_texto(payload),))
    r = r[0]["r"] if isinstance(r, list) else r["r"]
    return json.loads(r) if isinstance(r, str) else (r or {})


def importa_evento(caminho, quem, con):
    """Cancelamento avulso (-can.xml). A regra de efeito vive no banco."""
    nome = os.path.basename(caminho)
    try:
        payload, ev = carga_json.payload_evento(caminho, quem)
    except Exception as e:
        return ResultadoNFe(nome, "ignorado", avisos=[f"{type(e).__name__}: {e}"])
    r = _chama(con, "registrar_evento", payload)
    avisos = []
    if r.get("situacao") == "nota_cancelada":
        avisos.append(f"NF {r.get('num_nf')} cancelada: "
                      f"{r.get('movimentos_removidos')} movimento(s) removido(s)")
    elif r.get("situacao") == "cancelamento_guardado":
        avisos.append("a nota ainda não foi importada; quando for, já entra cancelada")
    elif r.get("situacao") == "evento_sem_efeito":
        avisos.append(f"evento não cancela: retorno da SEFAZ cStat {ev.c_stat or '(sem retorno)'}")
    return ResultadoNFe(nome, r.get("situacao", "evento"), ev.chave, r.get("nfe_id"),
                        avisos=avisos)


def importa(caminho, quem=None, con=None, cache=None):
    """
    Importa um XML: nota ou evento. `cache` fica na assinatura por
    compatibilidade com quem chama; o banco não precisa mais dele.
    """
    con = con or db.conecta()
    quem = quem or os.environ.get("AUDITOR") or getpass.getuser()
    nome = os.path.basename(caminho)

    try:
        if pnfe.e_evento(caminho):
            return importa_evento(caminho, quem, con)
        payload, probs = carga_json.payload_nfe(caminho, quem)
    except Exception as e:
        return ResultadoNFe(nome, "ignorado", avisos=[f"{type(e).__name__}: {e}"])

    avisos = [f"{t}: {m}" for t, m in probs]
    r = _chama(con, "importar_nfe", payload)
    situacao = r.get("situacao", "?")
    movs = int(r.get("movimentos") or 0)

    if situacao == "fora_do_grupo":
        avisos.append(f"emit {payload['emit_cnpj']} → dest {payload['dest_doc'] or '(sem)'} "
                      f"— nenhum é estabelecimento auditado")
    elif situacao == "conflito":
        avisos.append("mesma chave com conteúdo DIFERENTE do já importado — "
                      "campo a campo, não só o arquivo")
    elif situacao == "ja_importada" and r.get("outro_arquivo"):
        avisos.append("mesma nota, já importada de outro arquivo")
    elif situacao == "importada" and movs == 0 and r.get("nfe_id"):
        # A situação que vale é a do banco: um cancelamento importado antes da
        # nota a faz nascer cancelada, embora o XML diga "autorizada".
        s = con.consulta("select situacao from nfe where id = %s", (r["nfe_id"],))
        s = s[0]["situacao"] if s else None
        if s and s != "autorizada":
            situacao = "importada_sem_movimento"
            avisos.append("cancelada por evento já registrado" if s != payload["situacao"]
                          else f"situação {s}: não gera movimento")

    auto = int(r.get("automaticos") or 0)
    if auto:
        avisos.append(f"{auto} item(ns) de transferência interna casado(s) pelo "
                      f"código do emitente — de-para automático, revisável")

    return ResultadoNFe(nome, situacao, payload["chave"], r.get("nfe_id"),
                        movs, int(r.get("pendencias") or 0), avisos)


def importa_pasta(pasta, quem=None, limite=None, progresso=None):
    """Varre recursivamente. Devolve lista de ResultadoNFe."""
    con = db.conecta()
    arquivos = []
    for raiz, _, nomes in os.walk(pasta):
        for n in nomes:
            if n.lower().endswith(".xml"):
                arquivos.append(os.path.join(raiz, n))
    arquivos.sort()
    if limite:
        arquivos = arquivos[:limite]

    out = []
    for i, a in enumerate(arquivos, 1):
        r = importa(a, quem=quem, con=con)
        out.append(r)
        if progresso:
            progresso(i, len(arquivos), r)
    return out


def resumo(resultados):
    from collections import Counter
    c = Counter(r.situacao for r in resultados)
    return {
        "total": len(resultados),
        "por_situacao": dict(c),
        "movimentos": sum(r.movimentos for r in resultados),
        "pendencias": sum(r.pendencias for r in resultados),
    }
