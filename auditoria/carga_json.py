# -*- coding: utf-8 -*-
"""
Importação em uma chamada: o arquivo é parseado aqui e gravado pelo banco.

A carga original faz ~220 chamadas por EFD — uma por lote de cada registro e
duas por documento fiscal. Na máquina local isso custa minutos; numa função
serverless, que morre em 10 a 60 segundos, é inviável.

Aqui o parser continua sendo o mesmo (puro, com teste golden) e o resultado vai
inteiro num JSON para `importar_efd` / `importar_nfe`, que gravam dentro de uma
transação. De ~220 chamadas para 1 — e a atomicidade deixa de depender do
backend, porque a transação passou a ser do lado do banco.
"""
import getpass
import json
import os
from datetime import date, datetime
from decimal import Decimal

from . import nfe as pnfe, sped

VERSAO_MOTOR = "0.5.0"


def _json(v):
    """Decimal e date não são serializáveis por padrão; texto preserva a escala."""
    if isinstance(v, Decimal):
        return str(v)
    if isinstance(v, (date, datetime)):
        return v.isoformat()
    raise TypeError(f"não sei serializar {type(v).__name__}")


def payload_efd(caminho, quem=None):
    """Monta o JSON de um EFD a partir do parser."""
    efd = sped.parse(caminho)
    if not efd.cnpj:
        raise ValueError(f"{efd.nome_arquivo}: registro 0000 ausente — "
                         f"não parece um EFD ICMS/IPI.")
    quem = quem or os.environ.get("AUDITOR") or getpass.getuser()
    problemas = sped.confere(efd)

    return {
        "arquivo": {
            "nome_arquivo": efd.nome_arquivo, "cnpj": efd.cnpj,
            "nome_empresa": efd.nome_empresa, "uf": efd.uf, "ie": efd.ie,
            "dt_ini": efd.dt_ini, "dt_fin": efd.dt_fin, "cod_fin": efd.cod_fin,
            "cod_ver": efd.cod_ver, "ind_perfil": efd.ind_perfil,
            "ind_ativ": efd.ind_ativ, "sha256": efd.sha256,
            "importado_por": quem, "linhas_lidas": efd.linhas_lidas,
            "contagem": efd.contagem, "versao_motor": VERSAO_MOTOR,
            "problemas": [{"tipo": t, "detalhe": d} for t, d in problemas],
        },
        "unidades": efd.unidades,
        "participantes": efd.participantes,
        "itens": efd.itens,
        "inventario": efd.inventario,
        "inventario_itens": efd.inventario_itens,
        "documentos": efd.documentos,
    }, problemas


def payload_nfe(caminho, quem=None):
    d = pnfe.parse(caminho)
    if len(d.chave) != 44:
        raise ValueError(f"{d.nome_arquivo}: chave de acesso inválida")
    quem = quem or os.environ.get("AUDITOR") or getpass.getuser()
    return {
        "chave": d.chave, "sha256": d.sha256, "nome_arquivo": d.nome_arquivo,
        "modelo": d.modelo, "serie": d.serie, "num_nf": d.num_nf,
        "dh_emi": d.dh_emi, "dt_emi": d.dt_emi, "tp_nf": d.tp_nf,
        "fin_nfe": d.fin_nfe, "nat_op": d.nat_op,
        "emit_cnpj": d.emit_cnpj, "emit_nome": d.emit_nome, "emit_uf": d.emit_uf,
        "dest_doc": d.dest_doc, "dest_nome": d.dest_nome, "dest_uf": d.dest_uf,
        "vl_nf": d.vl_nf, "vl_prod": d.vl_prod, "situacao": d.situacao,
        "importado_por": quem, "versao_motor": VERSAO_MOTOR,
        "itens": [vars(i) for i in d.itens],
    }, pnfe.confere(d)


def como_texto(p):
    """JSON pronto para ir no corpo da chamada."""
    return json.dumps(p, default=_json, ensure_ascii=False)
