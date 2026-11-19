# -*- coding: utf-8 -*-
"""
Estoque real pelo Kardex do ERP.

Cada teste é uma história curta de um produto, do jeito que ela aparece no
extrato do cliente. O que se confere é a conclusão: que nota precisa de entrada,
que nota precisa de saída, e quanto é o estoque real no fim.

As funções do banco (erp_real_*) fazem a mesma conta em SQL; a regra é esta.
"""
import json

import pytest

from auditoria import carga_erp, erp, estoque_real as er

ARMAZEM, SAIDA_ARMAZEM = "Ent Ret Remet p Dep Fec Armaz", "S Rem Dep Fec Armaz Geral"
VENDA, COMPRA = "V Adq Terc p Consumo", "C p Comercializ EX"


def kardex(*movs, cod="100", descr="Refletor"):
    """(data, documento, tipo, entidade, entrada, saída) -> linhas do leitor."""
    linhas = []
    for n, (dt, doc, tipo, ent, e, s) in enumerate(movs, start=1):
        linhas.append({"seq": n, "abertura": False, "cod_item": cod, "descr_item": descr,
                       "unid": "Un", "dt": dt, "doc_texto": doc, "doc_num": doc[-3:],
                       "tipo": tipo, "entidade": ent,
                       "qtd_entrada": e or None, "qtd_saida": s or None, "qtd_saldo": None})
    return linhas


def um(a):
    assert len(a["produtos"]) == 1
    return a["produtos"][0]


# ------------------------------------------------------------------ natureza

@pytest.mark.parametrize("tipo, esperado", [
    ("Ent Ret Remet p Dep Fec Armaz", "armazem"),      # armazém antes de "ret"
    ("S Rem Dep Fec Armaz Geral", "armazem"),
    ("S Rem Locação", "locacao"), ("Ent Rem Locação", "locacao"),
    ("S Rem Comodato", "comodato"), ("Ent Ret Demonstração", "demonstracao"),
    ("S Rem Exposição", "exposicao"), ("S Ret Conserto", "conserto"),
    ("S Rem AnGarantia", "garantia"),
    ("S Rem Transf AdqTer", "transferencia"), ("Ent Rem Transferência", "transferencia"),
    ("V Adq Terc p Consumo", "venda"), ("S Rem Venda EF", "venda"),
    ("C p Comercializ EX", "compra"), ("S Brinde", "brinde"),
    ("Ent Dev Venda", "devolucao"), ("Req p Produção", "producao"),
    ("NF Correção", "ajuste"), ("E Ajuste Financeiro", "ajuste"),
    ("Ent Simples Remessa", "outros"), (None, "outros"),
])
def test_natureza_sai_do_texto_do_tipo(tipo, esperado):
    assert er.natureza(tipo) == esperado


# ------------------------------------------------------------ o caso que fecha

def test_compra_remessa_retorno_e_venda_fecham():
    a = er.analisa(kardex(
        ("2024-01-10", "NFe 1 001", COMPRA, "Fornecedor", 10, 0),
        ("2024-01-11", "NFe 1 002", SAIDA_ARMAZEM, "Sanco", 0, 10),
        ("2024-02-01", "NFe 2 003", ARMAZEM, "Sanco", 4, 0),
        ("2024-02-01", "NFe 1 004", VENDA, "Cliente", 0, 4)))
    p = um(a)
    assert (p["saldo_erp"], p["em_terceiros"], p["estoque_real"]) == (0, 6, 6)
    assert p["situacao"] == "ok" and p["falta_entrada"] == 0
    assert not a["sem_estoque"] and not a["sem_remessa"]
    # As 6 que ficaram no armazém são da única remessa.
    assert [(n["doc_texto"], n["pendente"]) for n in a["em_terceiros"]] == [("NFe 1 002", 6)]


# --------------------------------------------- precisa de ENTRADA: saída sem saldo

def test_venda_antes_do_retorno_precisa_de_entrada_e_depois_e_coberta():
    """O caso mais comum do extrato: vende, e só dias depois emite o retorno."""
    a = er.analisa(kardex(
        ("2024-01-10", "NFe 1 001", COMPRA, "Fornecedor", 5, 0),
        ("2024-01-11", "NFe 1 002", SAIDA_ARMAZEM, "Sanco", 0, 5),
        ("2024-03-01", "NFe 1 010", VENDA, "Cliente", 0, 2),         # depósito vazio
        ("2024-03-04", "NFe 2 011", ARMAZEM, "Sanco", 2, 0)))        # o retorno atrasado
    (n,) = a["sem_estoque"]
    assert n["doc_texto"] == "NFe 1 010" and n["descoberto"] == 2
    assert n["coberta_em"] == "2024-03-04" and n["coberta_doc"] == "NFe 2 011"
    assert n["coberta_natureza"] == "armazem"
    # Atraso de documento não muda o estoque: 3 seguem no armazém.
    p = um(a)
    assert p["estoque_real"] == 3 and p["situacao"] == "ficou_negativo"


def test_saida_sem_entrada_nenhuma_fica_em_aberto_e_falta_entrada():
    a = er.analisa(kardex(("2024-05-02", "NFe 1 020", VENDA, "Cliente", 0, 3)))
    (n,) = a["sem_estoque"]
    assert n["coberta_em"] is None and n["descoberto"] == 3
    p = um(a)
    assert p["saldo_erp"] == -3 and p["falta_entrada"] == 3 and p["estoque_real"] == 0
    assert p["situacao"] == "falta_entrada"
    assert a["resumo"]["sem_estoque_abertas"] == 1


def test_so_a_parte_descoberta_da_saida_conta():
    a = er.analisa(kardex(
        ("2024-01-10", "NFe 1 001", COMPRA, "Fornecedor", 2, 0),
        ("2024-01-12", "NFe 1 002", VENDA, "Cliente", 0, 5)))        # 2 havia, 3 não
    assert a["sem_estoque"][0]["descoberto"] == 3


def test_deposito_negativo_com_mercadoria_no_armazem_nao_e_falta_de_entrada():
    """Vendeu direto do armazém e nunca emitiu o retorno: falta a nota, não a mercadoria."""
    a = er.analisa(kardex(
        ("2024-01-10", "NFe 1 001", COMPRA, "Fornecedor", 10, 0),
        ("2024-01-11", "NFe 1 002", SAIDA_ARMAZEM, "Sanco", 0, 10),
        ("2024-02-01", "NFe 1 004", VENDA, "Cliente", 0, 4)))
    p = um(a)
    assert p["saldo_erp"] == -4 and p["em_terceiros"] == 10
    assert p["estoque_real"] == 6 and p["falta_entrada"] == 0
    assert p["situacao"] == "negativo_hoje"


# ----------------------------------------- precisa de SAÍDA: retorno sem remessa

def test_retorno_do_que_ja_estava_no_armazem_precisa_de_saida():
    """O ERP começou sem saldo inicial: a mercadoria volta de onde nunca 'foi'."""
    a = er.analisa(kardex(
        ("2023-08-10", "NFe 2 030", ARMAZEM, "Gold Sea", 8, 0),
        ("2023-08-11", "NFe 1 031", VENDA, "Cliente", 0, 8)))
    (n,) = a["sem_remessa"]
    assert n["doc_texto"] == "NFe 2 030" and n["sem_lastro"] == 8 and n["coberta_em"] is None
    p = um(a)
    assert p["retorno_sem_remessa"] == 8 and p["em_terceiros"] == 0
    assert p["estoque_real"] == 0 and p["situacao"] == "retorno_sem_remessa"
    assert not a["sem_estoque"]


def test_retorno_sem_remessa_que_fica_no_deposito_e_estoque_real():
    a = er.analisa(kardex(("2023-08-10", "NFe 2 030", ARMAZEM, "Gold Sea", 8, 0)))
    p = um(a)
    # O que voltou a mais já está no saldo; não se soma de novo nem se desconta.
    assert p["saldo_erp"] == 8 and p["estoque_real"] == 8


def test_cada_terceiro_tem_a_sua_conta():
    """Sobra num armazém não cobre o que voltou a mais de outro."""
    a = er.analisa(kardex(
        ("2024-01-10", "NFe 1 001", COMPRA, "Fornecedor", 5, 0),
        ("2024-01-11", "NFe 1 002", SAIDA_ARMAZEM, "Sanco", 0, 5),
        ("2024-01-20", "NFe 2 003", ARMAZEM, "Gold Sea", 3, 0)))
    p = um(a)
    assert p["em_terceiros"] == 5 and p["retorno_sem_remessa"] == 3
    assert p["estoque_real"] == 8                # 3 no depósito + 5 no Sanco
    assert [n["entidade"] for n in a["sem_remessa"]] == ["Gold Sea"]


def test_retorno_adiantado_e_coberto_pela_remessa_que_veio_depois():
    a = er.analisa(kardex(
        ("2024-01-10", "NFe 2 040", ARMAZEM, "Sanco", 2, 0),
        ("2024-01-15", "NFe 1 041", SAIDA_ARMAZEM, "Sanco", 0, 2)))
    (n,) = a["sem_remessa"]
    assert n["coberta_em"] == "2024-01-15" and n["coberta_doc"] == "NFe 1 041"
    assert um(a)["em_terceiros"] == 0


# ------------------------------------------------------ remessa sem retorno (FIFO)

def test_retorno_quita_a_remessa_mais_antiga_primeiro():
    a = er.analisa(kardex(
        ("2024-01-10", "NFe 1 001", COMPRA, "Fornecedor", 10, 0),
        ("2024-01-11", "NFe 1 002", SAIDA_ARMAZEM, "Sanco", 0, 4),
        ("2024-02-11", "NFe 1 003", SAIDA_ARMAZEM, "Sanco", 0, 6),
        ("2024-03-01", "NFe 2 004", ARMAZEM, "Sanco", 5, 0)))
    # 5 voltaram: quitam as 4 da primeira e 1 da segunda. Sobram 5 da segunda.
    assert [(n["doc_texto"], n["pendente"]) for n in a["em_terceiros"]] == [("NFe 1 003", 5)]


def test_locacao_comodato_e_armazem_somam_por_natureza():
    a = er.analisa(kardex(
        ("2024-01-10", "NFe 1 001", COMPRA, "Fornecedor", 10, 0),
        ("2024-01-11", "NFe 1 002", SAIDA_ARMAZEM, "Sanco", 0, 3),
        ("2024-01-12", "NFe 1 003", "S Rem Locação", "Locadora", 0, 2),
        ("2024-01-13", "NFe 1 004", "S Rem Comodato", "Estúdio", 0, 1)))
    p = um(a)
    assert p["por_natureza"] == {"armazem": 3, "locacao": 2, "comodato": 1}
    assert p["saldo_erp"] == 4 and p["estoque_real"] == 10


# ------------------------------------------------- o que não pode enganar a conta

def test_lancamento_errado_e_estornado_nao_cria_estoque():
    """Caso real: 1.181,65 unidades transferidas num dia e devolvidas no mês seguinte."""
    a = er.analisa(kardex(
        ("2024-04-01", "NFe 1 001", COMPRA, "Fornecedor", 4, 0),
        ("2024-04-29", "NFe 1 962", "S Rem Transf AdqTer", "EST MCI SP", 0, 1181.65),
        ("2024-05-31", "NFe 1 899", "Ent Rem Transferência", "EST MCI SP", 1181.65, 0)))
    p = um(a)
    assert p["estoque_real"] == pytest.approx(4) and p["falta_entrada"] == 0
    assert p["menor_saldo"] == pytest.approx(-1177.65)      # o tropeço continua visível
    assert a["sem_estoque"][0]["doc_texto"] == "NFe 1 962"


def test_mesmo_codigo_em_dois_cadastros_sao_dois_produtos():
    linhas = (kardex(("2024-01-10", "NFe 1 001", COMPRA, "F", 4, 0), descr="Mini LED Amar")
              + kardex(("2024-01-10", "NFe 1 001", COMPRA, "F", 25, 0),
                       descr="Mini LED Amaran AL-MW"))
    a = er.analisa(linhas)
    assert sorted(p["estoque_real"] for p in a["produtos"]) == [4, 25]


def test_nome_do_terceiro_com_caixa_ou_espaco_diferente_e_o_mesmo():
    a = er.analisa(kardex(
        ("2024-01-10", "NFe 1 001", COMPRA, "F", 5, 0),
        ("2024-01-11", "NFe 1 002", SAIDA_ARMAZEM, "Sanco Armazéns  Ltda", 0, 5),
        ("2024-02-01", "NFe 2 003", ARMAZEM, "SANCO ARMAZÉNS LTDA", 5, 0)))
    assert um(a)["em_terceiros"] == 0 and not a["sem_remessa"]


def test_resumo_conta_nota_e_nao_linha():
    linhas = (kardex(("2024-05-02", "NFe 1 020", VENDA, "Cliente", 0, 3), cod="1")
              + kardex(("2024-05-02", "NFe 1 020", VENDA, "Cliente", 0, 1), cod="2"))
    r = er.analisa(linhas)["resumo"]
    assert r["sem_estoque_linhas"] == 2 and r["sem_estoque_notas"] == 1
    assert r["sem_estoque_qtd"] == 4 and r["falta_entrada"] == 4


# ----------------------------------------------------- o extrato exportado em JSON

REG = {"columnchMov0": "745194", "columndtMov1": "25/07/2024", "columnhrMov2": "08:15:50",
       "columndeposito3": "DEP MCI SC", "columnrefFabricante4": None, "columnchDoc5": "745183",
       "columnoperacaoDeOrigemDocumento6": "NFe 2 000000865",
       "columnoperacaoDeOrigemTipo7": ARMAZEM,
       "columnoperacaoDeOrigemEntidade8": "Gold Sea Log Ltda",
       "columnquantidadeEntrada9": "1", "columnquantidadeSaida10": None,
       "columnquantidadeSaldo11": "1", "columncustoEntrada12": "437,28",
       "columncustoSaida13": None, "columncustoSaldo14": "437,28", "columncustoMed15": "437,28",
       "_000GROUP": "3936 - 18leaf Iris - Controle de Tamanho - Un"}
SAIDA = dict(REG, columnchMov0="714073", columnhrMov2="15:26",
             columnoperacaoDeOrigemDocumento6="NFe 1 000559608",
             columnoperacaoDeOrigemTipo7=VENDA,
             columnoperacaoDeOrigemEntidade8="Atilla",
             columnquantidadeEntrada9=None, columnquantidadeSaida10="-1",
             columnquantidadeSaldo11="0", columncustoEntrada12=None, columncustoSaida13="0")


def extrato_json(tmp_path, regs, nome="Extrato (20261113_152434).json"):
    caminho = tmp_path / nome
    caminho.write_text(json.dumps(regs, ensure_ascii=False), encoding="utf-8")
    return str(caminho)


def test_extrato_em_json_e_reconhecido_e_lido_como_a_planilha(tmp_path):
    caminho = extrato_json(tmp_path, [REG, SAIDA])
    assert erp.e_extrato_erp(caminho)
    e = erp.parse(caminho)
    assert (e.dt_ini, e.dt_fin, e.depositos) == ("2024-07-01", "2024-07-31", ["DEP MCI SC"])
    l1, l2 = e.linhas
    assert (l1["cod_item"], l1["unid"]) == ("3936", "Un")
    assert l1["descr_item"] == "18leaf Iris - Controle de Tamanho"     # ' - ' no meio fica
    assert (l1["doc_modelo"], l1["doc_serie"], l1["doc_num"]) == ("NFe", "2", "865")
    assert l1["qtd_entrada"] == 1 and l1["custo_entrada"] == 437.28
    # A saída vem negativa no relatório e é guardada positiva, na coluna dela.
    assert l2["qtd_saida"] == 1 and l2["qtd_entrada"] is None and l2["seq"] == 2
    assert not erp.confere(e)


def test_saldo_de_produtos_nao_e_confundido_com_extrato(tmp_path):
    saldo = [{"columnprodutoCodigo2": "3311", "columnsaldo7": "1",
              "columndeposito1": "DEP MCI SC"}]
    assert not erp.e_extrato_erp(extrato_json(tmp_path, saldo, "Saldo de produtos.json"))


def test_dois_cadastros_do_mesmo_codigo_nao_acusam_saldo_que_nao_fecha(tmp_path):
    outro = dict(REG, _000GROUP="3936 - Iris antiga - Un", columnquantidadeSaldo11="1")
    assert not erp.confere(erp.parse(extrato_json(tmp_path, [REG, outro])))


def test_extrato_grande_vai_em_partes_e_so_a_ultima_publica():
    p = {"arquivo": {"sha256": "abc", "linhas": 5}, "linhas": [{"seq": i} for i in range(5)]}
    ps = list(carga_erp.partes(p, lote=2))
    assert [len(x["linhas"]) for x in ps] == [2, 2, 1]
    assert [(x["arquivo"]["parte"], x["arquivo"]["partes"]) for x in ps] == [(1, 3), (2, 3), (3, 3)]
    assert all(x["arquivo"]["sha256"] == "abc" for x in ps)
    assert [l["seq"] for x in ps for l in x["linhas"]] == [0, 1, 2, 3, 4]    # nada some


# ------------------------------------------------------------- a posição numa data

from auditoria import estoque_real as er2


def base_de(*movs, cod="100", descr="Refletor"):
    """As linhas como erp_real_linha as devolve: o que posicao() lê."""
    out = []
    for n, (dt, doc, tipo, ent, e, s) in enumerate(movs, start=1):
        out.append({"seq": n, "cod_item": cod, "descr_item": descr, "unid": "Un", "dt": dt,
                    "doc_texto": doc, "doc_num": doc[-3:], "tipo": tipo, "entidade": ent,
                    "ent": e, "sai": s, "saldo_impresso": None, "custo_entrada": None})
    return out


def test_posicao_na_data_ignora_o_que_veio_depois():
    base = base_de(
        ("2024-01-10", "NFe 1 001", COMPRA, "Fornecedor", 10, 0),
        ("2024-01-11", "NFe 1 002", SAIDA_ARMAZEM, "Sanco", 0, 10),
        ("2024-03-01", "NFe 2 003", ARMAZEM, "Sanco", 4, 0))
    em_fev = er2.posicao(base, "2024-02-28")["produtos"][0]
    assert (em_fev["saldo_erp"], em_fev["em_terceiros"], em_fev["estoque_real"]) == (0, 10, 10)
    depois = er2.posicao(base, "2024-03-01")["produtos"][0]
    # 4 voltaram ao depósito e 6 continuam no armazém: a posição é 10.
    assert (depois["saldo_erp"], depois["em_terceiros"], depois["estoque_real"]) == (4, 6, 10)


def test_posicao_sem_data_e_a_posicao_final():
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 4, 0),
                   ("2024-01-12", "NFe 1 002", VENDA, "C", 0, 1))
    assert er2.posicao(base)["produtos"][0]["estoque_real"] == 3


def test_custo_da_posicao_vem_da_ultima_compra_ate_a_data():
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 2, 0),
                   ("2024-02-10", "NFe 1 002", COMPRA, "F", 2, 0),
                   ("2024-03-10", "NFe 1 003", COMPRA, "F", 2, 0))
    for l, c in zip(base, (200.0, 300.0, 450.0)):
        l["custo_entrada"] = c
    assert er2.posicao(base, "2024-02-15")["produtos"][0]["custo"] == 150.0
    assert er2.posicao(base, "2024-03-15")["produtos"][0]["custo"] == 225.0


def test_valor_da_posicao_arredonda_como_o_banco():
    """Meio centavo sobe, como o round() do banco: 10,005 vira 10,01, não 10,00."""
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 1, 0))
    base[0]["custo_entrada"] = 10.005
    p = er2.posicao(base)["produtos"][0]
    assert p["valor_real"] == 10.01
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 12, 0))
    base[0]["custo_entrada"] = 2191.09
    p = er2.posicao(base)["produtos"][0]
    assert p["valor_real"] == 2191.09 and p["custo"] == 182.5908


def test_foto_do_erp_traz_ncm_e_custo_declarado_na_data():
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 3, 0))
    foto = [{"cod_item": "100", "descr_item": "Refletor", "ncm": "94054200", "custo_unit": 0, "qtd": 3}]
    p = er2.posicao(base, None, foto)["produtos"][0]
    assert p["ncm"] == "94054200" and p["custo_erp"] is None      # custo zero no ERP não vale


# ------------------------------------------------------------- fechamento por data

def _fech(*rows):
    return er2.fechamento_de(list(rows))


def _rowf(tipo, **k):
    base = {"tipo": tipo, "cod_item": None, "descr_item": "", "campo": None, "qtd": None,
            "doc_texto": None, "dt": None, "nota_tipo": None, "entidade": None}
    base.update(k)
    return base


def test_excluir_nota_tira_os_movimentos_do_calculo():
    base = base_de(
        ("2024-01-10", "NFe 1 001", COMPRA, "Fornecedor", 10, 0),
        ("2024-01-12", "NFe 1 099", VENDA, "Cliente errado", 0, 4),   # emitida por engano
        ("2024-01-13", "NFe 1 002", VENDA, "Cliente", 0, 3))
    antes = er2.posicao(base)["produtos"][0]
    assert antes["saldo_erp"] == 3
    f = _fech(_rowf("nota", doc_texto="NFe 1 099", dt="2024-01-12", nota_tipo=VENDA, entidade="Cliente errado"))
    depois = er2.posicao(base, None, None, f)
    assert depois["produtos"][0]["saldo_erp"] == 7
    assert depois["resumo"]["excluidas_notas"] == 1
    assert all(n["doc_texto"] != "NFe 1 099" for n in depois["sem_estoque"])


def test_excluir_produto_tira_o_item_do_relatorio_e_do_total():
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 4, 0)) + \
           base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 5, 0), cod="200", descr="Outro")
    f = _fech(_rowf("produto", cod_item="200", descr_item="Outro"))
    r = er2.posicao(base, None, None, f)
    assert [p["cod_item"] for p in r["produtos"]] == ["100"]
    assert r["resumo"]["estoque_real"] == 4 and r["resumo"]["produtos"] == 1
    assert r["resumo"]["excluidos_produtos"] == 1


def test_correcao_de_quantidade_refaz_o_estoque_e_o_valor_e_guarda_o_original():
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 10, 0))
    base[0]["custo_entrada"] = 100.0
    f = _fech(_rowf("ajuste", cod_item="100", descr_item="Refletor", campo="saldo_erp", qtd=7))
    p = er2.posicao(base, None, None, f)["produtos"][0]
    assert p["saldo_erp"] == 7 and p["estoque_real"] == 7 and p["valor_real"] == 70.0  # 10 un a R$ 10
    assert p["ajuste_orig"] == {"saldo_erp": 10.0}
    assert p["ajuste_orig"] is not None and "ajuste_orig" not in er2.posicao(base)["produtos"][0]


def test_correcao_em_componente_terceiro_muda_o_que_esta_fora():
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 10, 0),
                   ("2024-01-11", "NFe 1 002", SAIDA_ARMAZEM, "Sanco", 0, 6))
    f = _fech(_rowf("ajuste", cod_item="100", descr_item="Refletor", campo="em_armazem", qtd=2))
    p = er2.posicao(base, None, None, f)["produtos"][0]
    assert p["em_terceiros"] == 2 and p["saldo_erp"] == 4 and p["estoque_real"] == 6


def test_montar_fechamento_valida_e_normaliza():
    acao, p = er2.montar_fechamento({"acao": "gravar", "tipo": "ajuste", "cod": "100",
                                     "descr": "Refletor", "campo": "saldo_erp", "qtd": "4,5"})
    assert acao == "gravar" and p["qtd"] == 4.5 and p["chave"] == er2.chave_fechamento(
        "ajuste", cod="100", descr="Refletor", campo="saldo_erp")
    acao, p = er2.montar_fechamento({"acao": "gravar", "tipo": "ajuste", "cod": "100", "campo": "saldo_erp", "qtd": ""})
    assert acao == "remover"                       # quantidade vazia desfaz
    acao, p = er2.montar_fechamento({"acao": "gravar", "tipo": "nota", "doc": "NFe 1 020",
                                     "dt": "2024-05-02", "ntipo": VENDA, "entidade": "Cliente"})
    assert acao == "gravar" and p["dt"] == "2024-05-02" and p["entidade"] == "Cliente"
    assert er2.montar_fechamento({"acao": "limpar"}) == ("limpar", {})
    for ruim in ({"tipo": "ajuste", "campo": "x", "qtd": 1}, {"tipo": "ajuste", "campo": "saldo_erp", "qtd": "abc"},
                 {"tipo": "nota", "doc": ""}, {"tipo": "coisa"}, {"acao": "apagar_tudo", "tipo": "nota"}):
        with pytest.raises(ValueError):
            er2.montar_fechamento(ruim)


def test_chave_do_fechamento_e_estavel_e_separa_os_itens():
    a = er2.chave_fechamento("nota", doc="NFe 1 020", dt="2024-05-02", ntipo=VENDA, ent="C")
    assert a == er2.chave_fechamento("nota", doc="NFe 1 020", dt="2024-05-02", ntipo=VENDA, ent="C")
    assert a != er2.chave_fechamento("nota", doc="NFe 1 020", dt="2024-05-03", ntipo=VENDA, ent="C")
    assert er2.chave_fechamento("ajuste", cod="1", descr="x", campo="saldo_erp") != \
        er2.chave_fechamento("ajuste", cod="1", descr="x", campo="em_armazem")


def test_correcao_da_posicao_final_vale_em_qualquer_data():
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 10, 0),
                   ("2024-03-10", "NFe 1 002", COMPRA, "F", 5, 0))
    final = [_rowf("ajuste", cod_item="100", descr_item="Refletor", campo="saldo_erp", qtd=0)]
    em_fev = er2.posicao(base, "2024-02-28", None, er2.fechamento_de(final))["produtos"][0]
    em_abr = er2.posicao(base, "2024-04-30", None, er2.fechamento_de(final))["produtos"][0]
    assert em_fev["saldo_erp"] == 0 and em_fev["ajuste_orig"] == {"saldo_erp": 10.0}
    assert em_abr["saldo_erp"] == 0 and em_abr["estoque_real"] == 0


def test_correcao_de_uma_data_passa_por_cima_da_final():
    base = base_de(("2024-01-10", "NFe 1 001", COMPRA, "F", 10, 0))
    final = [_rowf("ajuste", cod_item="100", descr_item="Refletor", campo="saldo_erp", qtd=0)]
    naData = [_rowf("ajuste", cod_item="100", descr_item="Refletor", campo="saldo_erp", qtd=7)]
    p = er2.posicao(base, "2024-02-28", None, er2.fechamento_de(final + naData))["produtos"][0]
    assert p["saldo_erp"] == 7
    # Sem a correção desta data, volta a valer a da posição final.
    q = er2.posicao(base, "2024-02-28", None, er2.fechamento_de(final))["produtos"][0]
    assert q["saldo_erp"] == 0
