# -*- coding: utf-8 -*-
"""
Carga de NF-e e geração de movimento do Kardex.

Princípio: na dúvida, NÃO gera movimento. Item que não casou vai para a fila de
pendências; CFOP não classificado bloqueia a linha. Um Kardex com furo visível é
auditável; um Kardex com número inventado, não.

Convenção de sinal em `movimento`:
  soma            +qtd em ind_prop 0
  baixa           -qtd em ind_prop 0
  para_terceiros  -qtd em ind_prop 0  e  +qtd em ind_prop 1  (continua nosso)
  de_terceiros    +qtd em ind_prop 0  e  -qtd em ind_prop 1
  simbolico       nenhuma linha (não move físico)
  fora_escopo     nenhuma linha (não é estoque)
"""
import getpass
import os

from . import db, nfe as pnfe

VERSAO_MOTOR = "0.3.0"


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


def _cfop_efeitos(con):
    return {r["cfop"]: r for r in con.consulta("select * from cfop_efeito")}


def _depara(con, cnpj):
    return {(r["parceiro_doc"] or "", r["c_prod_externo"]): r
            for r in con.consulta("select * from item_depara where cnpj = %s", (cnpj,))}


def _codigos_proprios(con, cnpj):
    return {r["cod_item"] for r in con.consulta(
        "select distinct cod_item from sped_item where cnpj_estab = %s", (cnpj,))}


def importa(caminho, quem=None, con=None, cache=None):
    con = con or db.conecta()
    quem = quem or os.environ.get("AUDITOR") or getpass.getuser()
    nome = os.path.basename(caminho)

    try:
        d = pnfe.parse(caminho)
    except Exception as e:
        return ResultadoNFe(nome, "ignorado", avisos=[f"{type(e).__name__}: {e}"])

    if len(d.chave) != 44:
        return ResultadoNFe(nome, "ignorado", avisos=["chave de acesso inválida"])

    cache = cache if cache is not None else {}
    if "cnpjs" not in cache:
        cache["cnpjs"] = nossos_cnpjs(con)
        cache["cfop"] = _cfop_efeitos(con)
        cache["depara"] = {}
        cache["proprios"] = {}
    nossos = cache["cnpjs"]

    envolvidos = d.sentido_para_algum(nossos)
    if not envolvidos:
        return ResultadoNFe(nome, "fora_do_grupo", d.chave,
                            avisos=[f"emit {d.emit_cnpj} → dest {d.dest_doc or '(sem)'} "
                                    f"— nenhum é estabelecimento auditado"])

    ja = con.consulta("select id, sha256 from nfe where chave = %s", (d.chave,))
    if ja:
        if ja[0]["sha256"] == d.sha256:
            return ResultadoNFe(nome, "ja_importada", d.chave, ja[0]["id"])
        return ResultadoNFe(nome, "conflito", d.chave, ja[0]["id"],
                            avisos=["mesma chave com conteúdo diferente do já importado"])

    avisos = [f"{t}: {m}" for t, m in pnfe.confere(d, nossos)]

    r = con.consulta(
        "insert into nfe (chave, sha256, nome_arquivo, modelo, serie, num_nf, dh_emi, "
        " dt_emi, tp_nf, fin_nfe, nat_op, emit_cnpj, emit_nome, emit_uf, dest_doc, "
        " dest_nome, dest_uf, vl_nf, vl_prod, situacao, importado_por, versao_motor) "
        "values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) "
        "returning id",
        (d.chave, d.sha256, nome, d.modelo, d.serie, d.num_nf, d.dh_emi, d.dt_emi,
         d.tp_nf, d.fin_nfe, d.nat_op, d.emit_cnpj, d.emit_nome, d.emit_uf,
         d.dest_doc, d.dest_nome, d.dest_uf, d.vl_nf, d.vl_prod, d.situacao,
         quem, VERSAO_MOTOR))
    nfe_id = r[0]["id"]

    ids_item = {}
    for it in d.itens:
        ri = con.consulta(
            "insert into nfe_item (nfe_id, n_item, c_prod, c_ean, x_prod, x_prod_norm, "
            " ncm, cest, cfop, u_com, q_com, v_un_com, v_prod, u_trib, q_trib, v_desc, "
            " v_frete, v_seg, v_outro, ind_tot, cst_icms) "
            "values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) "
            "returning id",
            (nfe_id, it.n_item, it.c_prod, it.c_ean, it.x_prod, it.x_prod_norm, it.ncm,
             it.cest, it.cfop, it.u_com, it.q_com, it.v_un_com, it.v_prod, it.u_trib,
             it.q_trib, it.v_desc, it.v_frete, it.v_seg, it.v_outro, it.ind_tot,
             it.cst_icms))
        ids_item[it.n_item] = ri[0]["id"]

    if d.situacao != "autorizada":
        return ResultadoNFe(nome, "importada_sem_movimento", d.chave, nfe_id,
                            avisos=avisos + [f"situação {d.situacao}: não gera movimento"])

    movs = pend = 0
    for cnpj in envolvidos:
        for sentido in d.sentido_para(cnpj):
            parceiro = d.dest_doc if sentido == "saida" else d.emit_cnpj
            if cnpj not in cache["depara"]:
                cache["depara"][cnpj] = _depara(con, cnpj)
                cache["proprios"][cnpj] = _codigos_proprios(con, cnpj)
            depara = cache["depara"][cnpj]
            proprios = cache["proprios"][cnpj]

            for it in d.itens:
                efeito = cache["cfop"].get(it.cfop)
                if efeito is None:
                    avisos.append(f"CFOP {it.cfop} não classificado — item {it.n_item} "
                                  f"não gerou movimento")
                    continue

                cod_item, fator = None, 1
                if sentido == "saida":
                    # Nota emitida por nós: o cProd É o nosso código, por definição.
                    # Não exigir presença no cadastro 0200 do momento zero — o
                    # cadastro evolui, e um item criado depois de 31/12/2022 seria
                    # rejeitado indevidamente.
                    cod_item = it.c_prod
                    if it.c_prod not in proprios:
                        avisos.append(f"item {it.n_item}: código {it.c_prod} não existe "
                                      f"no cadastro de {cnpj} do momento zero (item novo)")
                else:
                    # Entrada: o cProd é de quem emitiu. Mesmo vindo de filial nossa,
                    # os códigos colidem entre estabelecimentos e exigem de-para.
                    achado = depara.get((parceiro or "", it.c_prod)) or \
                             depara.get(("", it.c_prod))
                    if achado:
                        cod_item, fator = achado["cod_item"], float(achado["fator_unidade"])

                if not cod_item:
                    con.executa(
                        "insert into item_pendente (cnpj, parceiro_doc, parceiro_nome, "
                        " c_prod_externo, x_prod, ncm, u_com, ocorrencias, qtd_total, "
                        " vl_total, primeira_chave) "
                        "values (%s,%s,%s,%s,%s,%s,%s,1,%s,%s,%s) "
                        "on conflict (cnpj, parceiro_doc, c_prod_externo) do update set "
                        " ocorrencias = item_pendente.ocorrencias + 1, "
                        " qtd_total = coalesce(item_pendente.qtd_total,0) + excluded.qtd_total, "
                        " vl_total = coalesce(item_pendente.vl_total,0) + excluded.vl_total",
                        (cnpj, parceiro, d.emit_nome if sentido == "entrada" else d.dest_nome,
                         it.c_prod, it.x_prod, it.ncm, it.u_com, it.q_com, it.v_prod, d.chave))
                    pend += 1
                    continue

                qtd = float(it.q_com or 0) * fator
                if qtd <= 0:
                    continue
                vu = float(it.v_prod or 0) / qtd if qtd else 0

                linhas = []
                e = efeito["efeito"]
                if e == "soma":
                    linhas = [(qtd, "0")]
                elif e == "baixa":
                    linhas = [(-qtd, "0")]
                elif e == "para_terceiros":
                    linhas = [(-qtd, "0"), (qtd, "1")]
                elif e == "de_terceiros":
                    linhas = [(qtd, "0"), (-qtd, "1")]
                # simbolico e fora_escopo não geram linha

                for q, prop in linhas:
                    con.executa(
                        "insert into movimento (cnpj, dt, cod_item, origem, nfe_id, "
                        " nfe_item_id, chave, n_item, cfop, efeito, qtd, vl_unit, "
                        " vl_total, ind_prop, observacao) "
                        "values (%s,%s,%s,'nfe',%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                        (cnpj, d.dt_emi, cod_item, nfe_id, ids_item[it.n_item], d.chave,
                         it.n_item, it.cfop, e, q, vu, abs(q) * vu, prop,
                         f"{sentido} · {efeito['descricao'][:60]}"))
                    movs += 1

    return ResultadoNFe(nome, "importada", d.chave, nfe_id, movs, pend, avisos)


def importa_pasta(pasta, quem=None, limite=None, progresso=None):
    """Varre recursivamente. Devolve lista de ResultadoNFe."""
    con = db.conecta()
    cache = {}
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
        r = importa(a, quem=quem, con=con, cache=cache)
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
