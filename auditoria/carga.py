# -*- coding: utf-8 -*-
"""
Importação de arquivos EFD.

Garantias:
  · Idempotente — reimportar o mesmo arquivo (mesmo SHA-256) não faz nada.
  · Não destrutiva — nunca apaga. Retificadora vira nova versão e marca a
    anterior como não vigente, preservando o diff original × substituto.
  · Atômica — o arquivo inteiro entra ou nada dele entra.
  · Rastreável — toda linha guarda arquivo_id e a linha física de origem.
"""
import getpass
import json
import os

from . import db, sped

VERSAO_MOTOR = "0.2.0"
LOTE = 500


class Resultado:
    def __init__(self, arquivo, situacao, arquivo_id=None, contagens=None, problemas=None):
        self.arquivo = arquivo
        self.situacao = situacao          # importado | ja_importado | substituiu
        self.arquivo_id = arquivo_id
        self.contagens = contagens or {}
        self.problemas = problemas or []

    def __repr__(self):
        return f"<{self.situacao} {self.arquivo} id={self.arquivo_id}>"


def _insere_lote(cur, tabela, colunas, linhas):
    if not linhas:
        return 0
    marcas = "(" + ",".join(["%s"] * len(colunas)) + ")"
    sql = f"insert into {tabela} ({','.join(colunas)}) values {marcas}"
    total = 0
    for i in range(0, len(linhas), LOTE):
        parte = linhas[i:i + LOTE]
        cur.executa_varios(sql, parte)
        total += len(parte)
    return total


def importa(caminho, quem=None):
    """Importa um EFD. Devolve Resultado."""
    efd = sped.parse(caminho)
    if not efd.cnpj:
        raise ValueError(f"{os.path.basename(caminho)}: registro 0000 ausente — "
                         f"não parece um EFD ICMS/IPI.")

    quem = quem or os.environ.get("AUDITOR") or getpass.getuser()
    con = db.conecta()
    if not con.transacional:
        print("  AVISO: sem DATABASE_URL, a carga roda sem transação. "
              "Uma falha no meio deixa dados parciais deste arquivo.")

    ja = con.consulta("select id, nome_arquivo, importado_em from sped_arquivo "
                      "where sha256 = %s", (efd.sha256,))
    if ja:
        return Resultado(efd.nome_arquivo, "ja_importado", ja[0]["id"])

    problemas = sped.confere(efd)

    with con.transacao() as cur:
        cur.executa(
            "insert into estabelecimento (cnpj, nome, uf, ie) values (%s,%s,%s,%s) "
            "on conflict (cnpj) do update set nome = excluded.nome, "
            "uf = excluded.uf, ie = excluded.ie",
            (efd.cnpj, efd.nome_empresa, efd.uf, efd.ie))

        # Versões anteriores do mesmo período deixam de ser vigentes.
        anteriores = cur.consulta(
            "select id from sped_arquivo where cnpj = %s and dt_ini = %s "
            "and dt_fin = %s and vigente",
            (efd.cnpj, efd.dt_ini, efd.dt_fin))

        r = cur.consulta(
            "insert into sped_arquivo (nome_arquivo, cnpj, nome_empresa, uf, ie, "
            " dt_ini, dt_fin, cod_fin, cod_ver, ind_perfil, ind_ativ, sha256, "
            " importado_por, linhas_lidas, contagem_reg, problemas, versao_motor) "
            "values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) returning id",
            (efd.nome_arquivo, efd.cnpj, efd.nome_empresa, efd.uf, efd.ie,
             efd.dt_ini, efd.dt_fin, efd.cod_fin, efd.cod_ver, efd.ind_perfil,
             efd.ind_ativ, efd.sha256, quem, efd.linhas_lidas,
             json.dumps(efd.contagem), json.dumps([{"tipo": t, "detalhe": d}
                                                   for t, d in problemas]),
             VERSAO_MOTOR))
        aid = r[0]["id"]

        for a in anteriores:
            cur.executa("update sped_arquivo set vigente = false, substituido_por = %s "
                        "where id = %s", (aid, a["id"]))

        cont = {}
        cont["0190"] = _insere_lote(
            cur, "sped_unidade", ["arquivo_id", "cnpj", "unid", "descr", "linha_arquivo"],
            [(aid, efd.cnpj, u["unid"], u["descr"], u["linha"]) for u in efd.unidades])

        cont["0150"] = _insere_lote(
            cur, "sped_participante",
            ["arquivo_id", "cnpj_estab", "cod_part", "nome", "cod_pais", "cnpj",
             "cpf", "ie", "cod_mun", "linha_arquivo"],
            [(aid, efd.cnpj, p["cod_part"], p["nome"], p["cod_pais"], p["cnpj"],
              p["cpf"], p["ie"], p["cod_mun"], p["linha"]) for p in efd.participantes])

        cont["0200"] = _insere_lote(
            cur, "sped_item",
            ["arquivo_id", "cnpj_estab", "cod_item", "descr_item", "descr_norm",
             "cod_barra", "unid_inv", "tipo_item", "ncm", "ex_ipi", "cod_gen",
             "cod_lst", "aliq_icms", "cest", "linha_arquivo"],
            [(aid, efd.cnpj, i["cod_item"], i["descr_item"], i["descr_norm"],
              i["cod_barra"], i["unid_inv"], i["tipo_item"], i["ncm"], i["ex_ipi"],
              i["cod_gen"], i["cod_lst"], i["aliq_icms"], i["cest"], i["linha"])
             for i in efd.itens])

        cont["H010"] = 0
        if efd.inventario:
            inv = cur.consulta(
                "insert into inventario (arquivo_id, cnpj, dt_inv, vl_inv, mot_inv, "
                " linha_arquivo) values (%s,%s,%s,%s,%s,%s) returning id",
                (aid, efd.cnpj, efd.inventario["dt_inv"], efd.inventario["vl_inv"],
                 efd.inventario["mot_inv"], efd.inventario["linha"]))[0]["id"]
            cont["H010"] = _insere_lote(
                cur, "inventario_item",
                ["inventario_id", "cnpj", "dt_inv", "cod_item", "unid", "qtd",
                 "vl_unit", "vl_item", "ind_prop", "cod_part", "txt_compl",
                 "cod_cta", "vl_item_ir", "linha_arquivo"],
                [(inv, efd.cnpj, efd.inventario["dt_inv"], h["cod_item"], h["unid"],
                  h["qtd"], h["vl_unit"], h["vl_item"], h["ind_prop"], h["cod_part"],
                  h["txt_compl"], h["cod_cta"], h["vl_item_ir"], h["linha"])
                 for h in efd.inventario_itens])

        cont["C100"] = cont["C170"] = 0
        for d in efd.documentos:
            did = cur.consulta(
                "insert into doc_fiscal (arquivo_id, cnpj, ind_oper, ind_emit, "
                " cod_part, cod_mod, cod_sit, ser, num_doc, chv_nfe, dt_doc, dt_e_s, "
                " vl_doc, linha_arquivo) "
                "values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) returning id",
                (aid, efd.cnpj, d["ind_oper"], d["ind_emit"], d["cod_part"],
                 d["cod_mod"], d["cod_sit"], d["ser"], d["num_doc"], d["chv_nfe"],
                 d["dt_doc"], d["dt_e_s"], d["vl_doc"], d["linha"]))[0]["id"]
            cont["C100"] += 1
            cont["C170"] += _insere_lote(
                cur, "doc_item",
                ["doc_id", "arquivo_id", "cnpj", "num_item", "cod_item", "qtd",
                 "unid", "vl_item", "vl_desc", "cfop", "cst_icms", "dt_doc",
                 "ind_oper", "linha_arquivo"],
                [(did, aid, efd.cnpj, it["num_item"], it["cod_item"], it["qtd"],
                  it["unid"], it["vl_item"], it["vl_desc"], it["cfop"],
                  it["cst_icms"], d["dt_doc"], d["ind_oper"], it["linha"])
                 for it in d["itens"]])

        _insere_lote(cur, "importacao_problema", ["arquivo_id", "tipo", "detalhe"],
                     [(aid, t, det) for t, det in problemas])

    situacao = "substituiu" if anteriores else "importado"
    return Resultado(efd.nome_arquivo, situacao, aid, cont, problemas)


def importa_varios(caminhos, quem=None):
    return [importa(c, quem) for c in caminhos]
