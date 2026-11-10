# -*- coding: utf-8 -*-
"""
Leitura de .xlsx com a biblioteca padrão.

Um .xlsx é um zip de XML. Ler com zipfile e ElementTree evita trazer uma
dependência nova para dentro da função serverless, que hoje instala apenas o
psycopg — e o que precisamos daqui é pouco: as células como texto, na ordem,
com as vazias no lugar certo.

O valor volta sempre como texto. Converter número e data é decisão de quem
conhece o relatório: o ERP exporta quantidade e custo como texto com vírgula, e
transformar cedo demais perderia a diferença entre zero e célula vazia.
"""
import re
import zipfile
import xml.etree.ElementTree as ET

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
RE_COL = re.compile(r"^([A-Z]+)")


def _coluna(ref):
    """'BC12' -> 54. Sem a referência não dá para saber onde a célula cai."""
    letras = RE_COL.match(ref or "")
    if not letras:
        return None
    n = 0
    for ch in letras.group(1):
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def _textos(z):
    """sharedStrings.xml: as células de texto guardam só o índice daqui."""
    if "xl/sharedStrings.xml" not in z.namelist():
        return []
    raiz = ET.fromstring(z.read("xl/sharedStrings.xml"))
    out = []
    for si in raiz.findall(f"{NS}si"):
        # O texto de uma célula pode vir partido em vários <t> quando tem
        # formatação no meio; juntar é o que o Excel mostra.
        out.append("".join(t.text or "" for t in si.iter(f"{NS}t")))
    return out


def abas(caminho):
    """Nomes das abas, na ordem em que aparecem."""
    with zipfile.ZipFile(caminho) as z:
        raiz = ET.fromstring(z.read("xl/workbook.xml"))
        return [s.get("name") for s in raiz.iter(f"{NS}sheet")]


def linhas(caminho, aba=None):
    """
    Gera cada linha como lista de textos. A aba vai pelo nome; sem nome, a
    primeira. Linha vazia no meio da planilha é devolvida como lista vazia.
    """
    with zipfile.ZipFile(caminho) as z:
        nomes = abas(caminho)
        i = (nomes.index(aba) + 1) if aba in nomes else 1
        alvo = f"xl/worksheets/sheet{i}.xml"
        if alvo not in z.namelist():
            raise ValueError(f"{caminho}: não achei a aba {aba or i}")
        compartilhados = _textos(z)
        raiz = ET.fromstring(z.read(alvo))
        esperada = 1
        for row in raiz.iter(f"{NS}row"):
            # Linha em branco não tem <row> no arquivo. Pular direto para a
            # próxima deslocaria tudo o que vem depois — e a planilha do ERP
            # separa blocos com linha vazia. O número da linha é o do arquivo.
            atual = int(row.get("r") or esperada)
            while esperada < atual:
                esperada += 1
                yield []
            esperada = atual + 1
            saida = []
            for c in row.findall(f"{NS}c"):
                pos = _coluna(c.get("r"))
                if pos is None:
                    pos = len(saida)
                while len(saida) <= pos:
                    saida.append("")
                t = c.get("t")
                if t == "s":
                    v = c.find(f"{NS}v")
                    idx = int(v.text) if v is not None and v.text else -1
                    saida[pos] = compartilhados[idx] if 0 <= idx < len(compartilhados) else ""
                elif t == "inlineStr":
                    saida[pos] = "".join(x.text or "" for x in c.iter(f"{NS}t"))
                else:
                    v = c.find(f"{NS}v")
                    saida[pos] = (v.text or "") if v is not None else ""
            yield saida
