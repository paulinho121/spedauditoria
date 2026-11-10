# -*- coding: utf-8 -*-
"""
Leitura do extrato de estoque do ERP ("Extrato de produtos por depósito,
produto e lote").

É o Kardex que o cliente usa no dia a dia: uma linha por movimento, com data,
depósito, documento de origem, quantidade e custo. Para a auditoria ele vale
por ser a *outra* versão da mesma história — a nossa vem do XML, a dele vem do
sistema que emitiu a nota. Onde as duas discordam é onde se olha.

Duas convenções do relatório que o parser precisa conhecer:

  1. A linha **sem** chave de movimento é o saldo de abertura do item no
     período: quantidade e custo já acumulados antes do primeiro movimento.
  2. A saída vem com quantidade e custo **negativos**. Aqui o sinal é desfeito
     e guardado em colunas próprias — entrada e saída — como no resto do
     sistema, para que somar não dependa de lembrar do sinal.

O período não está escrito no arquivo; ele é deduzido dos movimentos, do
primeiro dia do mês mais antigo ao último dia do mês mais recente. Por isso a
abertura é confrontada com a nossa posição na véspera do dt_ini.
"""
import calendar
import hashlib
import os
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import date

from . import planilha

CABECALHO = ["1o. Agrupamento", "Ch Mov", "Dt Mov", "Hr Mov", "Depósito"]
RE_DOC = re.compile(r"^\s*(\w+)\s+(\d+)\s+0*(\d+)\s*$")
RE_DATA = re.compile(r"^(\d{2})/(\d{2})/(\d{4})$")
RE_NCM = re.compile(r"\d{4}\.?\d{2}\.?\d{2}")

# As colunas sao achadas pelo NOME, e nao pela posicao. O relatorio e montado
# pelo usuario do ERP: acrescentar uma coluna de NCM — ou de referencia do
# fabricante — nao pode quebrar a leitura das outras. A posicao fica como
# ultimo recurso, para o leiaute que ja conhecemos.
COLUNAS = {
    "agrupamento": (["1o. agrupamento", "agrupamento", "produto"], 0),
    "ch_mov": (["ch mov", "chave do movimento"], 1),
    "dt": (["dt mov", "data do movimento", "data"], 2),
    "hora": (["hr mov", "hora do movimento", "hora"], 3),
    "deposito": (["deposito", "almoxarifado"], 4),
    "ref_fabricante": (["ref. fabricante", "ref fabricante", "referencia do fabricante"], 5),
    "ncm": (["ncm", "ncm/sh", "ncm sh", "classificacao fiscal", "class. fiscal",
             "cod. ncm", "codigo ncm"], None),
    "ch_doc": (["ch doc", "chave do documento"], 6),
    "documento": (["operacao de origem#documento", "documento", "doc"], 7),
    "tipo": (["operacao de origem#tipo", "tipo da operacao", "operacao"], 8),
    "entidade": (["operacao de origem#entidade", "entidade", "parceiro"], 9),
    "qtd_entrada": (["quantidade#entrada", "qtd entrada", "quantidade entrada"], 10),
    "qtd_saida": (["quantidade#saida", "qtd saida", "quantidade saida"], 11),
    "qtd_saldo": (["quantidade#saldo", "qtd saldo", "quantidade saldo"], 12),
    "custo_entrada": (["custo#entrada", "custo entrada"], 13),
    "custo_saida": (["custo#saida", "custo saida"], 14),
    "custo_saldo": (["custo#saldo", "custo saldo"], 15),
    "custo_medio": (["custo med", "custo medio", "custo med.", "custo médio"], 16),
}


def _chave(texto):
    """Nome de coluna comparável: sem acento, sem caixa, sem espaço sobrando."""
    t = unicodedata.normalize("NFKD", (texto or "").strip().lower())
    t = "".join(c for c in t if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", t)


def mapa_colunas(cabecalho):
    """Nome da coluna -> posição. O que não existir no arquivo fica fora."""
    achadas = {_chave(c): i for i, c in enumerate(cabecalho or []) if (c or "").strip()}
    mapa = {}
    for campo, (nomes, padrao) in COLUNAS.items():
        pos = next((achadas[_chave(n)] for n in nomes if _chave(n) in achadas), None)
        if pos is None and padrao is not None and padrao < len(cabecalho or []):
            # Só vale a posição se o cabeçalho conhecido estiver mesmo ali.
            if _chave(cabecalho[padrao]) in {_chave(n) for n in nomes}:
                pos = padrao
        if pos is not None:
            mapa[campo] = pos
    return mapa


def _ncm(txt):
    """'9405.99.00' e '94059900' viram 94059900. Lixo vira None."""
    m = RE_NCM.search((txt or "").strip())
    if not m:
        return None
    so_digito = re.sub(r"\D", "", m.group(0))
    return so_digito if len(so_digito) == 8 else None


def _num(txt):
    """'1.234,56' e '-1587,858571' viram número; vazio vira None."""
    t = (txt or "").strip()
    if not t:
        return None
    t = t.replace(".", "").replace(",", ".") if "," in t else t
    try:
        return float(t)
    except ValueError:
        return None


def _data(txt):
    m = RE_DATA.match((txt or "").strip())
    return f"{m.group(3)}-{m.group(2)}-{m.group(1)}" if m else None


def _item(agrupamento):
    """
    '3979 - ACESSORIO DE SUPORTE P/ LUZES - Un' -> ('3979', 'ACESSORIO…', 'Un')

    O código vem antes do primeiro ' - ' e a unidade depois do último; a
    descrição fica no meio e pode conter ' - ' à vontade, que é o caso real.
    """
    partes = [p.strip() for p in (agrupamento or "").split(" - ")]
    if len(partes) == 1:
        return partes[0], "", ""
    cod, resto = partes[0], partes[1:]
    unid = ""
    if len(resto) > 1 and len(resto[-1]) <= 6:
        unid = resto.pop()
    return cod, " - ".join(resto).strip(), unid


def _documento(txt):
    """'NFe 1 000000579' -> ('NFe', '1', '579'). O ERP zera à esquerda."""
    m = RE_DOC.match(txt or "")
    return (m.group(1), m.group(2), m.group(3)) if m else (None, None, None)


def sha256(caminho):
    h = hashlib.sha256()
    with open(caminho, "rb") as fh:
        for bloco in iter(lambda: fh.read(1 << 20), b""):
            h.update(bloco)
    return h.hexdigest()


@dataclass
class ExtratoERP:
    nome_arquivo: str = ""
    sha256: str = ""
    depositos: list = field(default_factory=list)
    dt_ini: str = None
    dt_fin: str = None
    linhas: list = field(default_factory=list)
    itens: int = 0
    movimentos: int = 0
    aberturas: int = 0
    colunas: list = field(default_factory=list)
    problemas: list = field(default_factory=list)


def e_extrato_erp(caminho):
    """
    Reconhece o relatório pelo cabeçalho, não pelo nome do arquivo.

    Basta ter o produto, o saldo e um dos lados do movimento: coluna a mais —
    NCM, referência do fabricante — não descaracteriza o relatório.
    """
    if not caminho.lower().endswith((".xlsx", ".xlsm")):
        return False
    try:
        primeira = next(iter(planilha.linhas(caminho)), [])
    except Exception:
        return False
    m = mapa_colunas(primeira)
    return ("agrupamento" in m and "qtd_saldo" in m
            and ("qtd_entrada" in m or "qtd_saida" in m))


def parse(caminho, aba=None):
    e = ExtratoERP(nome_arquivo=os.path.basename(caminho), sha256=sha256(caminho))
    it = iter(planilha.linhas(caminho, aba))
    cab = next(it, [])
    mapa = mapa_colunas(cab)
    if not ("agrupamento" in mapa and "qtd_saldo" in mapa
            and ("qtd_entrada" in mapa or "qtd_saida" in mapa)):
        raise ValueError(f"{e.nome_arquivo}: não parece o extrato de produtos "
                         f"do ERP — cabeçalho inesperado.")
    e.colunas = sorted(mapa)

    def col(r, campo):
        i = mapa.get(campo)
        if i is None or i >= len(r):
            return ""
        return (r[i] or "").strip()

    itens, datas, depositos = set(), [], set()
    for n, r in enumerate(it, start=2):
        if not any((c or "").strip() for c in r):
            continue
        cod, descr, unid = _item(col(r, "agrupamento"))
        if not cod:
            continue
        dt = _data(col(r, "dt"))
        if col(r, "dt") and not dt:
            e.problemas.append(("data_ilegivel", f"linha {n}: {col(r, 'dt')!r}"))
        mod, serie, num = _documento(col(r, "documento"))
        ent, sai = _num(col(r, "qtd_entrada")), _num(col(r, "qtd_saida"))
        c_ent, c_sai = _num(col(r, "custo_entrada")), _num(col(r, "custo_saida"))
        abertura = not col(r, "ch_mov") and not dt

        itens.add(cod)
        if dt:
            datas.append(dt)
        if col(r, "deposito"):
            depositos.add(col(r, "deposito"))
        e.linhas.append({
            "seq": n - 1, "abertura": abertura,
            "cod_item": cod, "descr_item": descr, "unid": unid,
            # O NCM só existe se o relatório trouxer a coluna; quando não vem,
            # o sistema o busca pelo código no cadastro 0200 e nos XML.
            "ncm": _ncm(col(r, "ncm")),
            "deposito": col(r, "deposito"), "dt": dt, "hora": col(r, "hora") or None,
            "ch_mov": col(r, "ch_mov") or None, "ch_doc": col(r, "ch_doc") or None,
            "doc_modelo": mod, "doc_serie": serie, "doc_num": num,
            "doc_texto": col(r, "documento") or None,
            "tipo": col(r, "tipo") or None, "entidade": col(r, "entidade") or None,
            # O relatório traz a saída negativa; aqui cada lado tem sua coluna.
            "qtd_entrada": ent if (ent or 0) > 0 else None,
            "qtd_saida": abs(sai) if (sai or 0) < 0 else (sai or None),
            "qtd_saldo": _num(col(r, "qtd_saldo")),
            "custo_entrada": c_ent if (c_ent or 0) > 0 else None,
            "custo_saida": abs(c_sai) if (c_sai or 0) < 0 else (c_sai or None),
            "custo_saldo": _num(col(r, "custo_saldo")),
            "custo_medio": _num(col(r, "custo_medio")),
        })

    e.itens = len(itens)
    e.aberturas = sum(1 for l in e.linhas if l["abertura"])
    e.movimentos = len(e.linhas) - e.aberturas
    e.depositos = sorted(depositos)
    if datas:
        # O arquivo não diz o período; os movimentos dizem. Mês fechado, para
        # que a abertura case com a nossa posição na véspera.
        ini, fim = min(datas), max(datas)
        a, m = int(fim[:4]), int(fim[5:7])
        e.dt_ini = f"{ini[:7]}-01"
        e.dt_fin = f"{fim[:7]}-{calendar.monthrange(a, m)[1]:02d}"
    if not e.linhas:
        e.problemas.append(("vazio", "nenhuma linha de produto no arquivo"))
    if len(e.depositos) > 1:
        e.problemas.append(("varios_depositos", ", ".join(e.depositos)))
    return e


def confere(e):
    """
    Confere o extrato contra ele mesmo: o saldo que o ERP imprime em cada linha
    tem de ser o anterior mais a entrada menos a saída. Divergência aqui é do
    relatório, não da nossa leitura — e precisa aparecer antes de o número ser
    usado para auditar seja o que for.
    """
    problemas = []
    saldo = {}
    for l in e.linhas:
        chave = (l["cod_item"], l["deposito"] or (e.depositos[0] if e.depositos else ""))
        esperado = (saldo.get(chave, 0) + (l["qtd_entrada"] or 0) - (l["qtd_saida"] or 0))
        impresso = l["qtd_saldo"]
        if impresso is not None and abs(esperado - impresso) > 0.001:
            problemas.append(("saldo_nao_fecha",
                              f"item {l['cod_item']} linha {l['seq']}: "
                              f"calculado {esperado:g}, impresso {impresso:g}"))
            esperado = impresso
        saldo[chave] = esperado
    return problemas
