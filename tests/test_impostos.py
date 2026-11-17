# -*- coding: utf-8 -*-
"""
Tratamento de impostos: a linha de cada item do ponto de vista da filial, e as
conferências que apontam onde o imposto destacado não fecha.

Cada teste monta uma nota curta, do jeito que ela chega do banco — às vezes com
número em texto, como devolve a API de administração.
"""
import pytest

from auditoria import impostos as im

SC, SP, CE = "05502390000200", "05502390000383", "05502390000111"
FILIAIS = [{"cnpj": SC, "uf": "SC", "nome": "MCI SC"}, {"cnpj": SP, "uf": "SP", "nome": "MCI SP"},
           {"cnpj": CE, "uf": "CE", "nome": "MCI CE"}]


def nota(id_, emit=SC, dest="11111111000191", tp="1", emit_uf="SC", dest_uf="PR", dt="2025-03-10",
         situacao="autorizada"):
    return {"id": id_, "chave": f"{id_:044d}", "num_nf": str(id_), "serie": "1", "dt_emi": dt,
            "tp_nf": tp, "fin_nfe": "1", "nat_op": "VENDA", "emit_cnpj": emit, "emit_nome": "Emitente",
            "emit_uf": emit_uf, "dest_doc": dest, "dest_nome": "Destinatário", "dest_uf": dest_uf,
            "situacao": situacao}


def item(id_, nfe_id, cfop="6102", ncm="94054200", v_prod=1000, n=1, **extra):
    d = {"id": id_, "nfe_id": nfe_id, "n_item": n, "c_prod": f"P{id_}", "x_prod": "Luminária",
         "ncm": ncm, "cfop": cfop, "u_com": "UN", "q_com": 1, "v_un_com": v_prod, "v_prod": v_prod}
    d.update(extra)
    return d


def imposto(item_id, **t):
    return {"nfe_item_id": item_id, **t}


def linhas(notas, itens, imps):
    return im.monta(notas, itens, imps, FILIAIS)


def um(notas, itens, imps):
    (l,) = linhas(notas, itens, imps)
    return l


# ------------------------------------------------------- ponto de vista da filial

def test_saida_emitida_pela_filial():
    l = um([nota(1)], [item(10, 1)], [imposto(10, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=4, icms_v=40)])
    assert (l["filial"], l["filial_uf"], l["fluxo"], l["operacao"]) == (SC, "SC", "saida", "interestadual")
    assert l["part_doc"] == "11111111000191" and l["part_uf"] == "PR"
    assert l["tributos"] == 40 and l["carga"] == 4.0 and l["alertas"] == []


def test_nota_de_terceiro_recebida_e_entrada():
    l = um([nota(1, emit="22222222000191", dest=SP, emit_uf="MG", dest_uf="SP")],
           [item(10, 1, cfop="6102")], [imposto(10, icms_cst="00", icms_orig="0", icms_vbc=1000, icms_p=12, icms_v=120)])
    assert (l["filial_uf"], l["fluxo"], l["propria"]) == ("SP", "entrada", False)
    assert l["part_doc"] == "22222222000191" and l["part_uf"] == "MG"
    assert l["alertas"] == []            # a alíquota interestadual só se cobra na saída própria


def test_importacao_emitida_pela_filial_e_entrada_do_exterior():
    l = um([nota(1, dest="", tp="0", dest_uf="EX")], [item(10, 1, cfop="3102")],
           [imposto(10, icms_cst="51", ii_v=150, ipi_vbc=1150, ipi_p=10, ipi_v=115)])
    assert (l["fluxo"], l["operacao"]) == ("entrada", "exterior")
    assert l["tributos"] == 265


def test_transferencia_entre_filiais_aparece_uma_vez_pela_emitente():
    ls = linhas([nota(1, dest=SP, dest_uf="SP")], [item(10, 1, cfop="6152")], [imposto(10, icms_cst="00")])
    assert len(ls) == 1 and ls[0]["filial_uf"] == "SC" and ls[0]["transferencia"]


def test_numero_em_texto_vale_como_numero():
    l = um([nota(1)], [item(10, 1, v_prod="1000.00", v_desc="100.00", v_frete="50")],
           [imposto(10, icms_cst="00", icms_orig="1", icms_vbc="950.00", icms_p="4.0000", icms_v="38.00")])
    assert l["v_oper"] == 950 and l["icms_v"] == 38 and l["alertas"] == []


# ------------------------------------------------------------------- a conta

def test_icms_que_nao_fecha_e_apontado_e_centavo_nao():
    ok = um([nota(1)], [item(10, 1)], [imposto(10, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=4, icms_v=40.03)])
    ruim = um([nota(1)], [item(10, 1)], [imposto(10, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=4, icms_v=48)])
    assert "icms_nao_fecha" not in ok["alertas"] and "icms_nao_fecha" in ruim["alertas"]


def test_importacao_confere_na_nota_contando_a_base_da_adicao_uma_vez():
    """O ERP repete a base da adição em cada linha e reparte o valor: na nota, fecha."""
    n = [nota(1, dest="", tp="0", dest_uf="EX")]
    its = [item(10, 1, cfop="3102", n=1), item(11, 1, cfop="3102", n=2)]
    imps = [imposto(i, icms_cst="51", ipi_vbc=10000, ipi_p=10, ipi_v=500,
                    pis_vbc=8000, pis_p=2.1, pis_v=84, cofins_vbc=8000, cofins_p=9.65, cofins_v=386)
            for i in (10, 11)]
    ls = linhas(n, its, imps)
    assert all(l["alertas"] == [] for l in ls)                 # nem por item, nem por nota
    assert ls[0]["nota_ipi_calc"] == 1000 and ls[0]["nota_ipi_dest"] == 1000


def _imp(*imps, cfop="3102"):
    """Uma nota de importação com uma linha por imposto passado."""
    n = [nota(1, dest="", tp="0", dest_uf="EX")]
    its = [item(10 + i, 1, cfop=cfop, n=i + 1, v_prod=imp.pop("_v", 1000)) for i, imp in enumerate(imps)]
    ims = [imposto(10 + i, icms_cst="51", **imp) for i, imp in enumerate(imps)]
    return im.monta(n, its, ims, FILIAIS, com_contas=True)


PIS_COF = lambda b, pv, cv, pp=2.1, cp=9.65: dict(pis_vbc=b, pis_p=pp, pis_v=pv, cofins_vbc=b, cofins_p=cp, cofins_v=cv)


def test_pis_cofins_zerado_com_base_cheia_e_beneficio_e_nao_alerta():
    ls, contas = _imp(PIS_COF(8000, 0, 0), PIS_COF(500, 10.5, 48.25))
    zero = next(l for l in ls if l["n_item"] == 1)
    assert zero["beneficio"] == "PIS/COFINS zero"
    assert zero["pis_dispensado"] == 168.0 and zero["cofins_dispensado"] == 772.0
    assert zero["dispensado"] == 940.0
    assert all("importacao_pis_cofins_nao_fecha" not in l["alertas"] for l in ls)
    c = contas[1]["pis"]
    assert (c["calc"], c["dest"], c["dispensado"], c["fecha"]) == (178.5, 10.5, 168.0, True)


def test_pis_cofins_pagando_10_por_cento_e_beneficio():
    ls, contas = _imp(PIS_COF(10000, 21.0, 96.5))
    (l,) = ls
    assert l["beneficio"] == "PIS/COFINS 10%" and l["pis_classe"] == "beneficio_10"
    assert l["pis_dispensado"] == 189.0 and l["cofins_dispensado"] == 868.5
    assert contas[1]["cofins"]["adicoes"][0]["via"] == "valor"


def test_beneficio_declarado_na_aliquota_e_medido_contra_a_normal():
    """A nota já traz 0,21% e 0,965%: fecha com a alíquota dela, e é benefício."""
    ls, contas = _imp(PIS_COF(10000, 21.0, 96.5, pp=0.21, cp=0.965))
    (l,) = ls
    assert l["beneficio"] == "PIS/COFINS 10%"
    a = contas[1]["pis"]["adicoes"][0]
    assert (a["via"], a["calc"], a["cheio"], a["dispensado"]) == ("aliquota", 21.0, 210.0, 189.0)
    assert contas[1]["pis"]["fecha"] and l["alertas"] == []


def test_aliquota_zero_com_base_e_beneficio_zero():
    ls, contas = _imp(PIS_COF(10000, 0, 0, pp=0, cp=0))
    assert ls[0]["beneficio"] == "PIS/COFINS zero" and ls[0]["dispensado"] == 1175.0


def test_diferenca_que_nao_e_integral_nem_beneficio_continua_alerta():
    ls, contas = _imp(PIS_COF(10000, 105.0, 482.5))           # pagou a metade
    (l,) = ls
    assert not l.get("beneficio") and l["pis_classe"] == "nao_fecha"
    assert "importacao_pis_cofins_nao_fecha" in l["alertas"]
    assert contas[1]["pis"]["nao_explicado"] == -105.0


def test_itens_iguais_contam_a_base_uma_vez_por_item():
    """Mesma base em duas linhas, cada uma com o seu valor: são dois itens, não uma adição."""
    ls, contas = _imp(dict(PIS_COF(1000, 21.0, 96.5), _v=1000), dict(PIS_COF(1000, 21.0, 96.5), _v=1000))
    a = contas[1]["pis"]["adicoes"][0]
    assert a["vezes"] == 2 and a["calc"] == 42.0 and a["classe"] == "integral"
    assert all(l["alertas"] == [] and not l.get("beneficio") for l in ls)


def test_adicao_repetida_conta_a_base_uma_vez():
    """A base é a da adição (≈ soma das linhas) e o valor foi repartido."""
    ls, contas = _imp(dict(PIS_COF(2000, 21.0, 96.5), _v=1000), dict(PIS_COF(2000, 21.0, 96.5), _v=1000))
    a = contas[1]["pis"]["adicoes"][0]
    assert a["vezes"] == 1 and a["calc"] == 42.0 and a["classe"] == "integral"


def test_dispensado_da_adicao_e_repartido_pelo_valor_das_linhas():
    ls, contas = _imp(dict(PIS_COF(4000, 0, 0), _v=3000), dict(PIS_COF(4000, 0, 0), _v=1000))
    por = {l["n_item"]: l["pis_dispensado"] for l in ls}
    assert por == {1: 63.0, 2: 21.0} and contas[1]["pis"]["dispensado"] == 84.0


def test_resumo_soma_o_beneficio():
    n = [nota(1, dest="", tp="0", dest_uf="EX")]
    p = im.pacote(n, [item(10, 1, cfop="3102")], [imposto(10, icms_cst="51", **PIS_COF(10000, 0, 0))], FILIAIS)
    r = p["resumo"]
    assert (r["beneficio_itens"], r["beneficio_notas"], r["beneficio_dispensado"]) == (1, 1, 1175.0)
    assert p["importacoes"]["1"]["cofins"]["adicoes"][0]["classe"] == "beneficio_zero"
    assert p["classes"]["beneficio_10"].startswith("benefício")


# --------------------------------------------------------------- CST e alíquota

def test_cst_tributado_sem_icms_e_isento_com_icms():
    a = um([nota(1)], [item(10, 1)], [imposto(10, icms_cst="00", icms_orig="1", icms_v=0)])
    b = um([nota(1)], [item(10, 1)], [imposto(10, icms_cst="40", icms_orig="1", icms_vbc=1000, icms_p=4, icms_v=40)])
    assert "cst_tributado_sem_icms" in a["alertas"] and "cst_isento_com_icms" in b["alertas"]


def test_csosn_do_simples_nao_e_lido_como_cst():
    l = um([nota(1, emit="33333333000191", dest=SC, emit_uf="SC", dest_uf="SC")], [item(10, 1, cfop="5102")],
           [imposto(10, icms_grupo="ICMSSN102", icms_cst="400", icms_orig="0")])
    assert l["alertas"] == []                                   # 400 não é o CST 00


@pytest.mark.parametrize("orig, uf_dest, aliq, alerta", [
    ("1", "PR", 4, None), ("1", "PR", 12, "interestadual_importado"),
    ("2", "BA", 4, None), ("0", "PR", 12, None), ("0", "BA", 7, None),
    ("0", "BA", 12, "interestadual_nacional"), ("0", "ES", 7, None),
])
def test_aliquota_interestadual(orig, uf_dest, aliq, alerta):
    l = um([nota(1, dest_uf=uf_dest)], [item(10, 1)],
           [imposto(10, icms_cst="00", icms_orig=orig, icms_vbc=1000, icms_p=aliq, icms_v=10 * aliq)])
    assert ([a for a in l["alertas"] if a.startswith("interestadual")] or [None]) == [alerta]


def test_venda_a_nao_contribuinte_de_outra_uf_sem_difal():
    sem = um([nota(1)], [item(10, 1, cfop="6108")],
             [imposto(10, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=4, icms_v=40)])
    com = um([nota(1)], [item(10, 1, cfop="6108")],
             [imposto(10, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=4, icms_v=40,
                      difal_vbc=1000, difal_p_dest=19.5, difal_p_inter=4, difal_v=155)])
    assert "sem_difal" in sem["alertas"] and "sem_difal" not in com["alertas"]
    assert com["tributos"] == 195


def test_aliquota_fora_do_padrao_do_ncm_com_tolerancia_de_arredondamento():
    n = [nota(i) for i in range(1, 8)]
    aliqs = [4, 4, 4, 4, 4, 4.01, 12]                         # 4,01 é o 4 arredondado
    its = [item(10 + i, i) for i in range(1, 8)]
    imps = [imposto(10 + i, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=p, icms_v=10 * p)
            for i, p in zip(range(1, 8), aliqs)]
    ls = {l["id"]: l for l in linhas(n, its, imps)}
    assert "aliquota_icms_fora_do_ncm" in ls[17]["alertas"] and ls[17]["icms_p_padrao"] == 4.0
    assert "aliquota_icms_fora_do_ncm" not in ls[16]["alertas"]


def test_grupo_sem_padrao_claro_nao_acusa_ninguem():
    n = [nota(i) for i in range(1, 7)]
    its = [item(10 + i, i) for i in range(1, 7)]
    imps = [imposto(10 + i, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=p, icms_v=10 * p)
            for i, p in zip(range(1, 7), [4, 4, 4, 12, 12, 12])]
    assert all("aliquota_icms_fora_do_ncm" not in l["alertas"] for l in linhas(n, its, imps))


# ------------------------------------------------------------- resumo e pacote

def test_sem_detalhe_e_cancelada_ficam_fora_do_total():
    ns = [nota(1), nota(2, situacao="cancelada"), nota(3)]
    its = [item(10, 1), item(20, 2), item(30, 3)]
    imps = [imposto(10, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=4, icms_v=40),
            imposto(20, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=4, icms_v=40)]
    ls = linhas(ns, its, imps)
    assert {l["id"]: l["alertas"] for l in ls}[30] == ["sem_detalhe"]
    r = im.resumo(ls)
    assert (r["itens"], r["canceladas"], r["sem_detalhe"], r["tributos"]) == (2, 1, 1, 40)
    assert r["por_fluxo"]["saida"]["icms_v"] == 40


def test_pacote_nao_manda_campo_vazio():
    p = im.pacote([nota(1)], [item(10, 1)], [imposto(10, icms_cst="00", icms_orig="1", icms_vbc=1000, icms_p=4, icms_v=40)],
                  FILIAIS)
    (l,) = p["itens"]
    assert "st_v" not in l and "alertas" not in l and "transferencia" not in l
    assert l["icms_v"] == 40 and p["alertas"]["sem_difal"] and len(p["filiais"]) == 3
