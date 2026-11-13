# -*- coding: utf-8 -*-
"""
Importação do extrato de estoque do ERP, numa chamada ao banco
(importar_erp_extrato), dentro de uma transação.

Reimportar o mesmo arquivo não faz nada. Um extrato novo do mesmo depósito e
período substitui o anterior, que fica guardado — o cliente reemite o relatório
depois de corrigir um lançamento, e a auditoria precisa poder mostrar as duas
versões.
"""
import getpass
import json
import os

from . import carga_json, db, erp as perp


class ResultadoERP:
    def __init__(self, arquivo, situacao, arquivo_id=None, linhas=0, itens=0,
                 cnpj=None, deposito=None, problemas=None):
        self.arquivo = arquivo
        self.situacao = situacao
        self.arquivo_id = arquivo_id
        self.linhas = linhas
        self.itens = itens
        self.cnpj = cnpj
        self.deposito = deposito
        self.problemas = problemas or []

    def dict(self):
        return {"arquivo": self.arquivo, "situacao": self.situacao,
                "arquivo_id": self.arquivo_id, "linhas": self.linhas,
                "itens": self.itens, "cnpj": self.cnpj, "deposito": self.deposito,
                "avisos": [f"{t}: {d}" for t, d in self.problemas]}


def payload(caminho, quem=None):
    e = perp.parse(caminho)
    probs = list(e.problemas) + perp.confere(e)
    quem = quem or os.environ.get("AUDITOR") or getpass.getuser()
    return {
        "arquivo": {
            "nome_arquivo": e.nome_arquivo, "sha256": e.sha256,
            # Vários depósitos num arquivo só é raro; o primeiro nomeia o
            # arquivo e cada linha guarda o seu.
            "deposito": e.depositos[0] if e.depositos else None,
            "dt_ini": e.dt_ini, "dt_fin": e.dt_fin,
            "linhas": len(e.linhas), "itens": e.itens,
            "movimentos": e.movimentos, "aberturas": e.aberturas,
            "problemas": [{"tipo": t, "detalhe": d} for t, d in probs],
            "importado_por": quem,
        },
        "linhas": e.linhas,
    }, e, probs


# Acima disto o extrato vai em partes: uma chamada só não comporta o extrato de
# anos de um depósito (vinte mil linhas, doze megabytes).
LOTE = 2500


def partes(p, lote=LOTE):
    """
    Fatia o payload para importar_erp_extrato_parte. Cada fatia leva o
    cabeçalho do arquivo com 'parte' e 'partes'; a última é a que publica.
    """
    linhas = p["linhas"]
    n = max(1, -(-len(linhas) // lote))
    for i in range(n):
        cab = dict(p["arquivo"], parte=i + 1, partes=n)
        if i:
            # Os avisos vão uma vez só; o banco soma os de cada parte.
            cab["problemas"] = []
        yield {"arquivo": cab, "linhas": linhas[i * lote:(i + 1) * lote]}


def payload_parte(caminho, meta, quem=None):
    """
    Uma fatia do extrato cortada pelo NAVEGADOR (o arquivo inteiro não passa
    pelo limite de envio da versão web). O arquivo em disco é só a fatia;
    'meta' diz de que arquivo ela é e onde ela começa:

        {"sha256": do arquivo inteiro, "parte": 2, "partes": 9,
         "total": linhas do arquivo inteiro, "inicio": linhas antes desta fatia}

    A fatia começa sempre na troca de produto, então conferir o saldo corrido
    dentro dela é o mesmo que conferir no arquivo inteiro.
    """
    e = perp.parse(caminho)
    probs = list(e.problemas) + perp.confere(e)
    inicio = int(meta.get("inicio") or 0)
    for l in e.linhas:
        l["seq"] += inicio
    quem = quem or os.environ.get("AUDITOR") or getpass.getuser()
    return {
        "arquivo": {
            "nome_arquivo": e.nome_arquivo, "sha256": str(meta["sha256"]),
            "deposito": e.depositos[0] if e.depositos else None,
            # Período e contagens o banco calcula na última parte.
            "linhas": int(meta["total"]),
            "parte": int(meta["parte"]), "partes": int(meta["partes"]),
            "problemas": [{"tipo": t, "detalhe": d} for t, d in probs],
            "importado_por": quem,
        },
        "linhas": e.linhas,
    }, e, probs


def importa_parte(caminho, meta, quem=None, con=None):
    con = con or db.conecta()
    p, e, probs = payload_parte(caminho, meta, quem)
    r = _resposta(con.consulta("select importar_erp_extrato_parte(%s::jsonb) as r",
                               (carga_json.como_texto(p),)))
    return ResultadoERP(os.path.basename(caminho), r.get("situacao", "?"),
                        r.get("arquivo_id"), int(r.get("linhas") or 0), e.itens,
                        r.get("cnpj"), r.get("deposito"), probs), r


def _resposta(r):
    r = r[0]["r"] if isinstance(r, list) else r["r"]
    return json.loads(r) if isinstance(r, str) else (r or {})


def importa(caminho, quem=None, con=None):
    con = con or db.conecta()
    p, e, probs = payload(caminho, quem)
    if len(p["linhas"]) > LOTE:
        r = {}
        for parte in partes(p):
            r = _resposta(con.consulta(
                "select importar_erp_extrato_parte(%s::jsonb) as r",
                (carga_json.como_texto(parte),)))
            if r.get("situacao") == "ja_importado":
                break
    else:
        r = _resposta(con.consulta("select importar_erp_extrato(%s::jsonb) as r",
                                   (carga_json.como_texto(p),)))
    return ResultadoERP(os.path.basename(caminho), r.get("situacao", "?"),
                        r.get("arquivo_id"), int(r.get("linhas") or 0), e.itens,
                        r.get("cnpj"), r.get("deposito"), probs)


class ResultadoSaldo:
    def __init__(self, arquivo, situacao, arquivo_id=None, linhas=0, itens=0,
                 cnpj=None, deposito=None, dt=None, problemas=None):
        self.arquivo = arquivo
        self.situacao = situacao
        self.arquivo_id = arquivo_id
        self.linhas = linhas
        self.itens = itens
        self.cnpj = cnpj
        self.deposito = deposito
        self.dt = dt
        self.problemas = problemas or []

    def dict(self):
        return {"arquivo": self.arquivo, "situacao": self.situacao,
                "arquivo_id": self.arquivo_id, "linhas": self.linhas,
                "itens": self.itens, "cnpj": self.cnpj, "deposito": self.deposito,
                "dt": self.dt, "avisos": [f"{t}: {d}" for t, d in self.problemas]}


def payload_saldo(caminho, quem=None, data=None):
    from . import saldo_erp
    s = saldo_erp.parse(caminho, data)
    quem = quem or os.environ.get("AUDITOR") or getpass.getuser()
    return {
        "arquivo": {
            "nome_arquivo": s.nome_arquivo, "sha256": s.sha256,
            "deposito": s.depositos[0] if s.depositos else None,
            "dt": s.data, "linhas": len(s.linhas), "itens": s.itens,
            "quantidade": s.quantidade,
            "problemas": [{"tipo": t, "detalhe": d} for t, d in s.problemas],
            "importado_por": quem,
        },
        "linhas": s.linhas,
    }, s


def importa_saldo(caminho, quem=None, con=None, data=None):
    """Foto do saldo do ERP: posição declarada, não movimento."""
    con = con or db.conecta()
    p, s = payload_saldo(caminho, quem, data)
    r = con.consulta("select importar_erp_saldo(%s::jsonb) as r",
                     (carga_json.como_texto(p),))
    r = r[0]["r"] if isinstance(r, list) else r["r"]
    r = json.loads(r) if isinstance(r, str) else (r or {})
    return ResultadoSaldo(os.path.basename(caminho), r.get("situacao", "?"),
                          r.get("arquivo_id"), int(r.get("linhas") or 0), s.itens,
                          r.get("cnpj"), r.get("deposito"), r.get("dt"), s.problemas)
