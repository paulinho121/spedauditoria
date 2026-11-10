# -*- coding: utf-8 -*-
"""
Leitor do extrato de produtos do ERP contra uma planilha SINTÉTICA.

Não há planilha real no repositório — o extrato do cliente tem nome de pessoa
física em cada linha. A planilha montada aqui reproduz o que decide a leitura,
copiado do arquivo real de dezembro/2023:

  item 10  abertura de 10 un e uma saída de 2 por NF 579      -> sobra 8
  item 20  entra 3 por transferência e sai 1 sem documento    -> sobra 2
  item 30  saldo impresso que NÃO fecha com a aritmética      -> tem de aparecer

O .xlsx é escrito à mão (zip de XML) de propósito: o leitor também é de
biblioteca padrão, e assim o teste cobre o mesmo caminho que o arquivo real.
"""
import os
import tempfile
import zipfile

from auditoria import erp, planilha

CABECALHO = ["1o. Agrupamento", "Ch Mov", "Dt Mov", "Hr Mov", "Depósito",
             "Ref. fabricante", "Ch Doc", "Operação de Origem#Documento",
             "Operação de Origem#Tipo", "Operação de Origem#Entidade",
             "Quantidade#Entrada", "Quantidade#Saída", "Quantidade#Saldo",
             "Custo#Entrada", "Custo#Saída", "Custo#Saldo", "Custo Méd"]

LINHAS = [
    CABECALHO,
    # item 10: abertura e uma venda com NF
    ["10 - ACESSORIO DE SUPORTE - Un", "", "", "", "", "", "", "", "", "",
     "10", "", "10", "271,70", "", "271,70", "27,17"],
    ["10 - ACESSORIO DE SUPORTE - Un", "271478", "04/12/2023", "10:44:05", "DEP MCI SP", "",
     "271456", "NFe 1 000000579", "V Adq Terc p Consumo", "Taissuke Locadora", "",
     "-2", "8", "", "-54,34", "217,36", "27,17"],
    # item 20: entrada por transferência e saída SEM documento fiscal
    ["20 - Amaran 200d - Un", "287392", "12/12/2023", "10:35:03", "DEP MCI SP", "",
     "287389", "NFe 1 000001594", "Ent Rem Transferência ST", "EST MCI SC",
     "3", "", "3", "2.282,31", "", "2.282,31", "760,77"],
    ["20 - Amaran 200d - Un", "1255103", "15/12/2023", "15:30", "DEP MCI SP", "",
     "1255101", "  ", "Req p Produção", "CC MCI SP", "", "-1", "2", "", "-760,77",
     "1.521,54", "760,77"],
    # item 30: o saldo impresso não bate com entrada menos saída
    ["30 - Tripe - Un", "", "", "", "", "", "", "", "", "", "5", "", "5", "500,00", "", "500,00", "100,00"],
    ["30 - Tripe - Un", "300001", "20/12/2023", "09:00:00", "DEP MCI SP", "",
     "300000", "NFe 1 000000600", "V Adq Terc p Consumo", "Fulano", "", "-1", "7",
     "", "-100,00", "400,00", "100,00"],
]

TIPOS = """<?xml version="1.0"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>"""

WORKBOOK = """<?xml version="1.0"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheets><sheet name="Planilha1" sheetId="1" r:id="rId1"
  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></sheets>
</workbook>"""


def _coluna(i):
    """0 -> A, 25 -> Z, 26 -> AA. O leitor posiciona a célula pela referência."""
    s = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s


def _escapa(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def planilha_sintetica(linhas=None):
    """Escreve um .xlsx mínimo e devolve o caminho."""
    linhas = linhas or LINHAS
    corpo = []
    for n, linha in enumerate(linhas, start=1):
        celulas = "".join(
            f'<c r="{_coluna(i)}{n}" t="inlineStr"><is><t>{_escapa(v)}</t></is></c>'
            for i, v in enumerate(linha) if v != "")
        corpo.append(f'<row r="{n}">{celulas}</row>')
    sheet = ('<?xml version="1.0"?><worksheet '
             'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
             "<sheetData>" + "".join(corpo) + "</sheetData></worksheet>")
    caminho = os.path.join(tempfile.mkdtemp(prefix="erp_"), "extrato.xlsx")
    with zipfile.ZipFile(caminho, "w") as z:
        z.writestr("[Content_Types].xml", TIPOS)
        z.writestr("xl/workbook.xml", WORKBOOK)
        z.writestr("xl/worksheets/sheet1.xml", sheet)
    return caminho


def test_leitor_posiciona_celula_vazia():
    """A célula ausente no XML não pode deslocar as seguintes."""
    linhas = list(planilha.linhas(planilha_sintetica()))
    assert linhas[0][:5] == CABECALHO[:5]
    assert linhas[1][10] == "10"        # Quantidade#Entrada
    assert linhas[1][1] == ""           # Ch Mov vazio na abertura
    assert planilha.abas(planilha_sintetica()) == ["Planilha1"]


def test_reconhece_pelo_cabecalho():
    assert erp.e_extrato_erp(planilha_sintetica())
    outra = planilha_sintetica([["Produto", "Saldo"], ["10", "5"]])
    assert not erp.e_extrato_erp(outra)


def test_parse_separa_abertura_de_movimento():
    e = erp.parse(planilha_sintetica())
    assert e.itens == 3
    assert e.aberturas == 2
    assert e.movimentos == 4
    # Período fechado no mês, para a abertura casar com a véspera do dt_ini.
    assert (e.dt_ini, e.dt_fin) == ("2023-12-01", "2023-12-31")
    assert e.depositos == ["DEP MCI SP"]

    ab = e.linhas[0]
    assert ab["abertura"] and ab["cod_item"] == "10" and ab["unid"] == "Un"
    assert ab["descr_item"] == "ACESSORIO DE SUPORTE"
    assert ab["qtd_entrada"] == 10 and ab["qtd_saida"] is None


def test_saida_perde_o_sinal_e_ganha_coluna_propria():
    e = erp.parse(planilha_sintetica())
    venda = e.linhas[1]
    assert venda["qtd_saida"] == 2 and venda["qtd_entrada"] is None
    assert venda["custo_saida"] == 54.34
    assert venda["qtd_saldo"] == 8


def test_documento_e_quebrado_em_modelo_serie_numero():
    e = erp.parse(planilha_sintetica())
    venda = e.linhas[1]
    assert (venda["doc_modelo"], venda["doc_serie"], venda["doc_num"]) == ("NFe", "1", "579")
    sem_doc = [l for l in e.linhas if l["tipo"] == "Req p Produção"][0]
    assert sem_doc["doc_num"] is None


def test_numero_com_milhar_e_virgula():
    e = erp.parse(planilha_sintetica())
    transf = [l for l in e.linhas if l["cod_item"] == "20"][0]
    assert transf["custo_entrada"] == 2282.31


def test_confere_acusa_saldo_que_nao_fecha():
    """
    O item 30 abre com 5, sai 1 e o ERP imprime 7. A auditoria não pode usar
    esse número sem dizer que ele não fecha nem com o próprio relatório.
    """
    e = erp.parse(planilha_sintetica())
    probs = erp.confere(e)
    assert [t for t, _ in probs] == ["saldo_nao_fecha"]
    assert "item 30" in probs[0][1]


def test_le_a_coluna_de_ncm_quando_o_erp_a_exporta():
    """
    O relatório é montado pelo usuário do ERP. Acrescentar uma coluna de NCM —
    no meio das outras, inclusive — não pode deslocar a leitura do resto.
    """
    cab = CABECALHO[:5] + ["NCM"] + CABECALHO[5:]
    linhas = [cab] + [l[:5] + ["9405.99.00"] + l[5:] for l in LINHAS[1:]]
    e = erp.parse(planilha_sintetica(linhas))
    assert erp.e_extrato_erp(planilha_sintetica(linhas))
    assert e.linhas[0]["ncm"] == "94059900"     # ponto some, 8 dígitos ficam
    # E o resto continua no lugar, que é o ponto do teste.
    assert e.linhas[1]["doc_num"] == "579"
    assert e.linhas[1]["qtd_saida"] == 2
    assert e.linhas[1]["custo_saida"] == 54.34


def test_ncm_ausente_ou_ilegivel_vira_nulo():
    e = erp.parse(planilha_sintetica())
    assert all(l["ncm"] is None for l in e.linhas)
    cab = CABECALHO + ["Classificação fiscal"]
    linhas = [cab] + [l + ["sem ncm"] for l in LINHAS[1:]]
    assert erp.parse(planilha_sintetica(linhas)).linhas[0]["ncm"] is None


def test_coluna_renomeada_e_reconhecida_pelo_nome():
    """Acento, caixa e espaço não podem decidir se o arquivo é legível."""
    cab = ["Agrupamento", "CH MOV", "Dt Mov", "Hr Mov", "DEPÓSITO",
           "Ref. fabricante", "Ch Doc", "Operação de Origem#Documento",
           "Operação de Origem#Tipo", "Operação de Origem#Entidade",
           "Quantidade#Entrada", "Quantidade#Saída", "Quantidade#Saldo",
           "Custo#Entrada", "Custo#Saída", "Custo#Saldo", "Custo Médio"]
    e = erp.parse(planilha_sintetica([cab] + LINHAS[1:]))
    assert e.itens == 3 and e.linhas[1]["custo_medio"] == 27.17


def test_extrato_sem_problema_nao_inventa_achado():
    linhas = [l for l in LINHAS if not l[0].startswith("30 - ")]
    e = erp.parse(planilha_sintetica(linhas))
    assert erp.confere(e) == []
    assert e.problemas == []
