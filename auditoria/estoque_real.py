# -*- coding: utf-8 -*-
"""
Estoque real a partir do Kardex do ERP.

O extrato de movimentos diz, nota a nota, o que entrou e o que saiu do
depósito. Três coisas nele denunciam estoque errado, e cada uma aponta um tipo
de nota que falta:

  1. SAÍDA SEM ESTOQUE — a nota saiu e o saldo do depósito ficou negativo.
     Falta uma ENTRADA antes dela: o retorno do armazém que não foi emitido a
     tempo, ou a compra / o saldo inicial que nunca foi lançado.

  2. RETORNO SEM REMESSA — voltou de um terceiro (armazém, locação, comodato…)
     mais do que foi mandado para ele. Falta uma SAÍDA: a nota de remessa, ou o
     saldo que já estava lá quando o ERP começou.

  3. REMESSA SEM RETORNO — foi para um terceiro e não voltou. Não é erro por si:
     é o que está em poder de terceiros hoje. Vira erro quando a mercadoria já
     voltou ou já foi vendida e ninguém emitiu a entrada de retorno.

O ESTOQUE REAL de um produto é a posição de hoje, sem deixar negativo:

    posição      = saldo do depósito no ERP + o que está em terceiros
    em terceiros = em cada terceiro, o que foi menos o que voltou — só quando
                   sobra. Onde voltou mais do que foi, não há nada lá: o que
                   voltou a mais já está somado no saldo do depósito.
    estoque real = a posição, quando positiva; zero, quando negativa — e aí o
                   tamanho do negativo é a ENTRADA QUE FALTA.

Vale a posição de HOJE, e não o pior momento do caminho. O extrato tem
lançamento errado que o próprio cliente estornou depois (1.181,65 unidades
transferidas num dia e devolvidas no mês seguinte), e tem retorno emitido dias
depois da venda. Medir pelo pior momento transformaria esses tropeços em
estoque que nunca existiu. O caminho continua visível — nas listas de notas.

É um piso, não uma contagem. Onde o ERP começou sem saldo inicial, o extrato só
prova o que se mexeu; o que ficou parado sem nunca ter sido lançado não deixa
rastro, e só o inventário físico mostra.

Este módulo é a referência do cálculo: as funções do banco (erp_real_*) fazem a
mesma conta, e os testes conferem a regra aqui.
"""
import json
import unicodedata
from collections import Counter, OrderedDict, defaultdict

EPS = 1e-9

# Naturezas em que a mercadoria muda de lugar e continua sendo da empresa.
TERCEIROS = ("armazem", "locacao", "comodato", "demonstracao", "exposicao",
             "conserto", "garantia")

ROTULO = {
    "armazem": "Armazém / depósito fechado", "locacao": "Locação",
    "comodato": "Comodato", "demonstracao": "Demonstração",
    "exposicao": "Exposição", "conserto": "Conserto", "garantia": "Garantia",
    "compra": "Compra / importação", "venda": "Venda",
    "transferencia": "Transferência entre filiais", "brinde": "Brinde",
    "devolucao": "Devolução", "producao": "Requisição de produção",
    "ajuste": "Ajuste / correção", "outros": "Outros",
}


def _sem_acento(t):
    t = unicodedata.normalize("NFKD", (t or "").lower())
    return "".join(c for c in t if not unicodedata.combining(c)).strip()


def natureza(tipo):
    """
    O tipo de operação do ERP é texto livre ("S Rem Dep Fec Armaz Geral"). A
    natureza sai de palavras-chave, e a ordem importa: "Ent Ret Remet p Dep Fec
    Armaz" é armazém antes de ser qualquer outra coisa.
    """
    t = _sem_acento(tipo)
    if "dep fec" in t or "armaz" in t:
        return "armazem"
    for chave, nat in (("loca", "locacao"), ("comodato", "comodato"),
                       ("demonstra", "demonstracao"), ("exposi", "exposicao"),
                       ("conserto", "conserto"), ("garantia", "garantia"),
                       ("transf", "transferencia"), ("brinde", "brinde"),
                       ("dev", "devolucao"), ("produ", "producao"),
                       ("ajust", "ajuste"), ("corre", "ajuste"),
                       ("complement", "ajuste")):
        if chave in t:
            return nat
    if t.startswith("v ") or "venda" in t:
        return "venda"
    if t.startswith("c p") or "compra" in t:
        return "compra"
    return "outros"


def _terceiro(l):
    """Com quem está a mercadoria: o nome como veio, só sem caixa e sem sobra."""
    return " ".join((l.get("entidade") or "").upper().split())


def analisa(linhas):
    """
    linhas: as do leitor do extrato, na ordem do arquivo (cronológica dentro de
    cada produto). Devolve produtos, as três listas de notas e o resumo.
    """
    grupos = OrderedDict()
    for l in linhas:
        if l.get("abertura"):
            continue
        grupos.setdefault((l["cod_item"], l.get("descr_item") or ""), []).append(l)

    produtos, sem_estoque, sem_remessa, em_terceiros = [], [], [], []
    for (cod, descr), ls in grupos.items():
        # Quanto cada terceiro devolveu ao todo: é o que abate as remessas.
        devolvido = defaultdict(float)
        for l in ls:
            nat = natureza(l.get("tipo"))
            if nat in TERCEIROS:
                devolvido[(nat, _terceiro(l))] += l.get("qtd_entrada") or 0

        saldo = menor_saldo = 0.0
        entradas = saidas = 0.0
        fora = defaultdict(float)          # saldo de cada par (natureza, terceiro)
        remetido = defaultdict(float)      # remessas acumuladas de cada par
        negativos = []                     # saídas descobertas, à espera de entrada
        sem_lastro = defaultdict(list)     # retornos a mais, à espera de remessa
        for l in ls:
            ent, sai = l.get("qtd_entrada") or 0, l.get("qtd_saida") or 0
            nat = natureza(l.get("tipo"))
            entradas += ent
            saidas += sai
            saldo += ent - sai
            menor_saldo = min(menor_saldo, saldo)

            if nat in TERCEIROS:
                k = (nat, _terceiro(l))
                fora[k] += sai - ent
                remetido[k] += sai
                if fora[k] >= -EPS:
                    for n in sem_lastro[k]:        # a remessa que deu lastro
                        n.update(coberta_em=l.get("dt"), coberta_doc=l.get("doc_texto"),
                                 coberta_tipo=l.get("tipo"))
                    sem_lastro[k] = []
                elif ent > 0:
                    n = _nota(l, cod, descr, nat, {
                        "qtd": ent, "saldo_depois": fora[k],
                        "sem_lastro": min(ent, -fora[k]),
                        "coberta_em": None, "coberta_doc": None, "coberta_tipo": None})
                    sem_remessa.append(n)
                    sem_lastro[k].append(n)
                if sai > 0:
                    # Os retornos quitam as remessas mais antigas primeiro; fica
                    # pendente o que passa do total devolvido.
                    pend = min(sai, remetido[k] - devolvido[k])
                    if pend > EPS:
                        em_terceiros.append(_nota(l, cod, descr, nat, {
                            "qtd": sai, "pendente": pend}))

            if saldo >= -EPS:
                for n in negativos:                # a entrada que zerou o negativo
                    n.update(coberta_em=l.get("dt"), coberta_doc=l.get("doc_texto"),
                             coberta_tipo=l.get("tipo"),
                             coberta_natureza=natureza(l.get("tipo")))
                negativos = []
            elif sai > 0:
                n = _nota(l, cod, descr, nat, {
                    "qtd": sai, "saldo_depois": saldo, "descoberto": min(sai, -saldo),
                    "coberta_em": None, "coberta_doc": None, "coberta_tipo": None,
                    "coberta_natureza": None})
                sem_estoque.append(n)
                negativos.append(n)

        por_nat = defaultdict(float)
        for (nat, _e), v in fora.items():
            if v > EPS:
                por_nat[nat] += v
        em_terc = sum(por_nat.values())
        volta_a_mais = sum(-v for v in fora.values() if v < -EPS)
        posicao = saldo + em_terc
        produtos.append({
            "cod_item": cod, "descr_item": descr, "unid": ls[0].get("unid"),
            "movimentos": len(ls), "primeira": ls[0].get("dt"), "ultima": ls[-1].get("dt"),
            "entradas": entradas, "saidas": saidas,
            "saldo_erp": saldo, "saldo_impresso": ls[-1].get("qtd_saldo"),
            "menor_saldo": menor_saldo,
            "em_terceiros": em_terc, "por_natureza": dict(por_nat),
            "retorno_sem_remessa": volta_a_mais,
            "falta_entrada": max(0.0, -posicao),
            "estoque_real": max(0.0, posicao),
            "situacao": _situacao(saldo, menor_saldo, volta_a_mais, posicao),
        })

    return {"produtos": produtos, "sem_estoque": sem_estoque,
            "sem_remessa": sem_remessa, "em_terceiros": em_terceiros,
            "resumo": _resumo(produtos, sem_estoque, sem_remessa, em_terceiros)}


def _nota(l, cod, descr, nat, extra):
    n = {"seq": l.get("seq"), "dt": l.get("dt"), "doc_texto": l.get("doc_texto"),
         "doc_num": l.get("doc_num"), "tipo": l.get("tipo"), "natureza": nat,
         "entidade": l.get("entidade"), "cod_item": cod, "descr_item": descr}
    n.update(extra)
    return n


def _situacao(saldo, menor_saldo, volta_a_mais, posicao):
    """A pior coisa que o extrato diz do produto — uma só, a mais grave."""
    if posicao < -EPS:
        return "falta_entrada"         # nem contando terceiros o estoque fecha
    if saldo < -EPS:
        return "negativo_hoje"         # depósito negativo; há saldo em terceiros
    if volta_a_mais > EPS:
        return "retorno_sem_remessa"
    if menor_saldo < -EPS:
        return "ficou_negativo"        # já fechou, mas houve saída sem estoque
    return "ok"


def _resumo(produtos, sem_estoque, sem_remessa, em_terceiros):
    # Uma nota é documento + data + operação + entidade: o mesmo número aparece
    # em mais de uma operação, e lançamento sem documento não vira uma nota só.
    docs = lambda ns: len({(n["doc_texto"], n["dt"], n["tipo"], n["entidade"])
                           for n in ns})
    abertas = [n for n in sem_estoque if n["coberta_em"] is None]
    sem_lastro = [n for n in sem_remessa if n["coberta_em"] is None]
    return {
        "produtos": len(produtos),
        "saldo_erp": sum(p["saldo_erp"] for p in produtos),
        "negativos_hoje": sum(1 for p in produtos if p["saldo_erp"] < -EPS),
        "qtd_negativa_hoje": -sum(p["saldo_erp"] for p in produtos if p["saldo_erp"] < -EPS),
        "em_terceiros": sum(p["em_terceiros"] for p in produtos),
        "retorno_sem_remessa": sum(p["retorno_sem_remessa"] for p in produtos),
        "falta_entrada": sum(p["falta_entrada"] for p in produtos),
        "produtos_falta_entrada": sum(1 for p in produtos if p["falta_entrada"] > EPS),
        "estoque_real": sum(p["estoque_real"] for p in produtos),
        "sem_estoque_linhas": len(sem_estoque), "sem_estoque_notas": docs(sem_estoque),
        "sem_estoque_qtd": sum(n["descoberto"] for n in sem_estoque),
        "sem_estoque_abertas": len(abertas),
        "sem_estoque_abertas_notas": docs(abertas),   # nota com algum item aberto
        "sem_estoque_abertas_qtd": sum(n["descoberto"] for n in abertas),
        "sem_remessa_linhas": len(sem_remessa), "sem_remessa_notas": docs(sem_remessa),
        "sem_remessa_qtd": sum(n["sem_lastro"] for n in sem_remessa),
        "sem_remessa_abertas": len(sem_lastro),
        "sem_remessa_abertas_notas": docs(sem_lastro),
        "em_terceiros_linhas": len(em_terceiros), "em_terceiros_notas": docs(em_terceiros),
        "em_terceiros_qtd": sum(n["pendente"] for n in em_terceiros),
    }


# ------------------------------------------------------- a posição numa data
#
# A tela pede o estoque real "daquele dia" e, para cada fechamento de mês, o
# auditor pode corrigir quantidades e tirar do cálculo o que foi emitido de
# forma errada. Tudo isso fica no banco (erp_fechamento), por data, e é
# aplicado aqui na hora de montar a posição.

TERCEIROS_OUTROS = ("exposicao", "conserto", "garantia")
TERC_CAMPOS = ("em_armazem", "em_locacao", "em_comodato", "em_demonstracao", "em_outros")
CAMPOS_FECHAMENTO = ("saldo_erp",) + TERC_CAMPOS
TIPOS_FECHAMENTO = ("ajuste", "nota", "produto")


def _linha_da_base(r):
    """Uma linha de erp_real_linha no formato que analisa() lê."""
    num = lambda v: float(v) if v not in (None, "") else 0.0
    ent, sai = num(r.get("ent")), num(r.get("sai"))
    return {"seq": int(r["seq"]), "abertura": False, "cod_item": r["cod_item"],
            "descr_item": r.get("descr_item") or "", "unid": r.get("unid"),
            "dt": str(r.get("dt") or "")[:10], "doc_texto": r.get("doc_texto"),
            "doc_num": r.get("doc_num"), "tipo": r.get("tipo"), "entidade": r.get("entidade"),
            "qtd_entrada": ent or None, "qtd_saida": sai or None,
            "qtd_saldo": None if r.get("saldo_impresso") in (None, "") else float(r["saldo_impresso"]),
            "custo_entrada": None if r.get("custo_entrada") in (None, "") else float(r["custo_entrada"])}


def _custo(ls):
    """
    Custo unitário de um documento de entrada, como em erp_real_produtos: a
    última COMPRA; sem compra, o último retorno de armazém; por fim, qualquer
    entrada. O custo médio do extrato não serve (saída sem custo o infla).

    Em Decimal, como o numeric do banco: com float, o valor de 35 produtos
    saía um centavo diferente do que o banco calcula para a mesma conta.
    """
    from decimal import Decimal
    for alvo in ("compra", "armazem", None):
        for l in reversed(ls):
            e, c = l.get("qtd_entrada") or 0, l.get("custo_entrada") or 0
            if e > 0 and c > 0 and (alvo is None or natureza(l.get("tipo")) == alvo):
                return Decimal(str(c)) / Decimal(str(e)), ("entrada" if alvo is None else alvo)
    return None, None


CASAS_CUSTO = 16     # a divisão numeric do banco tem pelo menos 16 casas


def _dinheiro(qtd, custo):
    """
    qtd × custo, como o banco: o custo sai da divisão com 16 casas, e o produto
    é arredondado a centavo, metade para cima. Sem as 16 casas, 3 de 1557
    produtos saíam um centavo diferente do banco.
    """
    from decimal import Decimal, ROUND_HALF_UP
    c = custo.quantize(Decimal(1).scaleb(-CASAS_CUSTO), rounding=ROUND_HALF_UP)
    return float((Decimal(str(qtd)) * c).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def _ordem_cod(cod):
    return cod.rjust(20, "0") if cod.isdigit() else cod


def _nk(doc, dt, tipo, ent):
    """Identidade de uma nota: documento, data, operação e entidade — como a tela agrupa."""
    return (str(doc or ""), str(dt or "")[:10], str(tipo or ""), str(ent or ""))


def chave_fechamento(tipo, cod=None, descr=None, campo=None, doc=None, dt=None, ntipo=None, ent=None):
    """
    A chave de um item do fechamento. É ela que diz se dois pedidos são o mesmo
    item: a mesma chave gravada de novo substitui, e a chave sem gravação remove.
    """
    if tipo == "ajuste":
        partes = [cod or "", descr or "", campo or ""]
    elif tipo == "produto":
        partes = [cod or "", descr or ""]
    elif tipo == "nota":
        partes = list(_nk(doc, dt, ntipo, ent))
    else:
        raise ValueError("tipo de fechamento desconhecido")
    return json.dumps([tipo] + partes, ensure_ascii=False)


def fechamento_de(rows):
    """
    Das linhas guardadas do fechamento de uma data, o que a posição precisa:
    as notas excluídas, os produtos excluídos e as quantidades corrigidas.
    """
    notas, produtos, ajustes = set(), set(), {}
    for r in rows or []:
        t = r.get("tipo")
        if t == "nota":
            notas.add(_nk(r.get("doc_texto"), r.get("dt"), r.get("nota_tipo"), r.get("entidade")))
        elif t == "produto":
            produtos.add((r.get("cod_item") or "", r.get("descr_item") or ""))
        elif t == "ajuste" and r.get("qtd") not in (None, "") and r.get("campo") in CAMPOS_FECHAMENTO:
            ajustes.setdefault((r.get("cod_item") or "", r.get("descr_item") or ""), {})[r["campo"]] = float(r["qtd"])
    return {"notas": notas, "produtos": produtos, "ajustes": ajustes}


def montar_fechamento(b):
    """
    O pedido da tela, conferido. Devolve (ação, dados): ação é 'gravar',
    'remover' ou 'limpar'. Quantidade vazia num ajuste é pedido para remover.
    """
    acao = str(b.get("acao") or "gravar")
    if acao not in ("gravar", "remover", "limpar"):
        raise ValueError("ação desconhecida")
    if acao == "limpar":
        return acao, {}
    tipo = str(b.get("tipo") or "")
    if tipo not in TIPOS_FECHAMENTO:
        raise ValueError("tipo de fechamento desconhecido")
    p = {"tipo": tipo, "cod_item": str(b.get("cod") or ""), "descr_item": str(b.get("descr") or ""),
         "campo": None, "qtd": None, "qtd_original": None, "doc_texto": None, "dt": None,
         "nota_tipo": None, "entidade": "", "observacao": (str(b.get("obs") or "").strip()[:300] or None)}
    if tipo == "ajuste":
        campo = str(b.get("campo") or "")
        if campo not in CAMPOS_FECHAMENTO:
            raise ValueError("campo de ajuste desconhecido")
        p["campo"] = campo
        bruto = b.get("qtd")
        if acao == "gravar":
            if bruto in (None, ""):
                acao = "remover"
            else:
                try:
                    q = float(str(bruto).replace(",", "."))
                except ValueError:
                    raise ValueError("quantidade inválida")
                if q != q or abs(q) > 1e9:
                    raise ValueError("quantidade inválida")
                p["qtd"] = q
                orig = b.get("qtd_original")
                p["qtd_original"] = None if orig in (None, "") else float(orig)
    elif tipo == "nota":
        doc = str(b.get("doc") or "")
        if not doc:
            raise ValueError("nota sem número")
        p["doc_texto"] = doc
        p["dt"] = str(b.get("dt") or "")[:10] or None
        p["nota_tipo"] = str(b.get("ntipo") or "")
        p["entidade"] = str(b.get("entidade") or "")
    p["chave"] = chave_fechamento(tipo, cod=p["cod_item"], descr=p["descr_item"], campo=p["campo"],
                                  doc=p["doc_texto"], dt=p["dt"], ntipo=p["nota_tipo"], ent=p["entidade"])
    return acao, p


def posicao(base, data=None, foto=None, fechamento=None):
    """
    base: linhas de erp_real_linha do extrato (qualquer ordem).
    data: 'AAAA-MM-DD' — só entram os movimentos até o fim desse dia. None = tudo.
    foto: linhas do saldo de produtos do ERP (cod_item, descr_item, ncm,
          custo_unit, qtd), para NCM e o custo que o ERP declara.
    fechamento: o que o auditor fez nesta data (ver fechamento_de): notas e
          produtos excluídos, quantidades corrigidas.
    Devolve produtos, as três listas de notas e o resumo, no formato da tela.
    Quantidade corrigida traz 'ajuste_orig' com o valor que o extrato dava.
    """
    import datetime as _dt
    fc = fechamento or {}
    notas_x = fc.get("notas", set())
    prod_x = fc.get("produtos", set())
    aj = fc.get("ajustes", {})

    linhas = sorted((_linha_da_base(r) for r in base), key=lambda l: l["seq"])
    if data:
        linhas = [l for l in linhas if l["dt"] and l["dt"] <= data]
    linhas = [l for l in linhas if _nk(l["doc_texto"], l["dt"], l["tipo"], l["entidade"]) not in notas_x]
    a = analisa(linhas)
    ref = data or max((l["dt"] for l in linhas if l["dt"]), default=None)
    dia = lambda s: _dt.date.fromisoformat(s[:10]) if s else None

    por_prod = defaultdict(list)
    for l in linhas:
        por_prod[(l["cod_item"], l["descr_item"])].append(l)
    cadastros = Counter(p["cod_item"] for p in a["produtos"])
    foto_por = defaultdict(list)
    for f in foto or []:
        foto_por[f["cod_item"]].append(f)

    produtos = []
    for p in a["produtos"]:
        key = (p["cod_item"], p["descr_item"])
        if key in prod_x:
            continue                                  # produto excluído do fechamento
        ls = por_prod[key]
        nat = p["por_natureza"]
        custo, origem = _custo(ls)
        fs = foto_por.get(p["cod_item"]) or []
        # Mesmo código em dois cadastros: casa primeiro pela descrição.
        f = next((x for x in fs if (x.get("descr_item") or "") == p["descr_item"]), fs[0] if fs else {})
        cu = f.get("custo_unit")
        cu = float(cu) if cu not in (None, "") and float(cu) > 0 else None
        d = {
            "cod_item": p["cod_item"], "descr_item": p["descr_item"], "unid": p["unid"],
            "ncm": f.get("ncm"), "movimentos": p["movimentos"],
            "primeira": p["primeira"], "ultima": p["ultima"],
            "entradas": p["entradas"], "saidas": p["saidas"],
            "saldo_erp": p["saldo_erp"], "saldo_impresso": p["saldo_impresso"],
            "menor_saldo": p["menor_saldo"],
            "em_armazem": nat.get("armazem", 0.0), "em_locacao": nat.get("locacao", 0.0),
            "em_comodato": nat.get("comodato", 0.0), "em_demonstracao": nat.get("demonstracao", 0.0),
            "em_outros": sum(nat.get(k, 0.0) for k in TERCEIROS_OUTROS),
            "retorno_sem_remessa": p["retorno_sem_remessa"],
            "situacao": p["situacao"], "cadastros": cadastros[p["cod_item"]],
            "custo": round(float(custo), 4) if custo is not None else None, "custo_origem": origem,
            "custo_erp": round(cu, 4) if cu is not None else None,
            "saldo_foto": None if f.get("qtd") in (None, "") else float(f["qtd"]),
        }
        # Correção do auditor: troca o número do extrato e refaz a conta.
        corrigido = aj.get(key, {})
        orig = {}
        for campo, q in corrigido.items():
            orig[campo] = d[campo]
            d[campo] = q
        if orig:
            d["ajuste_orig"] = orig
        d["em_terceiros"] = sum(d[c] for c in TERC_CAMPOS)
        pos = d["saldo_erp"] + d["em_terceiros"]
        d["estoque_real"] = max(pos, 0.0)
        d["falta_entrada"] = max(-pos, 0.0)
        d["valor_real"] = _dinheiro(d["estoque_real"], custo) if custo is not None else None
        produtos.append(d)
    produtos.sort(key=lambda x: (_ordem_cod(x["cod_item"]), x["descr_item"]))

    keep = {(x["cod_item"], x["descr_item"]) for x in produtos}

    def lista(ns, extra):
        out = []
        for n in ns:
            if (n["cod_item"], n["descr_item"]) not in keep:
                continue
            x = dict(n)
            extra(x)
            out.append(x)
        out.sort(key=lambda x: (x["dt"] or "", x["seq"]))
        return out

    def cobertura(x):
        x["situacao"] = "aberta" if x.get("coberta_em") is None else "coberta"
        x["dias"] = (dia(x["coberta_em"]) - dia(x["dt"])).days if x.get("coberta_em") else None

    def fora(x):
        x["dias"] = (dia(ref) - dia(x["dt"])).days if ref and x["dt"] else None

    sem_estoque = lista(a["sem_estoque"], cobertura)
    sem_remessa = lista(a["sem_remessa"], cobertura)
    em_terceiros = lista(a["em_terceiros"], fora)

    r = _resumo(produtos, sem_estoque, sem_remessa, em_terceiros)
    r.update({
        "data": data, "movimentos": len(linhas),
        "primeira": min((l["dt"] for l in linhas if l["dt"]), default=None),
        "ultima": max((l["dt"] for l in linhas if l["dt"]), default=None),
        "em_armazem": sum(x["em_armazem"] for x in produtos),
        "em_locacao": sum(x["em_locacao"] for x in produtos),
        "em_comodato": sum(x["em_comodato"] for x in produtos),
        "em_demonstracao": sum(x["em_demonstracao"] for x in produtos),
        "em_outros": sum(x["em_outros"] for x in produtos),
        "valor_real": round(sum(x["valor_real"] or 0 for x in produtos), 2),
        "sem_custo": sum(1 for x in produtos if x["estoque_real"] > EPS and x["custo"] is None),
        "situacoes": dict(Counter(x["situacao"] for x in produtos)),
        "custo_por_compra": sum(1 for x in produtos if x["custo_origem"] == "compra"),
        "excluidas_notas": len(notas_x), "excluidos_produtos": len(prod_x),
        "ajustes": sum(len(v) for v in aj.values()),
    })
    return {"produtos": produtos, "sem_estoque": sem_estoque, "sem_remessa": sem_remessa,
            "em_terceiros": em_terceiros, "resumo": r}


# Colunas de erp_real_linha que posicao() lê.
COLUNAS_BASE = ("seq,cod_item,descr_item,unid,dt,doc_texto,doc_num,tipo,entidade,"
                "ent,sai,saldo_impresso,custo_entrada")
