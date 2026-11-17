# -*- coding: utf-8 -*-
"""
Tratamento de impostos: o imposto de cada item de NF-e, pronto para filtrar.

A base já guarda, linha a linha, o que cada nota DESTACOU (nfe_item_imposto):
ICMS, ICMS-ST, FCP, DIFAL, IPI, II, PIS, COFINS e IBS/CBS. Este módulo junta
isso com a nota e com o item numa linha só, do ponto de vista da filial:

  · quem é a filial (a emitente, quando é nossa; senão a destinatária);
  · se a mercadoria entrou ou saiu da filial (fluxo);
  · quem é a outra parte, e se a operação é interna, interestadual ou exterior;
  · o total de tributos da linha e a carga sobre o valor da operação.

E confere o que dá para conferir sem inventar regra:

  · a conta: base × alíquota tem de dar o valor destacado (ICMS, IPI, PIS,
    COFINS) — a diferença é erro de digitação ou de cadastro. Na nota de
    importação a conta é feita na NOTA, e não no item: o ERP repete em cada
    linha a base da adição inteira e reparte o valor entre as linhas, então
    item a item a conta nunca fecha. Na nota, a base de cada adição é contada
    uma vez;
  · o CST contra o valor: CST tributado sem imposto, CST isento com imposto;
  · a alíquota interestadual: mercadoria importada (origem 1, 2, 3 ou 8) sai
    para outra UF a 4% (Resolução do Senado 13/2012); nacional a 7% ou 12%;
  · venda a não contribuinte de outra UF sem DIFAL (EC 87/2015);
  · a alíquota fora do padrão do próprio NCM: o mesmo NCM, na mesma operação,
    com alíquota diferente da que ele tem em quase todas as outras notas.

E evidencia o BENEFÍCIO na importação. Mercadoria importada com LPCO que dá
redução paga 10% do tributo, ou nada. O XML não traz a LPCO do item; o que ele
traz é o valor: numa adição com base e alíquota cheias, o destacado é 10% do
calculado, ou zero. A adição nessa situação é marcada como benefício — com o
tributo que deixou de ser pago — e sai da conta do "não fecha". Só o que não é
nem integral nem benefício continua como divergência.

Nada aqui é recalculado no lugar do destacado: o que a nota trouxe é o que
aparece. A conferência só aponta.

Função pura: recebe as linhas como vieram do banco (texto ou número) e devolve
as linhas prontas. As duas versões do servidor usam a mesma.
"""
from collections import Counter, defaultdict

# Alíquota interestadual de mercadoria nacional: 7% de S/SE (menos ES) para
# N/NE/CO/ES; 12% nos demais casos.
SUL_SUDESTE = {"PR", "SC", "RS", "SP", "RJ", "MG"}
ORIGEM_IMPORTADA = {"1", "2", "3", "8"}          # 4% na saída interestadual

CST_TRIBUTADO = {"00", "10", "20"}               # tem de destacar ICMS próprio
CST_SEM_DESTAQUE = {"40", "41", "50", "60"}      # não pode destacar

TRIBUTOS = ("icms_v", "st_v", "fcpst_v", "difal_v", "difal_fcp_v",
            "ipi_v", "ii_v", "pis_v", "cofins_v", "ibs_v", "cbs_v")

ALERTAS = {
    "sem_detalhe": "Nota importada sem o detalhe de imposto por item",
    "icms_nao_fecha": "ICMS: base × alíquota não dá o valor destacado",
    "ipi_nao_fecha": "IPI: base × alíquota não dá o valor destacado",
    "pis_nao_fecha": "PIS: base × alíquota não dá o valor destacado",
    "cofins_nao_fecha": "COFINS: base × alíquota não dá o valor destacado",
    "cst_tributado_sem_icms": "CST tributado (00, 10, 20) sem ICMS destacado",
    "cst_isento_com_icms": "CST sem destaque (40, 41, 50, 60) com ICMS destacado",
    "importacao_ipi_nao_fecha": "Importação: IPI da nota não fecha com base × alíquota",
    "importacao_pis_cofins_nao_fecha": "Importação: PIS/COFINS da nota não fecha com base × alíquota",
    "importacao_beneficio_parcial": "Importação: benefício em parte do tributo — confirmar a LPCO",
    "interestadual_importado": "Importado para outra UF com alíquota diferente de 4%",
    "interestadual_nacional": "Nacional para outra UF fora de 7% / 12%",
    "sem_difal": "Venda a não contribuinte de outra UF sem DIFAL",
    "aliquota_icms_fora_do_ncm": "Alíquota de ICMS fora do padrão do NCM",
    "aliquota_ipi_fora_do_ncm": "Alíquota de IPI fora do padrão do NCM",
}


def _f(v):
    """Número do banco (texto, Decimal ou float). Vazio fica None."""
    if v is None or v == "":
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _z(v):
    return _f(v) or 0.0


def _aliq(p):
    """Alíquota comparável: 4.0000 e 4 são a mesma coisa."""
    p = _f(p)
    return None if p is None else round(p, 2)


def _mesma_aliq(a, b):
    """9,74% e 9,75% são a mesma alíquota digitada com arredondamento diferente."""
    return a is not None and b is not None and abs(a - b) <= 0.05


def importacao(linha):
    return str(linha.get("cfop") or "")[:1] == "3"


def _nao_fecha(base, aliq, valor):
    """
    Base × alíquota contra o valor destacado. Tolerância de arredondamento:
    5 centavos ou 0,5% do valor — o que for maior. Abaixo disso é centavo de
    arredondamento do emissor, não erro.
    """
    b, p, v = _f(base), _f(aliq), _f(valor)
    if b is None or p is None or v is None or (b == 0 and v == 0):
        return False
    calc = b * p / 100.0
    return abs(calc - v) > max(0.05, abs(v) * 0.005)


def aliquota_interestadual(uf_orig, uf_dest, origem):
    """A alíquota que a saída interestadual deveria ter. None quando não se sabe."""
    if not uf_orig or not uf_dest or uf_orig == uf_dest or "EX" in (uf_orig, uf_dest):
        return None
    if str(origem or "") in ORIGEM_IMPORTADA:
        return 4.0
    if uf_orig in SUL_SUDESTE and uf_dest not in SUL_SUDESTE:
        return 7.0
    return 12.0


def monta(notas, itens, impostos, filiais, com_contas=False):
    """
    notas, itens, impostos: linhas de nfe, nfe_item e nfe_item_imposto.
    filiais: linhas de estabelecimento (cnpj, nome, uf).
    Devolve as linhas de item prontas para a tela, na ordem data/nota/item.
    """
    nossas = {f["cnpj"]: f for f in filiais}
    por_nota = {n["id"]: n for n in notas}
    por_item = {i["nfe_item_id"]: i for i in impostos}

    linhas = []
    for it in itens:
        n = por_nota.get(it["nfe_id"])
        if not n:
            continue
        t = por_item.get(it["id"]) or {}
        emit_nosso = n.get("emit_cnpj") in nossas
        dest_nosso = n.get("dest_doc") in nossas
        filial = n["emit_cnpj"] if emit_nosso else (n.get("dest_doc") if dest_nosso else None)
        # Do ponto de vista da filial: a nota que ela emite com tpNF=1 é saída;
        # a que ela recebe de terceiro (tpNF=1 para o emitente) é entrada.
        tp = str(n.get("tp_nf") or "")
        if emit_nosso:
            fluxo = "saida" if tp == "1" else "entrada"
            part_nome, part_doc, part_uf = n.get("dest_nome"), n.get("dest_doc"), n.get("dest_uf")
        else:
            fluxo = "entrada" if tp == "1" else "saida"
            part_nome, part_doc, part_uf = n.get("emit_nome"), n.get("emit_cnpj"), n.get("emit_uf")
        cfop = str(it.get("cfop") or "")
        uf_o, uf_d = n.get("emit_uf"), n.get("dest_uf")
        if cfop[:1] in ("3", "7") or "EX" in (uf_o, uf_d):
            operacao = "exterior"
        elif uf_o and uf_d and uf_o != uf_d:
            operacao = "interestadual"
        else:
            operacao = "interna"

        v_prod, v_desc = _z(it.get("v_prod")), _z(it.get("v_desc"))
        v_oper = v_prod - v_desc + _z(it.get("v_frete")) + _z(it.get("v_seg")) + _z(it.get("v_outro"))
        l = {
            "id": it["id"], "nfe_id": n["id"], "chave": n.get("chave"),
            "num": n.get("num_nf"), "serie": n.get("serie"),
            "dt": str(n.get("dt_emi") or "")[:10], "mes": str(n.get("dt_emi") or "")[:7],
            "situacao": n.get("situacao"), "fin": str(n.get("fin_nfe") or ""),
            "nat_op": n.get("nat_op"),
            "filial": filial, "filial_uf": (nossas.get(filial) or {}).get("uf"),
            "propria": emit_nosso, "fluxo": fluxo,
            "transferencia": emit_nosso and dest_nosso,
            "part_nome": part_nome, "part_doc": part_doc or None, "part_uf": part_uf,
            "uf_orig": uf_o, "uf_dest": uf_d, "operacao": operacao,
            "n_item": it.get("n_item"), "cod": it.get("c_prod"), "descr": it.get("x_prod"),
            "ncm": it.get("ncm"), "cest": it.get("cest"), "cfop": cfop,
            "unid": it.get("u_com"), "qtd": _f(it.get("q_com")), "v_unit": _f(it.get("v_un_com")),
            "v_prod": v_prod, "v_desc": v_desc or None, "v_oper": round(v_oper, 2),
            "tem_detalhe": bool(t),
            "orig": t.get("icms_orig"),
            "cst": t.get("icms_cst") or it.get("cst_icms"),
            "icms_grupo": t.get("icms_grupo"),
        }
        for campo in ("icms_vbc", "icms_p", "icms_v", "icms_deson", "st_vbc", "st_p", "st_v",
                      "fcpst_v", "st_ret_v", "difal_vbc", "difal_p_dest", "difal_p_inter",
                      "difal_v", "difal_fcp_v", "difal_remet_v", "ipi_vbc", "ipi_p", "ipi_v",
                      "ii_v", "pis_vbc", "pis_p", "pis_v", "cofins_vbc", "cofins_p", "cofins_v",
                      "ibs_v", "cbs_v"):
            l[campo] = _f(t.get(campo))
        for campo in ("ipi_cst", "pis_cst", "cofins_cst", "ibscbs_cst"):
            l[campo] = t.get(campo)
        l["tributos"] = round(sum(_z(l[c]) for c in TRIBUTOS), 2)
        l["carga"] = round(100.0 * l["tributos"] / v_oper, 2) if v_oper > 0 else None
        l["alertas"] = _alertas(l)
        linhas.append(l)

    contas = _importacao_por_nota(linhas)
    _fora_do_padrao(linhas, "icms_p", "aliquota_icms_fora_do_ncm",
                    lambda l: (l["ncm"], l["fluxo"], l["operacao"],
                               str(l["orig"] or "") in ORIGEM_IMPORTADA, l["cfop"][:1]),
                    lambda l: (l["icms_v"] or 0) > 0)
    _fora_do_padrao(linhas, "ipi_p", "aliquota_ipi_fora_do_ncm",
                    lambda l: (l["ncm"], l["operacao"], l["cfop"][:1]),
                    lambda l: (l["ipi_v"] or 0) > 0)

    linhas.sort(key=lambda l: (l["dt"], str(l["num"] or ""), l["n_item"] or 0))
    if com_contas:
        return linhas, contas
    return linhas


def _alertas(l):
    a = []
    if not l["tem_detalhe"]:
        return ["sem_detalhe"]
    # Na importação a conta é por nota (ver _importacao_por_nota); só o ICMS,
    # que não sofre do rateio, é conferido por item.
    for pref in (("icms",) if importacao(l) else ("icms", "ipi", "pis", "cofins")):
        if _nao_fecha(l[pref + "_vbc"], l[pref + "_p"], l[pref + "_v"]):
            a.append(pref + "_nao_fecha")
    # CSOSN (Simples Nacional) tem três dígitos e outra tabela: não se confunde
    # o 400 com o CST 00.
    simples = str(l["icms_grupo"] or "").upper().startswith("ICMSSN") or len(str(l["cst"] or "")) == 3
    cst = "" if simples else str(l["cst"] or "")[-2:]
    if cst in CST_TRIBUTADO and not (l["icms_v"] or 0) > 0:
        a.append("cst_tributado_sem_icms")
    if cst in CST_SEM_DESTAQUE and (l["icms_v"] or 0) > 0:
        a.append("cst_isento_com_icms")
    # Alíquota interestadual: só na saída emitida pela filial, com ICMS destacado.
    if (l["propria"] and l["fluxo"] == "saida" and l["operacao"] == "interestadual"
            and (l["icms_v"] or 0) > 0 and l["cfop"][:1] == "6"):
        esperada = aliquota_interestadual(l["uf_orig"], l["uf_dest"], l["orig"])
        p = _aliq(l["icms_p"])
        if esperada is not None and p is not None and p != esperada:
            a.append("interestadual_importado" if esperada == 4.0 else "interestadual_nacional")
    if (l["cfop"] in ("6107", "6108") and l["dt"] >= "2016-01-01"
            and (l["icms_v"] or 0) > 0 and not (l["difal_v"] or l["difal_vbc"])):
        a.append("sem_difal")
    return a


# Situação de cada adição da importação, pela razão destacado ÷ calculado.
CLASSES = {
    "integral": "integral",
    "beneficio_10": "benefício — pagou 10%",
    "beneficio_zero": "benefício — zero",
    "nao_fecha": "não fecha",
}
TRIBUTOS_IMPORTACAO = ("ipi", "pis", "cofins")
# Alíquota normal de PIS/COFINS-Importação (Lei 10.865/2004, art. 8º). O
# benefício também aparece na própria nota como alíquota de 10% dela (0,21% e
# 0,965%) ou zero; o dispensado se mede contra a normal. O IPI não tem uma
# alíquota só — a TIPI é por NCM —, então nele o benefício só se vê pelo valor.
ALIQ_NORMAL = {"pis": 2.10, "cofins": 9.65}


def classe_adicao(calc, dest):
    """
    integral: o destacado é o calculado (tolerância R$ 1,00 ou 0,5%);
    beneficio_10: o destacado é 10% do calculado (entre 8,5% e 11,5%);
    beneficio_zero: base e alíquota cheias, nada destacado;
    nao_fecha: qualquer outra coisa.
    """
    if calc <= 0.005:
        return "integral" if abs(dest) <= 1.0 else "nao_fecha"
    if abs(calc - dest) <= max(1.0, abs(dest) * 0.005):
        return "integral"
    if abs(dest) < 0.005:
        return "beneficio_zero"
    if 0.085 <= dest / calc <= 0.115:
        return "beneficio_10"
    return "nao_fecha"


def _vezes_da_base(base, xs):
    """
    Quantas vezes a base do grupo entra no calculado. Duas formas de o ERP
    escrever a mesma coisa:

      · a base é a da ADIÇÃO inteira, repetida em cada linha, e o valor é
        repartido — conta UMA vez;
      · as linhas são itens iguais, cada um com a sua base — conta UMA VEZ
        POR LINHA.

    Em cada linha a base fica perto do valor da própria linha (mediana 1,00
    nas notas reais). Então vale a leitura cuja razão base ÷ valor fica mais
    perto de 1: base ÷ soma das linhas (adição) ou base ÷ cada linha (itens).
    """
    import math
    if len(xs) < 2:
        return 1
    soma = sum(x["v_oper"] for x in xs)
    cada = [x["v_oper"] for x in xs if x["v_oper"] > 0]
    if soma <= 0 or not cada or base <= 0:
        return 1
    r_adicao = abs(math.log(base / soma))
    r_itens = sum(abs(math.log(base / v)) for v in cada) / len(cada)
    return len(xs) if r_itens < r_adicao else 1


def conta_importacao(ls):
    """
    A conta de uma nota de importação, adição por adição, para IPI, PIS e
    COFINS. Devolve, por tributo: calculado, destacado, o que o benefício
    dispensou, a diferença que nada explica e a lista das adições.
    """
    r = {}
    for t in TRIBUTOS_IMPORTACAO:
        grupos = defaultdict(list)
        soltas = []
        for l in ls:
            b, p = l[t + "_vbc"], l[t + "_p"]
            if b is None or p is None:
                if l[t + "_v"]:
                    soltas.append(l)
                continue
            grupos[(b, p)].append(l)
        adicoes = []
        for (b, p), xs in grupos.items():
            k = _vezes_da_base(b, xs)
            calc = b * p / 100.0 * k
            dest = sum(x[t + "_v"] or 0 for x in xs)
            cl = classe_adicao(calc, dest)
            # O tributo cheio: pela alíquota da nota, ou pela normal quando a
            # própria nota já traz a alíquota reduzida (benefício na alíquota).
            cheio, via = calc, "valor"
            normal = ALIQ_NORMAL.get(t)
            if normal and b > 0:
                if p == 0 and abs(dest) < 0.005:
                    cl, via = "beneficio_zero", "aliquota"
                    cheio = b * normal / 100.0 * k
                elif 0 < p <= normal * 0.115 and cl == "integral":
                    cl, via = "beneficio_10", "aliquota"
                    cheio = b * normal / 100.0 * k
            adicoes.append({
                "base": b, "aliq": p, "vezes": k, "calc": round(calc, 2), "dest": round(dest, 2),
                "cheio": round(cheio, 2), "via": via,
                "dif": round(dest - calc, 2), "razao": round(dest / calc, 4) if calc > 0.005 else None,
                "classe": cl, "itens": [x["n_item"] for x in xs],
                "dispensado": round(cheio - dest, 2) if cl.startswith("beneficio") else 0.0,
            })
        adicoes.sort(key=lambda a: (a["classe"] == "integral", -abs(a["dif"])))
        v_soltas = round(sum(x[t + "_v"] or 0 for x in soltas), 2)
        calc = round(sum(a["calc"] for a in adicoes), 2)
        dest = round(sum(a["dest"] for a in adicoes) + v_soltas, 2)
        dispensado = round(sum(a["dispensado"] for a in adicoes), 2)
        # O que sobra depois de descontar o benefício é a divergência de verdade.
        # Benefício pela alíquota já está no calculado (a nota fecha com a
        # alíquota reduzida que declarou); só o benefício pelo valor se desconta.
        pelo_valor = sum(a["dispensado"] for a in adicoes if a["via"] == "valor")
        nao_explicado = round(dest - (calc - pelo_valor), 2)
        r[t] = {"calc": calc, "dest": dest, "dif": round(dest - calc, 2),
                "dispensado": dispensado, "nao_explicado": nao_explicado,
                "fecha": abs(nao_explicado) <= max(1.0, abs(dest) * 0.005),
                "adicoes": adicoes, "soltas": v_soltas,
                "soltas_itens": [x["n_item"] for x in soltas]}
    return r


def _importacao_por_nota(linhas):
    """
    Na nota de importação a conta é por nota (ver conta_importacao). O
    resultado vai em todas as linhas da nota, para o filtro achá-las; e cada
    linha leva a situação da SUA adição em cada tributo — é isso que deixa o
    item com benefício à vista.
    """
    notas = defaultdict(list)
    for l in linhas:
        if importacao(l) and l["tem_detalhe"] and l["situacao"] != "cancelada":
            notas[l["nfe_id"]].append(l)
    contas = {}
    for nfe_id, ls in notas.items():
        c = conta_importacao(ls)
        contas[nfe_id] = c
        por_item = {t: {i: a for a in c[t]["adicoes"] for i in a["itens"]} for t in c}
        for l in ls:
            for t in TRIBUTOS_IMPORTACAO:
                l[f"nota_{t}_calc"], l[f"nota_{t}_dest"] = c[t]["calc"], c[t]["dest"]
                l[f"nota_{t}_dispensado"] = c[t]["dispensado"]
                a = por_item[t].get(l["n_item"])
                if a and a["classe"] != "integral":
                    l[f"{t}_classe"] = a["classe"]
                if a and a["classe"].startswith("beneficio"):
                    # O dispensado da adição, repartido pelo valor das linhas dela.
                    xs = [x for x in ls if x["n_item"] in a["itens"]]
                    tot = sum(x["v_oper"] for x in xs) or len(xs)
                    parte = (l["v_oper"] if tot != len(xs) else 1) / tot
                    l[f"{t}_dispensado"] = round(a["dispensado"] * parte, 2)
            l["beneficio"] = beneficio_txt(l)
            l["dispensado"] = round(sum(l.get(f"{t}_dispensado") or 0 for t in TRIBUTOS_IMPORTACAO), 2)
            if not c["ipi"]["fecha"]:
                l["alertas"].append("importacao_ipi_nao_fecha")
            if not (c["pis"]["fecha"] and c["cofins"]["fecha"]):
                l["alertas"].append("importacao_pis_cofins_nao_fecha")
    return contas


def beneficio_txt(l):
    """'PIS/COFINS 10%', 'PIS/COFINS zero', 'IPI zero + PIS/COFINS 10%'… ou None."""
    def rot(classe):
        return {"beneficio_10": "10%", "beneficio_zero": "zero"}.get(classe)
    ipi = rot(l.get("ipi_classe"))
    pis, cof = rot(l.get("pis_classe")), rot(l.get("cofins_classe"))
    partes = []
    if ipi:
        partes.append(f"IPI {ipi}")
    if pis and pis == cof:
        partes.append(f"PIS/COFINS {pis}")
    else:
        if pis:
            partes.append(f"PIS {pis}")
        if cof:
            partes.append(f"COFINS {cof}")
    return " + ".join(partes) or None


def _fora_do_padrao(linhas, campo, codigo, grupo, conta):
    """
    Alíquota que destoa do próprio NCM. Só acusa quando o padrão é claro: o
    grupo tem pelo menos 5 linhas e uma alíquota responde por 80% delas. Grupo
    dividido ao meio não tem padrão — é decisão de cadastro, não erro.
    """
    grupos = defaultdict(list)
    for l in linhas:
        if l["tem_detalhe"] and l["situacao"] != "cancelada" and l["ncm"] and conta(l):
            p = _aliq(l[campo])
            if p is not None:
                grupos[grupo(l)].append((l, p))
    for ls in grupos.values():
        if len(ls) < 5:
            continue
        moda, _ = Counter(p for _, p in ls).most_common(1)[0]
        # Alíquota a um arredondamento da moda conta como a moda.
        vezes = sum(1 for _, p in ls if _mesma_aliq(p, moda))
        if vezes / len(ls) < 0.8:
            continue
        for l, p in ls:
            if not _mesma_aliq(p, moda):
                l["alertas"].append(codigo)
                l[campo + "_padrao"] = moda


def resumo(linhas):
    """Totais do topo da tela, sobre as linhas que não foram canceladas."""
    vivas = [l for l in linhas if l["situacao"] != "cancelada"]
    soma = lambda campo, ls=vivas: round(sum(_z(l[campo]) for l in ls), 2)
    por_fluxo = {}
    for f in ("entrada", "saida"):
        ls = [l for l in vivas if l["fluxo"] == f]
        por_fluxo[f] = {"itens": len(ls), "notas": len({l["nfe_id"] for l in ls}),
                        "v_oper": soma("v_oper", ls), "tributos": soma("tributos", ls),
                        **{c: soma(c, ls) for c in TRIBUTOS}}
    alertas = Counter(a for l in vivas for a in l["alertas"])
    return {
        "itens": len(vivas), "notas": len({l["nfe_id"] for l in vivas}),
        "canceladas": len({l["nfe_id"] for l in linhas if l["situacao"] == "cancelada"}),
        "sem_detalhe": sum(1 for l in vivas if not l["tem_detalhe"]),
        "notas_sem_detalhe": len({l["nfe_id"] for l in vivas if not l["tem_detalhe"]}),
        "primeira": min((l["dt"] for l in vivas if l["dt"]), default=None),
        "ultima": max((l["dt"] for l in vivas if l["dt"]), default=None),
        "v_oper": soma("v_oper"), "tributos": soma("tributos"),
        **{c: soma(c) for c in TRIBUTOS},
        "por_fluxo": por_fluxo,
        "alertas": dict(alertas),
        "beneficio_itens": sum(1 for l in vivas if l.get("beneficio")),
        "beneficio_notas": len({l["nfe_id"] for l in vivas if l.get("beneficio")}),
        "beneficio_dispensado": round(sum(l.get("dispensado") or 0 for l in vivas), 2),
        "itens_com_alerta": sum(1 for l in vivas if l["alertas"] and l["alertas"] != ["sem_detalhe"]),
    }


# ------------------------------------------------------------ para a tela

# As colunas que a tela precisa de cada tabela. Os dois servidores buscam as
# mesmas — um por SQL, o outro pelo PostgREST.
COLUNAS = {
    "nfe": "id,chave,modelo,serie,num_nf,dt_emi,tp_nf,fin_nfe,nat_op,emit_cnpj,"
           "emit_nome,emit_uf,dest_doc,dest_nome,dest_uf,vl_nf,vl_prod,situacao",
    "nfe_item": "id,nfe_id,n_item,c_prod,x_prod,ncm,cest,cfop,u_com,q_com,v_un_com,"
                "v_prod,v_desc,v_frete,v_seg,v_outro,cst_icms",
    "nfe_item_imposto": "*",
    "estabelecimento": "cnpj,nome,uf",
}


def pacote(notas, itens, impostos, filiais):
    """
    O que a tela recebe: as linhas, o resumo e o nome de cada alerta. Campo
    vazio, zero-de-falso e lista vazia não viajam — a tela os lê como vazios.
    Sem isso a resposta passa de 5 MB com três mil itens.
    """
    linhas, contas = monta(notas, itens, impostos, filiais, com_contas=True)
    enxutas = [{k: v for k, v in l.items() if v not in (None, "", [], False)} for l in linhas]
    return {"itens": enxutas, "resumo": resumo(linhas), "alertas": ALERTAS,
            "classes": CLASSES,
            # A conta da importação, adição por adição. A tela mostra; não refaz.
            "importacoes": {str(k): v for k, v in contas.items()},
            "filiais": [{"cnpj": f["cnpj"], "uf": f.get("uf"), "nome": f.get("nome")}
                        for f in filiais]}
