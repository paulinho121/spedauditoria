# -*- coding: utf-8 -*-
"""
Parser do EFD ICMS/IPI.

Funções puras: entra caminho de arquivo, sai estrutura de dados. Nenhum acesso a
banco, nenhum efeito colateral — é o que torna o teste golden possível.

Layout conforme Guia Prático da EFD ICMS/IPI. Os índices de campo estão
documentados em cada parser porque errar um deles corrompe tudo silenciosamente
(aconteceu: C170 lido com o índice do COD_ITEM errado devolvia 1 item distinto).
"""
import hashlib
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal, InvalidOperation

# Um registro válido: pipe, 4 caracteres (dígito ou letra de bloco), pipe.
RE_REGISTRO = re.compile(r"^\|([0-9A-K][0-9A-Z]{3})\|")

ENCODING = "latin-1"          # ISO-8859-1, conforme o layout oficial


# ------------------------------------------------------------------ conversões
def dec(s):
    """'1.234,56' -> Decimal('1234.56'). Vazio vira None, não zero."""
    s = (s or "").strip()
    if not s:
        return None
    try:
        return Decimal(s.replace(".", "").replace(",", "."))
    except InvalidOperation:
        return None


def dec0(s):
    return dec(s) or Decimal("0")


def data(s):
    """'31122022' -> date(2022,12,31). Formato do SPED é DDMMAAAA."""
    s = (s or "").strip()
    if len(s) != 8 or not s.isdigit():
        return None
    try:
        return date(int(s[4:8]), int(s[2:4]), int(s[0:2]))
    except ValueError:
        return None


def norm_descr(s):
    """
    Chave para reconhecer o mesmo produto entre filiais.
    O código do item NÃO serve: 4061 é refletor em SP e pinça em SC.
    """
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    return re.sub(r"[^A-Z0-9]", "", s.upper())[:40]


def sha256(caminho):
    h = hashlib.sha256()
    with open(caminho, "rb") as fh:
        for bloco in iter(lambda: fh.read(1 << 20), b""):
            h.update(bloco)
    return h.hexdigest()


def campo(p, i):
    return p[i] if len(p) > i else ""


# ------------------------------------------------------------------ estruturas
@dataclass
class Efd:
    caminho: str
    nome_arquivo: str
    sha256: str
    cnpj: str = ""
    nome_empresa: str = ""
    uf: str = ""
    ie: str = ""
    dt_ini: date = None
    dt_fin: date = None
    cod_fin: str = ""
    cod_ver: str = ""
    ind_perfil: str = ""
    ind_ativ: str = ""
    unidades: list = field(default_factory=list)
    participantes: list = field(default_factory=list)
    itens: list = field(default_factory=list)
    inventario: dict = None
    inventario_itens: list = field(default_factory=list)
    documentos: list = field(default_factory=list)
    contagem: dict = field(default_factory=dict)
    linhas_lidas: int = 0
    contadores_9900: dict = field(default_factory=dict)
    # Bloco E: o que a empresa DECLAROU como apuração. Uma lista de registros,
    # cada um com o tributo, a UF (ST e DIFAL apuram por UF) e os valores.
    apuracao: list = field(default_factory=list)

    @property
    def detalha_itens(self):
        """Perfil B não obriga C170 — sem ele não há Kardex por item."""
        with_c170 = sum(1 for d in self.documentos if d["itens"])
        return with_c170, len(self.documentos)


def ler_registros(caminho):
    """Gera (n_linha, registro, campos). Descarta a assinatura digital do fim."""
    with open(caminho, "rb") as fh:
        texto = fh.read().decode(ENCODING, errors="replace")
    for n, linha in enumerate(texto.splitlines(), 1):
        m = RE_REGISTRO.match(linha)
        if m:
            yield n, m.group(1), linha.split("|")


def parse(caminho):
    """Lê um EFD inteiro. Uma passada, sem carregar duas vezes na memória."""
    import os
    efd = Efd(caminho=caminho, nome_arquivo=os.path.basename(caminho),
              sha256=sha256(caminho))
    doc_atual = None
    uf_apur = ""

    for n, reg, p in ler_registros(caminho):
        efd.linhas_lidas += 1
        efd.contagem[reg] = efd.contagem.get(reg, 0) + 1

        if reg == "0000":
            # |0000|COD_VER|COD_FIN|DT_INI|DT_FIN|NOME|CNPJ|CPF|UF|IE|COD_MUN|IM|SUFRAMA|IND_PERFIL|IND_ATIV|
            efd.cod_ver, efd.cod_fin = campo(p, 2), campo(p, 3)
            efd.dt_ini, efd.dt_fin = data(campo(p, 4)), data(campo(p, 5))
            efd.nome_empresa, efd.cnpj = campo(p, 6), campo(p, 7)
            efd.uf, efd.ie = campo(p, 9), campo(p, 10)
            efd.ind_perfil, efd.ind_ativ = campo(p, 14), campo(p, 15)

        elif reg == "0190":
            # |0190|UNID|DESCR|
            efd.unidades.append({"unid": campo(p, 2), "descr": campo(p, 3), "linha": n})

        elif reg == "0150":
            # |0150|COD_PART|NOME|COD_PAIS|CNPJ|CPF|IE|COD_MUN|SUFRAMA|END|NUM|COMPL|BAIRRO|
            efd.participantes.append({
                "cod_part": campo(p, 2), "nome": campo(p, 3), "cod_pais": campo(p, 4),
                "cnpj": campo(p, 5), "cpf": campo(p, 6), "ie": campo(p, 7),
                "cod_mun": campo(p, 8), "linha": n})

        elif reg == "0200":
            # |0200|COD_ITEM|DESCR_ITEM|COD_BARRA|COD_ANT_ITEM|UNID_INV|TIPO_ITEM|COD_NCM|EX_IPI|COD_GEN|COD_LST|ALIQ_ICMS|CEST|
            efd.itens.append({
                "cod_item": campo(p, 2), "descr_item": campo(p, 3),
                "descr_norm": norm_descr(campo(p, 3)), "cod_barra": campo(p, 4),
                "cod_ant": campo(p, 5), "unid_inv": campo(p, 6),
                "tipo_item": campo(p, 7), "ncm": campo(p, 8), "ex_ipi": campo(p, 9),
                "cod_gen": campo(p, 10), "cod_lst": campo(p, 11),
                "aliq_icms": dec(campo(p, 12)), "cest": campo(p, 13), "linha": n})

        elif reg == "H005":
            # |H005|DT_INV|VL_INV|MOT_INV|
            efd.inventario = {"dt_inv": data(campo(p, 2)), "vl_inv": dec0(campo(p, 3)),
                              "mot_inv": campo(p, 4), "linha": n}

        elif reg == "H010":
            # |H010|COD_ITEM|UNID|QTD|VL_UNIT|VL_ITEM|IND_PROP|COD_PART|TXT_COMPL|COD_CTA|VL_ITEM_IR|
            efd.inventario_itens.append({
                "cod_item": campo(p, 2), "unid": campo(p, 3),
                "qtd": dec0(campo(p, 4)), "vl_unit": dec0(campo(p, 5)),
                "vl_item": dec0(campo(p, 6)), "ind_prop": campo(p, 7),
                "cod_part": campo(p, 8) or None, "txt_compl": campo(p, 9) or None,
                "cod_cta": campo(p, 10) or None, "vl_item_ir": dec(campo(p, 11)),
                "linha": n})

        elif reg == "C100":
            # |C100|IND_OPER|IND_EMIT|COD_PART|COD_MOD|COD_SIT|SER|NUM_DOC|CHV_NFE|DT_DOC|DT_E_S|VL_DOC|...
            # ...|IND_PGTO|VL_DESC|VL_ABAT_NT|VL_MERC|IND_FRT|VL_FRT|VL_SEG|VL_OUT_DA|
            #    VL_BC_ICMS|VL_ICMS|VL_BC_ICMS_ST|VL_ICMS_ST|VL_IPI|VL_PIS|VL_COFINS|
            doc_atual = {
                "ind_oper": campo(p, 2), "ind_emit": campo(p, 3), "cod_part": campo(p, 4),
                "cod_mod": campo(p, 5), "cod_sit": campo(p, 6), "ser": campo(p, 7),
                "num_doc": campo(p, 8), "chv_nfe": campo(p, 9),
                "dt_doc": data(campo(p, 10)), "dt_e_s": data(campo(p, 11)),
                "vl_doc": dec(campo(p, 12)), "linha": n, "itens": [], "analitico": [],
                "impostos": {
                    "vl_desc": dec(campo(p, 14)), "vl_merc": dec(campo(p, 16)),
                    "vl_bc_icms": dec(campo(p, 21)), "vl_icms": dec(campo(p, 22)),
                    "vl_bc_st": dec(campo(p, 23)), "vl_st": dec(campo(p, 24)),
                    "vl_ipi": dec(campo(p, 25)), "vl_pis": dec(campo(p, 26)),
                    "vl_cofins": dec(campo(p, 27))}}
            efd.documentos.append(doc_atual)

        elif reg == "C190" and doc_atual is not None:
            # |C190|CST_ICMS|CFOP|ALIQ_ICMS|VL_OPR|VL_BC_ICMS|VL_ICMS|VL_BC_ICMS_ST|
            #  VL_ICMS_ST|VL_RED_BC|VL_IPI|COD_OBS|
            # É o C190, e não o C170, que alimenta a apuração: existe mesmo no
            # perfil B, onde o C170 é dispensado.
            doc_atual["analitico"].append({
                "cst_icms": campo(p, 2), "cfop": campo(p, 3),
                "aliq": dec(campo(p, 4)), "vl_opr": dec(campo(p, 5)),
                "vl_bc_icms": dec(campo(p, 6)), "vl_icms": dec(campo(p, 7)),
                "vl_bc_st": dec(campo(p, 8)), "vl_st": dec(campo(p, 9)),
                "vl_red_bc": dec(campo(p, 10)), "vl_ipi": dec(campo(p, 11)),
                "linha": n})

        elif reg in ("E200", "E300"):
            # |E200|UF|DT_INI|DT_FIN| — abre a apuração de ST (E210) ou DIFAL
            # (E310) daquela UF.
            uf_apur = campo(p, 2)

        elif reg == "E110":
            # |E110|VL_TOT_DEBITOS|VL_AJ_DEBITOS|VL_TOT_AJ_DEBITOS|VL_ESTORNOS_CRED|
            #  VL_TOT_CREDITOS|VL_AJ_CREDITOS|VL_TOT_AJ_CREDITOS|VL_ESTORNOS_DEB|
            #  VL_SLD_CREDOR_ANT|VL_SLD_APURADO|VL_TOT_DED|VL_ICMS_RECOLHER|
            #  VL_SLD_CREDOR_TRANSPORTAR|DEB_ESP|
            # Há DOIS ajustes de cada lado: VL_AJ_* vem dos documentos (C197) e
            # VL_TOT_AJ_* da própria apuração (E111). A primeira versão desta
            # leitura somava só um deles, e o E110 de SC de fev/2023 parecia não
            # fechar por R$ 3.696,31 — quando fechava no centavo.
            efd.apuracao.append({
                "tributo": "icms", "uf": efd.uf, "linha": n,
                "debitos": dec0(campo(p, 2)),
                "ajustes_debito_doc": dec0(campo(p, 3)),
                "ajustes_debito": dec0(campo(p, 4)),
                "estornos_credito": dec0(campo(p, 5)),
                "creditos": dec0(campo(p, 6)),
                "ajustes_credito_doc": dec0(campo(p, 7)),
                "ajustes_credito": dec0(campo(p, 8)),
                "estornos_debito": dec0(campo(p, 9)),
                "saldo_credor_anterior": dec0(campo(p, 10)),
                "saldo_apurado": dec0(campo(p, 11)), "deducoes": dec0(campo(p, 12)),
                "a_recolher": dec0(campo(p, 13)),
                "saldo_credor_transportar": dec0(campo(p, 14)),
                "debitos_especiais": dec0(campo(p, 15))})

        elif reg == "E210":
            # |E210|IND_MOV_ST|VL_SLD_CRED_ANT_ST|VL_DEVOL_ST|VL_RESSARC_ST|
            #  VL_OUT_CRED_ST|VL_AJ_CREDITOS_ST|VL_RETENCAO_ST|VL_OUT_DEB_ST|
            #  VL_AJ_DEBITOS_ST|VL_SLD_DEV_ANT_ST|VL_DEDUCOES_ST|VL_ICMS_RECOL_ST|
            #  VL_SLD_CRED_ST_TRANSPORTAR|DEB_ESP_ST|
            efd.apuracao.append({
                "tributo": "st", "uf": uf_apur, "linha": n,
                "movimento": campo(p, 2),
                "saldo_credor_anterior": dec0(campo(p, 3)),
                "creditos": dec0(campo(p, 4)) + dec0(campo(p, 5)) + dec0(campo(p, 6))
                            + dec0(campo(p, 7)),
                "debitos": dec0(campo(p, 8)),
                "ajustes_debito": dec0(campo(p, 9)) + dec0(campo(p, 10)),
                "saldo_apurado": dec0(campo(p, 11)), "deducoes": dec0(campo(p, 12)),
                "a_recolher": dec0(campo(p, 13)),
                "saldo_credor_transportar": dec0(campo(p, 14)),
                "debitos_especiais": dec0(campo(p, 15))})

        elif reg == "E310":
            # |E310|IND_MOV_FCP_DIFAL|VL_SLD_CRED_ANT_DIFAL|VL_TOT_DEBITOS_DIFAL|
            #  VL_OUT_DEB_DIFAL|VL_TOT_CREDITOS_DIFAL|VL_OUT_CRED_DIFAL|
            #  VL_SLD_DEV_ANT_DIFAL|VL_DEDUCOES_DIFAL|VL_RECOL_DIFAL|
            #  VL_SLD_CRED_TRANSPORTAR_DIFAL|DEB_ESP_DIFAL| e o mesmo para o FCP.
            efd.apuracao.append({
                "tributo": "difal", "uf": uf_apur, "linha": n,
                "movimento": campo(p, 2),
                "saldo_credor_anterior": dec0(campo(p, 3)),
                "debitos": dec0(campo(p, 4)), "ajustes_debito": dec0(campo(p, 5)),
                "creditos": dec0(campo(p, 6)), "ajustes_credito": dec0(campo(p, 7)),
                "saldo_apurado": dec0(campo(p, 8)), "deducoes": dec0(campo(p, 9)),
                "a_recolher": dec0(campo(p, 10)),
                "saldo_credor_transportar": dec0(campo(p, 11)),
                "debitos_especiais": dec0(campo(p, 12))})
            efd.apuracao.append({
                "tributo": "fcp", "uf": uf_apur, "linha": n,
                "saldo_credor_anterior": dec0(campo(p, 13)),
                "debitos": dec0(campo(p, 14)), "ajustes_debito": dec0(campo(p, 15)),
                "creditos": dec0(campo(p, 16)), "ajustes_credito": dec0(campo(p, 17)),
                "saldo_apurado": dec0(campo(p, 18)), "deducoes": dec0(campo(p, 19)),
                "a_recolher": dec0(campo(p, 20)),
                "saldo_credor_transportar": dec0(campo(p, 21)),
                "debitos_especiais": dec0(campo(p, 22))})

        elif reg == "E520":
            # |E520|VL_SD_ANT_IPI|VL_DEB_IPI|VL_CRED_IPI|VL_OD_IPI|VL_OC_IPI|
            #  VL_SC_IPI|VL_SD_IPI|
            efd.apuracao.append({
                "tributo": "ipi", "uf": efd.uf, "linha": n,
                "saldo_credor_anterior": dec0(campo(p, 2)),
                "debitos": dec0(campo(p, 3)), "creditos": dec0(campo(p, 4)),
                "ajustes_debito": dec0(campo(p, 5)), "ajustes_credito": dec0(campo(p, 6)),
                "saldo_credor_transportar": dec0(campo(p, 7)),
                "a_recolher": dec0(campo(p, 8))})

        elif reg == "C170" and doc_atual is not None:
            # |C170|NUM_ITEM|COD_ITEM|DESCR_COMPL|QTD|UNID|VL_ITEM|VL_DESC|IND_MOV|CST_ICMS|CFOP|...
            doc_atual["itens"].append({
                "num_item": campo(p, 2), "cod_item": campo(p, 3),
                "qtd": dec(campo(p, 5)), "unid": campo(p, 6),
                "vl_item": dec(campo(p, 7)), "vl_desc": dec(campo(p, 8)),
                "cst_icms": campo(p, 10), "cfop": campo(p, 11), "linha": n})

        elif reg == "9900":
            # |9900|REG_BLC|QTD_REG_BLC|
            efd.contadores_9900[campo(p, 2)] = int(campo(p, 3) or 0)

    return efd


# ------------------------------------------------------------------ validações
def confere(efd):
    """
    Conferências que só dependem do arquivo. Devolve lista de problemas.
    Rodam na importação — o auditor precisa saber antes de usar o dado.
    """
    probs = []

    if not efd.cnpj:
        probs.append(("estrutura", "registro 0000 ausente ou sem CNPJ"))

    for reg, declarado in sorted(efd.contadores_9900.items()):
        lido = efd.contagem.get(reg, 0)
        if lido != declarado:
            probs.append(("contador_9900",
                          f"registro {reg}: 9900 declara {declarado}, arquivo tem {lido}"))

    if efd.inventario:
        soma = sum(i["vl_item"] for i in efd.inventario_itens)
        dif = efd.inventario["vl_inv"] - soma
        if abs(dif) >= Decimal("0.01"):
            probs.append(("h005_x_h010",
                          f"H005 declara {efd.inventario['vl_inv']}, "
                          f"soma dos H010 é {soma} (diferença {dif})"))

    cods_0200 = {i["cod_item"] for i in efd.itens}
    sem_cadastro = {h["cod_item"] for h in efd.inventario_itens} - cods_0200
    if sem_cadastro:
        probs.append(("h010_sem_0200",
                      f"{len(sem_cadastro)} itens do inventário sem registro 0200: "
                      f"{sorted(sem_cadastro)[:5]}"))

    for h in efd.inventario_itens:
        if h["qtd"] < 0:
            probs.append(("qtd_negativa", f"item {h['cod_item']} com quantidade {h['qtd']}"))
        if h["vl_item"] < 0:
            probs.append(("valor_negativo", f"item {h['cod_item']} com valor {h['vl_item']}"))

    vistos = set()
    for h in efd.inventario_itens:
        chave = (h["cod_item"], h["ind_prop"], h["cod_part"])
        if chave in vistos:
            probs.append(("h010_duplicado", f"item {h['cod_item']} repetido no inventário"))
        vistos.add(chave)

    com_c170, total_docs = efd.detalha_itens
    if total_docs and com_c170 < total_docs:
        probs.append(("cobertura_c170",
                      f"perfil {efd.ind_perfil}: {com_c170} de {total_docs} documentos "
                      f"têm detalhe por item (C170). Sem C170 não há Kardex por item."))

    return probs


def digest(efd):
    """
    Resumo estável do conteúdo, para o teste golden.
    Não guarda os dados do cliente — só contagens e hashes.
    """
    def h(linhas):
        # Normaliza para texto antes de ordenar: as tuplas misturam None,
        # Decimal e str, e comparar tipos diferentes estoura TypeError.
        textos = ["|".join("" if c is None else str(c) for c in t) for t in linhas]
        m = hashlib.sha256()
        for t in sorted(textos):
            m.update((t + "\n").encode("utf-8"))
        return m.hexdigest()[:16]

    inv = [(i["cod_item"], i["unid"], i["qtd"], i["vl_unit"], i["vl_item"],
            i["ind_prop"], i["cod_part"], i["cod_cta"]) for i in efd.inventario_itens]
    itens = [(i["cod_item"], i["descr_norm"], i["ncm"], i["unid_inv"], i["tipo_item"])
             for i in efd.itens]
    docs = [(d["cod_mod"], d["num_doc"], d["chv_nfe"], d["dt_doc"], d["vl_doc"])
            for d in efd.documentos]
    # O C170 precisa entrar no digest: sem ele o golden passava mesmo com o
    # COD_ITEM sendo lido do campo errado, porque nada do item era resumido.
    itens_doc = [(d["num_doc"], it["num_item"], it["cod_item"], it["qtd"],
                  it["vl_item"], it["cfop"], it["cst_icms"])
                 for d in efd.documentos for it in d["itens"]]

    return {
        "sha256_arquivo": efd.sha256,
        "cnpj": efd.cnpj, "uf": efd.uf, "perfil": efd.ind_perfil,
        "periodo": f"{efd.dt_ini}..{efd.dt_fin}", "cod_fin": efd.cod_fin,
        "linhas_lidas": efd.linhas_lidas,
        "contagem": dict(sorted(efd.contagem.items())),
        "inventario_dt": str(efd.inventario["dt_inv"]) if efd.inventario else None,
        "inventario_vl": str(efd.inventario["vl_inv"]) if efd.inventario else None,
        "inventario_qtd_itens": len(efd.inventario_itens),
        "inventario_soma_vl": str(sum(i["vl_item"] for i in efd.inventario_itens)),
        "inventario_soma_qtd": str(sum(i["qtd"] for i in efd.inventario_itens)),
        "hash_h010": h(inv),
        "hash_0200": h(itens),
        "hash_c100": h(docs),
        "hash_c170": h(itens_doc),
        "docs_qtd": len(efd.documentos),
        "docs_itens_qtd": len(itens_doc),
        "docs_itens_cods_distintos": len({t[2] for t in itens_doc}),
        "problemas": sorted(t for t, _ in confere(efd)),
    }
