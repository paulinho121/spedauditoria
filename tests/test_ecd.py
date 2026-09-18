# -*- coding: utf-8 -*-
"""
Leitor da ECD contra um arquivo SINTÉTICO, montado a partir do leiaute oficial.

Não há ECD real no projeto. O arquivo abaixo é mínimo, mas tem as partes que
decidem o resultado: plano de contas com natureza 04, saldos mensais (I155),
um lançamento comum e um de ENCERRAMENTO em dezembro, que zera as contas de
resultado. Os valores esperados foram calculados à mão:

  novembro  vendas 1.000 − CMV 600 − pessoal 300          = +100 (lucro)
  dezembro  vendas   500 − CMV 400 − pessoal 300          = −200 (prejuízo)

O I155 de dezembro inclui o encerramento (vendas com débito de 1.500, custos
com crédito de 1.000 e 600). Sem descontá-lo, dezembro daria zero.
"""
from decimal import Decimal

from auditoria import ecd

LINHAS = """|0000|LECD|01112022|31122022|EMPRESA TESTE LTDA|00000000000191|SP|123|3550308||0|0|0|0||0|G|||N|N|0||
|I010|G|9.00|
|I050|01012020|01|S|1|1||ATIVO|
|I050|01012020|01|A|2|1.1.01|1|CAIXA|
|I050|01012020|03|A|2|2.3.01|1|LUCROS ACUMULADOS|
|I050|01012020|04|S|1|3||RESULTADO|
|I050|01012020|04|S|2|3.1|3|RECEITAS|
|I050|01012020|04|A|3|3.1.01|3.1|RECEITA DE VENDAS DE MERCADORIAS|
|I051||3.01.01.01.01.01|
|I050|01012020|04|S|2|3.2|3|CUSTOS E DESPESAS|
|I050|01012020|04|A|3|3.2.01|3.2|CUSTO DAS MERCADORIAS VENDIDAS|
|I051||3.01.01.03.01.01|
|I050|01012020|04|A|3|3.2.02|3.2|DESPESAS COM PESSOAL|
|I051||3.01.01.05.01.01|
|I150|01112022|30112022|
|I155|1.1.01||0,00|D|1000,00|900,00|100,00|D|
|I155|3.1.01||0,00|C|0,00|1000,00|1000,00|C|
|I155|3.2.01||0,00|D|600,00|0,00|600,00|D|
|I155|3.2.02||0,00|D|300,00|0,00|300,00|D|
|I150|01122022|31122022|
|I155|1.1.01||100,00|D|500,00|700,00|100,00|C|
|I155|3.1.01||1000,00|C|1500,00|500,00|0,00|C|
|I155|3.2.01||600,00|D|400,00|1000,00|0,00|D|
|I155|3.2.02||300,00|D|300,00|600,00|0,00|D|
|I155|2.3.01||0,00|C|100,00|0,00|100,00|D|
|I200|1|15122022|500,00|N||
|I250|1.1.01||500,00|D||||
|I250|3.1.01||500,00|C||||
|I200|2|31122022|1500,00|E||
|I250|3.1.01||1500,00|D||||
|I250|3.2.01||1000,00|C||||
|I250|3.2.02||600,00|C||||
|I250|2.3.01||100,00|D||||
|I350|31122022|
|I355|3.1.01||1500,00|C|
|I355|3.2.01||1000,00|D|
|I355|3.2.02||600,00|D|
|9999|40|
"""


def _arquivo(tmp_path):
    p = tmp_path / "ecd_sintetica.txt"
    p.write_bytes(LINHAS.encode("latin-1"))
    return str(p)


def test_reconhece_ecd(tmp_path):
    assert ecd.e_ecd(_arquivo(tmp_path))


def test_cabecalho_e_plano(tmp_path):
    e = ecd.parse(_arquivo(tmp_path))
    assert e.cnpj == "00000000000191"
    assert str(e.dt_ini) == "2022-11-01" and str(e.dt_fin) == "2022-12-31"
    contas = {c["cod_cta"]: c for c in e.contas}
    assert contas["3.1.01"]["cod_nat"] == "04" and contas["3.1.01"]["ind_cta"] == "A"
    assert contas["3.1.01"]["cod_cta_sup"] == "3.1"
    assert contas["3.1.01"]["cod_cta_ref"] == "3.01.01.01.01.01"
    assert contas["1.1.01"]["cod_cta_ref"] == ""


def test_saldos_com_sinal(tmp_path):
    e = ecd.parse(_arquivo(tmp_path))
    nov = {s["cod_cta"]: s for s in e.saldos if str(s["dt_ini"]) == "2022-11-01"}
    assert nov["3.1.01"]["sl_fin"] == Decimal("-1000.00")      # credor
    assert nov["3.2.01"]["sl_fin"] == Decimal("600.00")        # devedor
    assert nov["3.1.01"]["creditos"] == Decimal("1000.00")


def test_so_o_encerramento_e_guardado(tmp_path):
    e = ecd.parse(_arquivo(tmp_path))
    assert e.lancamentos == 2
    enc = {x["cod_cta"]: x for x in e.encerramento}
    assert set(enc) == {"3.1.01", "3.2.01", "3.2.02", "2.3.01"}
    assert enc["3.1.01"]["debitos"] == Decimal("1500.00")
    assert enc["3.2.01"]["creditos"] == Decimal("1000.00")
    assert str(enc["3.1.01"]["mes"]) == "2022-12-01"


def test_resultado_mensal_sem_encerramento(tmp_path):
    """A mesma conta que o banco faz em ecd_movimento_resultado, em Python."""
    e = ecd.parse(_arquivo(tmp_path))
    resultado = {c["cod_cta"] for c in e.contas if c["cod_nat"] == "04" and c["ind_cta"] == "A"}
    enc = {(str(x["mes"]), x["cod_cta"]): x["creditos"] - x["debitos"] for x in e.encerramento}
    por_mes = {}
    for s in e.saldos:
        if s["cod_cta"] in resultado:
            k = str(s["dt_ini"])
            v = s["creditos"] - s["debitos"] - enc.get((k, s["cod_cta"]), 0)
            por_mes[k] = por_mes.get(k, 0) + v
    assert por_mes["2022-11-01"] == Decimal("100.00")
    assert por_mes["2022-12-01"] == Decimal("-200.00")


def test_confere_sem_problemas_graves(tmp_path):
    tipos = {t for t, _ in ecd.confere(ecd.parse(_arquivo(tmp_path)))}
    assert not {"sem_0000", "sem_saldos", "sem_resultado"} & tipos
