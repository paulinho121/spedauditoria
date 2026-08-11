# -*- coding: utf-8 -*-
"""
Parser de NF-e (modelo 55) e NFC-e (65).

Lê XML de verdade com namespace — não regex. Os arquivos reais têm variações
(nfeProc envolvendo NFe, ou NFe solta) e blocos opcionais que regex erra em
silêncio: numa primeira leitura por regex o bloco <dest> não foi encontrado em
5 de 8 notas.

Funções puras. O sentido do movimento (entrada/saída) NÃO é decidido aqui:
depende de quais CNPJs são nossos, e isso é responsabilidade da carga.
"""
import hashlib
import os
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal, InvalidOperation

NS = {"n": "http://www.portalfiscal.inf.br/nfe"}

# cStat do protocolo: o que cada faixa significa para o estoque.
CSTAT_AUTORIZADA = {"100", "150"}
CSTAT_CANCELADA = {"101", "151", "155"}
CSTAT_DENEGADA = {"110", "301", "302", "303"}
TP_EVENTO_CANCELAMENTO = {"110111"}


def dec(s):
    if s is None or str(s).strip() == "":
        return None
    try:
        return Decimal(str(s).strip())
    except InvalidOperation:
        return None


def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    return re.sub(r"[^A-Z0-9]", "", s.upper())[:60]


def sha256(caminho):
    h = hashlib.sha256()
    with open(caminho, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


@dataclass
class ItemNFe:
    n_item: int
    c_prod: str
    c_ean: str = ""
    x_prod: str = ""
    x_prod_norm: str = ""
    ncm: str = ""
    cest: str = ""
    cfop: str = ""
    u_com: str = ""
    q_com: Decimal = None
    v_un_com: Decimal = None
    v_prod: Decimal = None
    u_trib: str = ""
    q_trib: Decimal = None
    v_desc: Decimal = None
    v_frete: Decimal = None
    v_seg: Decimal = None
    v_outro: Decimal = None
    ind_tot: str = ""
    cst_icms: str = ""


@dataclass
class NFe:
    caminho: str
    nome_arquivo: str
    sha256: str
    chave: str = ""
    modelo: str = ""
    serie: str = ""
    num_nf: str = ""
    dh_emi: datetime = None
    dt_emi: object = None
    tp_nf: str = ""            # 0 = entrada, 1 = saída (do ponto de vista do emitente)
    fin_nfe: str = ""
    nat_op: str = ""
    emit_cnpj: str = ""
    emit_nome: str = ""
    emit_uf: str = ""
    dest_doc: str = ""
    dest_nome: str = ""
    dest_uf: str = ""
    vl_nf: Decimal = None
    vl_prod: Decimal = None
    situacao: str = "autorizada"
    c_stat: str = ""
    itens: list = field(default_factory=list)

    def sentido_para(self, cnpj):
        """entrada, saida ou None. Transferência entre filiais devolve os dois."""
        s = []
        if self.emit_cnpj == cnpj:
            s.append("saida")
        if self.dest_doc == cnpj:
            s.append("entrada")
        return s


def _txt(no, caminho):
    if no is None:
        return ""
    achado = no.find(caminho, NS)
    return (achado.text or "").strip() if achado is not None else ""


def parse(caminho):
    import xml.etree.ElementTree as ET

    nfe = NFe(caminho=caminho, nome_arquivo=os.path.basename(caminho),
              sha256=sha256(caminho))
    raiz = ET.parse(caminho).getroot()

    inf = raiz.find(".//n:infNFe", NS)
    if inf is None:
        raise ValueError(f"{nfe.nome_arquivo}: não contém infNFe — não é uma NF-e.")

    ident = (inf.get("Id") or "")
    nfe.chave = re.sub(r"\D", "", ident)[-44:] if ident else ""

    ide = inf.find("n:ide", NS)
    nfe.modelo = _txt(ide, "n:mod")
    nfe.serie = _txt(ide, "n:serie")
    nfe.num_nf = _txt(ide, "n:nNF")
    nfe.tp_nf = _txt(ide, "n:tpNF")
    nfe.fin_nfe = _txt(ide, "n:finNFe")
    nfe.nat_op = _txt(ide, "n:natOp")

    bruto = _txt(ide, "n:dhEmi") or _txt(ide, "n:dEmi")
    if bruto:
        try:
            nfe.dh_emi = datetime.fromisoformat(bruto)
            nfe.dt_emi = nfe.dh_emi.date()
        except ValueError:
            try:
                nfe.dt_emi = datetime.strptime(bruto[:10], "%Y-%m-%d").date()
            except ValueError:
                pass

    emit = inf.find("n:emit", NS)
    nfe.emit_cnpj = _txt(emit, "n:CNPJ") or _txt(emit, "n:CPF")
    nfe.emit_nome = _txt(emit, "n:xNome")
    nfe.emit_uf = _txt(emit, "n:enderEmit/n:UF")

    dest = inf.find("n:dest", NS)
    nfe.dest_doc = _txt(dest, "n:CNPJ") or _txt(dest, "n:CPF") or _txt(dest, "n:idEstrangeiro")
    nfe.dest_nome = _txt(dest, "n:xNome")
    nfe.dest_uf = _txt(dest, "n:enderDest/n:UF")

    total = inf.find("n:total/n:ICMSTot", NS)
    nfe.vl_nf = dec(_txt(total, "n:vNF"))
    nfe.vl_prod = dec(_txt(total, "n:vProd"))

    for det in inf.findall("n:det", NS):
        prod = det.find("n:prod", NS)
        if prod is None:
            continue
        icms = det.find("n:imposto/n:ICMS", NS)
        cst = ""
        if icms is not None:
            for filho in icms:
                cst = _txt(filho, "n:CST") or _txt(filho, "n:CSOSN")
                if cst:
                    break
        x_prod = _txt(prod, "n:xProd")
        nfe.itens.append(ItemNFe(
            n_item=int(det.get("nItem") or 0),
            c_prod=_txt(prod, "n:cProd"),
            c_ean=_txt(prod, "n:cEAN"),
            x_prod=x_prod,
            x_prod_norm=norm(x_prod),
            ncm=_txt(prod, "n:NCM"),
            cest=_txt(prod, "n:CEST"),
            cfop=_txt(prod, "n:CFOP"),
            u_com=_txt(prod, "n:uCom"),
            q_com=dec(_txt(prod, "n:qCom")),
            v_un_com=dec(_txt(prod, "n:vUnCom")),
            v_prod=dec(_txt(prod, "n:vProd")),
            u_trib=_txt(prod, "n:uTrib"),
            q_trib=dec(_txt(prod, "n:qTrib")),
            v_desc=dec(_txt(prod, "n:vDesc")),
            v_frete=dec(_txt(prod, "n:vFrete")),
            v_seg=dec(_txt(prod, "n:vSeg")),
            v_outro=dec(_txt(prod, "n:vOutro")),
            ind_tot=_txt(prod, "n:indTot"),
            cst_icms=cst,
        ))

    # Situação: o protocolo manda. Sem protocolo, assume autorizada e avisa.
    prot = raiz.find(".//n:protNFe/n:infProt", NS)
    if prot is not None:
        nfe.c_stat = _txt(prot, "n:cStat")
        if nfe.c_stat in CSTAT_CANCELADA:
            nfe.situacao = "cancelada"
        elif nfe.c_stat in CSTAT_DENEGADA:
            nfe.situacao = "denegada"
        elif nfe.c_stat in CSTAT_AUTORIZADA:
            nfe.situacao = "autorizada"
        else:
            nfe.situacao = "indefinida"

    # Evento de cancelamento embutido no mesmo arquivo.
    for ev in raiz.findall(".//n:infEvento", NS):
        if _txt(ev, "n:tpEvento") in TP_EVENTO_CANCELAMENTO:
            nfe.situacao = "cancelada"

    return nfe


def confere(nfe, nossos_cnpjs=()):
    """Problemas que só dependem do arquivo."""
    probs = []
    if len(nfe.chave) != 44:
        probs.append(("chave_invalida", f"chave com {len(nfe.chave)} dígitos"))
    if not nfe.dt_emi:
        probs.append(("sem_data", "não foi possível ler dhEmi/dEmi"))
    if not nfe.itens:
        probs.append(("sem_itens", "nota sem nenhum <det>"))
    if not nfe.emit_cnpj:
        probs.append(("sem_emitente", "bloco emit sem CNPJ/CPF"))
    if not nfe.dest_doc:
        probs.append(("sem_destinatario", "bloco dest sem CNPJ/CPF/idEstrangeiro"))
    if not nfe.c_stat:
        probs.append(("sem_protocolo",
                      "sem protNFe: não dá para confirmar autorização nem cancelamento"))
    if nfe.situacao != "autorizada":
        probs.append(("nao_autorizada", f"situação {nfe.situacao} (cStat {nfe.c_stat})"))

    if nossos_cnpjs and not nfe.sentido_para_algum(nossos_cnpjs):
        probs.append(("fora_do_grupo",
                      f"nem emit ({nfe.emit_cnpj}) nem dest ({nfe.dest_doc}) "
                      f"são estabelecimentos auditados"))

    soma = sum((i.v_prod or Decimal("0")) for i in nfe.itens)
    if nfe.vl_prod is not None and abs(soma - nfe.vl_prod) > Decimal("0.02"):
        probs.append(("total_divergente",
                      f"soma dos itens {soma} ≠ vProd do total {nfe.vl_prod}"))

    for i in nfe.itens:
        if not i.cfop:
            probs.append(("item_sem_cfop", f"item {i.n_item} sem CFOP"))
        if i.q_com is None or i.q_com <= 0:
            probs.append(("qtd_invalida", f"item {i.n_item} com qCom {i.q_com}"))
        if i.u_com and i.u_trib and i.u_com != i.u_trib:
            probs.append(("unidade_diferente",
                          f"item {i.n_item}: uCom {i.u_com} ≠ uTrib {i.u_trib} "
                          f"({i.q_com} x {i.q_trib}) — exige fator de conversão"))
    return probs


def _sentido_para_algum(self, cnpjs):
    return [c for c in cnpjs if self.emit_cnpj == c or self.dest_doc == c]


NFe.sentido_para_algum = _sentido_para_algum


def digest(nfe):
    """Resumo estável para o teste golden, sem guardar dado do cliente."""
    def h(vals):
        m = hashlib.sha256()
        for t in sorted("|".join("" if c is None else str(c) for c in v) for v in vals):
            m.update((t + "\n").encode("utf-8"))
        return m.hexdigest()[:16]

    itens = [(i.n_item, i.c_prod, i.ncm, i.cfop, i.u_com, i.q_com, i.v_un_com, i.v_prod)
             for i in nfe.itens]
    return {
        "sha256_arquivo": nfe.sha256,
        "chave": nfe.chave,
        "modelo": nfe.modelo, "serie": nfe.serie, "num_nf": nfe.num_nf,
        "dt_emi": str(nfe.dt_emi), "tp_nf": nfe.tp_nf, "nat_op": nfe.nat_op,
        "emit": nfe.emit_cnpj, "dest": nfe.dest_doc,
        "situacao": nfe.situacao, "c_stat": nfe.c_stat,
        "vl_nf": str(nfe.vl_nf), "vl_prod": str(nfe.vl_prod),
        "qtd_itens": len(nfe.itens),
        "cfops": sorted({i.cfop for i in nfe.itens}),
        "hash_itens": h(itens),
        "problemas": sorted({t for t, _ in confere(nfe)}),
    }
