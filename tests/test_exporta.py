# -*- coding: utf-8 -*-
"""
Exportação para .xlsx e .pdf.

A planilha é conferida lendo o arquivo gerado de volta com o nosso próprio
leitor: escrever e ler fecham o círculo, e um arquivo que o leitor não abre
também não abriria no Excel. O PDF é conferido pela estrutura — assinatura,
número de páginas e xref —, porque é o que decide se o leitor abre.

O que mais importa aqui: número tem de sair NÚMERO na planilha. Relatório que
chega com valor em formato de texto não soma, e quem recebe vai querer somar.
"""
import re
import zipfile

from auditoria import exporta, planilha

COLUNAS = [
    {"campo": "cod_item", "rotulo": "Código"},
    {"campo": "descr_item", "rotulo": "Descrição"},
    {"campo": "ncm", "rotulo": "NCM"},
    {"campo": "dt", "rotulo": "Data", "tipo": "data"},
    {"campo": "preco", "rotulo": "Preço", "tipo": "dinheiro"},
    {"campo": "qtd", "rotulo": "Quantidade", "tipo": "numero"},
]
LINHAS = [
    {"cod_item": "3881", "descr_item": "B7c Luminária & Led — 105°", "ncm": "94054200",
     "dt": "2023-12-20", "preco": "433.02", "qtd": "12.000"},
    {"cod_item": "4512", "descr_item": "Light Dome III <grid>", "ncm": None,
     "dt": "2023-12-15", "preco": "898.205059", "qtd": "2015.020"},
]


def _escreve(tmp_path, nome="r.xlsx", colunas=None, linhas=None):
    caminho = tmp_path / nome
    caminho.write_bytes(exporta.xlsx("Relatório de teste", colunas or COLUNAS,
                                     linhas if linhas is not None else LINHAS))
    return str(caminho)


def test_planilha_volta_pelo_nosso_leitor(tmp_path):
    linhas = list(planilha.linhas(_escreve(tmp_path)))
    assert linhas[0][0] == "Relatório de teste"
    assert linhas[1][0].startswith("Fiscal Stock · gerado em")
    assert linhas[3] == ["Código", "Descrição", "NCM", "Data", "Preço", "Quantidade"]
    assert linhas[4][0] == "3881"
    assert linhas[4][3] == "20/12/2023"        # data legível, não ISO


def test_numero_sai_como_numero_e_texto_como_texto(tmp_path):
    with zipfile.ZipFile(_escreve(tmp_path)) as z:
        sheet = z.read("xl/worksheets/sheet1.xml").decode()
    # A célula de preço traz <v>, a de descrição traz texto embutido.
    assert "<v>433.02</v>" in sheet
    assert "B7c Luminária &amp; Led — 105°" in sheet
    assert "<v>B7c" not in sheet


def test_caractere_que_quebraria_o_xml_e_escapado(tmp_path):
    linhas = [{"cod_item": "<1>", "descr_item": "a & b", "ncm": "1", "dt": "",
               "preco": "", "qtd": ""}]
    lidas = list(planilha.linhas(_escreve(tmp_path, linhas=linhas)))
    assert lidas[4][0] == "<1>" and lidas[4][1] == "a & b"


def test_celula_vazia_nao_vira_zero(tmp_path):
    """NCM ausente é ausência; zero seria uma afirmação que ninguém fez."""
    lidas = list(planilha.linhas(_escreve(tmp_path)))
    assert lidas[5][2] == ""


def test_formata_no_padrao_brasileiro():
    assert exporta.formata("1234567.891", "dinheiro") == "1.234.567,89"
    assert exporta.formata("2015.020", "numero") == "2.015,02"
    assert exporta.formata("12.000", "numero") == "12"
    assert exporta.formata("2023-12-15", "data") == "15/12/2023"
    assert exporta.formata(None, "dinheiro") == ""
    # O que não for número fica como está, em vez de virar zero.
    assert exporta.formata("n/d", "numero") == "n/d"


def test_pdf_tem_estrutura_que_abre():
    pdf = exporta.pdf("Relatório de teste", "subtítulo", COLUNAS, LINHAS)
    assert pdf.startswith(b"%PDF-1.4")
    assert pdf.rstrip().endswith(b"%%EOF")
    assert pdf.count(b"/Type /Page ") == 1
    # O xref tem de apontar para o começo de cada objeto, senão o leitor recusa.
    inicio = int(re.search(rb"startxref\s+(\d+)", pdf).group(1))
    assert pdf[inicio:inicio + 4] == b"xref"
    for off in [int(m) for m in re.findall(rb"^(\d{10}) 00000 n", pdf, re.M)]:
        assert re.match(rb"\d+ 0 obj", pdf[off:off + 20])


def test_pdf_quebra_pagina_e_repete_o_cabecalho():
    muitas = LINHAS * 60
    pdf = exporta.pdf("Relatório", "sub", COLUNAS, muitas)
    paginas = pdf.count(b"/Type /Page ")
    assert paginas >= 3
    # O cabeçalho aparece uma vez por página: sem isso a página 2 fica cega.
    assert pdf.count("(Código) Tj".encode("cp1252")) == paginas


def test_pdf_preserva_acento_e_escapa_parentese():
    pdf = exporta.pdf("Relatório", "sub", COLUNAS,
                      [{"cod_item": "1", "descr_item": "Luminária (nova)",
                        "ncm": "", "dt": "", "preco": "", "qtd": ""}])
    assert "Lumin\\341ria".encode() in pdf or "Luminária".encode("cp1252") in pdf
    assert rb"\(nova\)" in pdf


def test_nome_do_arquivo_e_previsivel():
    nome = exporta.nome_arquivo("Extrato do ERP — Item a item", "xlsx")
    assert re.match(r"^extrato_do_erp_item_a_item_\d{8}\.xlsx$", nome)
    assert exporta.nome_arquivo("", "pdf").startswith("relatorio_")


def test_tabela_vazia_ainda_gera_arquivo(tmp_path):
    """Exportar um filtro sem resultado não pode explodir na cara de quem clicou."""
    lidas = list(planilha.linhas(_escreve(tmp_path, linhas=[])))
    assert lidas[3][0] == "Código"
    assert exporta.pdf("Vazio", "", COLUNAS, []).count(b"/Type /Page ") == 1
