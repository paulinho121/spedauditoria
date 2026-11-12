# -*- coding: utf-8 -*-
"""
Leitura do relatório "Saldo de produtos" do ERP (JSON).

É uma FOTO: o saldo de cada produto num depósito, numa data. Não tem
movimento, não tem documento, não tem custo — só quantidade. Por isso ela não
vira Kardex nem abertura: entra como **posição declarada**, ao lado da nossa
apuração, para ser confrontada com ela na mesma data.

O ERP exporta as colunas com nome gerado ("columnprodutoCodigo2"), onde o
número é só a ordem na tela. O leitor casa pelo nome sem o prefixo e sem o
sufixo, então reordenar ou acrescentar coluna no relatório não quebra nada.

A data da posição não está dentro do arquivo; está no nome dele
("Saldo de produtos (20261112_131054).json"). Quando não dá para ler, quem
importa informa — uma foto sem data não se confronta com nada.
"""
import hashlib
import json
import os
import re
from dataclasses import dataclass, field
from datetime import date, datetime

RE_DATA_NOME = re.compile(r"(20\d{2})(\d{2})(\d{2})[_-]?(\d{2})?(\d{2})?")
RE_NCM = re.compile(r"\d{4}\.?\d{2}\.?\d{2}")

# Nome da coluna (sem 'column' e sem o número) -> campo nosso.
CAMPOS = {
    "cod_item": ["produtocodigo", "codigo", "codigoproduto", "produto", "item"],
    "descr_item": ["produtonome", "nome", "descricao", "produtodescricao"],
    "unid": ["produtoun", "un", "unidade", "produtounidade"],
    "ncm": ["produtoncm", "ncm", "classificacaofiscal"],
    "fabricante": ["produtofabricante", "fabricante", "reffabricante"],
    "deposito": ["deposito", "almoxarifado"],
    "local": ["localescrituracao", "local"],
    "saldo": ["saldo", "saldoatual", "quantidade", "qtd", "estoque"],
}


def _chave(nome):
    t = re.sub(r"^column", "", str(nome or ""), flags=re.I)
    t = re.sub(r"\d+$", "", t)
    return re.sub(r"[^a-z]", "", t.lower())


def _mapa(registro):
    achadas = {_chave(k): k for k in registro}
    return {campo: achadas[a] for campo, nomes in CAMPOS.items()
            for a in nomes if a in achadas}


def numero(txt):
    """
    '70,76' -> 70.76 · '1.675' -> 1675 · '1.234,50' -> 1234.5

    Ponto sozinho antes de três casas é separador de milhar, que é como o ERP
    exporta. Tratar como decimal transformaria 1.675 unidades em 1,675 — e o
    número ia para um confronto de estoque sem ninguém perceber.
    """
    if isinstance(txt, (int, float)) and not isinstance(txt, bool):
        return float(txt)
    t = str(txt or "").strip().replace(" ", "")
    if not t:
        return None
    negativo = t.startswith("-")
    t = t.lstrip("+-")
    if "," in t:
        t = t.replace(".", "").replace(",", ".")
    elif "." in t:
        cabeca, _, cauda = t.rpartition(".")
        if len(cauda) == 3 and cabeca and all(p.isdigit() for p in cabeca.split(".")):
            t = t.replace(".", "")
    try:
        v = float(t)
    except ValueError:
        return None
    return -v if negativo else v


def ncm(txt):
    m = RE_NCM.search(str(txt or ""))
    if not m:
        return None
    d = re.sub(r"\D", "", m.group(0))
    return d if len(d) == 8 else None


def sha256(caminho):
    h = hashlib.sha256()
    with open(caminho, "rb") as fh:
        for bloco in iter(lambda: fh.read(1 << 20), b""):
            h.update(bloco)
    return h.hexdigest()


def data_do_nome(nome_arquivo):
    """A data que o próprio ERP carimbou no nome do arquivo exportado."""
    m = RE_DATA_NOME.search(os.path.basename(nome_arquivo or ""))
    if not m:
        return None
    try:
        return date(int(m.group(1)), int(m.group(2)), int(m.group(3))).isoformat()
    except ValueError:
        return None


@dataclass
class SaldoERP:
    nome_arquivo: str = ""
    sha256: str = ""
    data: str = None
    depositos: list = field(default_factory=list)
    linhas: list = field(default_factory=list)
    itens: int = 0
    quantidade: float = 0.0
    problemas: list = field(default_factory=list)


def _registros(bruto):
    """Aceita a lista direta ou embrulhada em {'dados': [...]}."""
    if isinstance(bruto, list):
        return bruto
    if isinstance(bruto, dict):
        for chave in ("dados", "registros", "linhas", "rows", "data", "items"):
            if isinstance(bruto.get(chave), list):
                return bruto[chave]
    return []


def e_saldo_erp(caminho):
    """Reconhece pelo conteúdo: tem de haver código do produto e saldo."""
    if not caminho.lower().endswith(".json"):
        return False
    try:
        with open(caminho, encoding="utf-8-sig") as fh:
            regs = _registros(json.load(fh))
    except Exception:
        return False
    if not regs or not isinstance(regs[0], dict):
        return False
    m = _mapa(regs[0])
    return "cod_item" in m and "saldo" in m


def parse(caminho, data=None):
    s = SaldoERP(nome_arquivo=os.path.basename(caminho), sha256=sha256(caminho))
    with open(caminho, encoding="utf-8-sig") as fh:
        regs = _registros(json.load(fh))
    if not regs:
        raise ValueError(f"{s.nome_arquivo}: nenhum registro de saldo no arquivo.")
    m = _mapa(regs[0])
    if "cod_item" not in m or "saldo" not in m:
        raise ValueError(f"{s.nome_arquivo}: não parece o relatório de saldo de "
                         f"produtos — faltam as colunas de código e de saldo.")

    s.data = data or data_do_nome(s.nome_arquivo) or date.today().isoformat()
    if not data and not data_do_nome(s.nome_arquivo):
        s.problemas.append(("data_presumida",
                            f"o nome do arquivo não traz a data; usei {s.data}"))

    pega = lambda r, campo: (r.get(m[campo]) if campo in m else None)
    depositos, vistos = set(), {}
    for n, r in enumerate(regs, start=1):
        cod = str(pega(r, "cod_item") or "").strip()
        if not cod:
            continue
        qtd = numero(pega(r, "saldo"))
        if qtd is None:
            s.problemas.append(("saldo_ilegivel",
                                f"item {cod}: {pega(r, 'saldo')!r}"))
            continue
        dep = str(pega(r, "deposito") or "").strip()
        if dep:
            depositos.add(dep)
        vistos[cod] = vistos.get(cod, 0) + 1
        s.linhas.append({
            "seq": n, "cod_item": cod,
            "descr_item": (str(pega(r, "descr_item") or "").strip() or None),
            "unid": (str(pega(r, "unid") or "").strip() or None),
            "ncm": ncm(pega(r, "ncm")),
            "fabricante": (str(pega(r, "fabricante") or "").strip() or None),
            "deposito": dep or None,
            "local": (str(pega(r, "local") or "").strip() or None),
            "qtd": qtd,
        })

    s.itens = len({l["cod_item"] for l in s.linhas})
    s.quantidade = round(sum(l["qtd"] for l in s.linhas), 3)
    s.depositos = sorted(depositos)
    # Mesmo código em mais de uma linha: o ERP exporta assim quando o produto
    # tem mais de um cadastro ou mais de um lote. O saldo do item é a soma,
    # mas quem audita precisa saber que a soma existiu.
    repetidos = sorted(c for c, n in vistos.items() if n > 1)
    if repetidos:
        s.problemas.append(("codigo_repetido",
                            "somados: " + ", ".join(repetidos[:20])
                            + (" …" if len(repetidos) > 20 else "")))
    if len(s.depositos) > 1:
        s.problemas.append(("varios_depositos", ", ".join(s.depositos)))
    return s
