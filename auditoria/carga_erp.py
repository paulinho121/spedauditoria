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


def importa(caminho, quem=None, con=None):
    con = con or db.conecta()
    p, e, probs = payload(caminho, quem)
    r = con.consulta("select importar_erp_extrato(%s::jsonb) as r",
                     (carga_json.como_texto(p),))
    r = r[0]["r"] if isinstance(r, list) else r["r"]
    r = json.loads(r) if isinstance(r, str) else (r or {})
    return ResultadoERP(os.path.basename(caminho), r.get("situacao", "?"),
                        r.get("arquivo_id"), int(r.get("linhas") or 0), e.itens,
                        r.get("cnpj"), r.get("deposito"), probs)
