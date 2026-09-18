# -*- coding: utf-8 -*-
"""
Importação da ECD, numa chamada ao banco (importar_ecd), dentro de uma
transação. Reimportar o mesmo arquivo não faz nada; uma retificadora do mesmo
período passa a valer e a anterior fica guardada.
"""
import getpass
import json
import os

from . import carga_json, db, ecd as pecd


class ResultadoEcd:
    def __init__(self, arquivo, situacao, arquivo_id=None, contas=0, saldos=0, problemas=None):
        self.arquivo = arquivo
        self.situacao = situacao
        self.arquivo_id = arquivo_id
        self.contas = contas
        self.saldos = saldos
        self.problemas = problemas or []


def payload(caminho, quem=None):
    e = pecd.parse(caminho)
    probs = pecd.confere(e)
    quem = quem or os.environ.get("AUDITOR") or getpass.getuser()
    return {
        "arquivo": {"cnpj": e.cnpj, "nome": e.nome, "uf": e.uf, "dt_ini": e.dt_ini,
                    "dt_fin": e.dt_fin, "ind_fin_esc": e.ind_fin_esc,
                    "nome_arquivo": e.nome_arquivo, "sha256": e.sha256,
                    "linhas": e.linhas_lidas, "lancamentos": e.lancamentos,
                    "problemas": [{"tipo": t, "detalhe": d} for t, d in probs],
                    "importado_por": quem},
        "contas": e.contas, "saldos": e.saldos, "encerramento": e.encerramento,
    }, probs


def importa(caminho, quem=None, con=None):
    con = con or db.conecta()
    p, probs = payload(caminho, quem)
    r = con.consulta("select importar_ecd(%s::jsonb) as r", (carga_json.como_texto(p),))
    r = r[0]["r"] if isinstance(r, list) else r["r"]
    r = json.loads(r) if isinstance(r, str) else (r or {})
    return ResultadoEcd(os.path.basename(caminho), r.get("situacao", "?"),
                        r.get("arquivo_id"), int(r.get("contas") or 0),
                        int(r.get("saldos") or 0), probs)
