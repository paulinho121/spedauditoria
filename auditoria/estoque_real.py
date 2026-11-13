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
import unicodedata
from collections import OrderedDict, defaultdict

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
