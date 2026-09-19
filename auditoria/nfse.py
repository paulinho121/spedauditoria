# -*- coding: utf-8 -*-
"""
Leitor de NFS-e no padrão nacional (xmlns http://www.sped.fazenda.gov.br/nfse).

Serviço não movimenta estoque, mas é faturamento: o ERP soma as NFS-e no
faturamento da empresa, e a receita de serviço entra na base de PIS, COFINS,
IRPJ e CSLL — com presunção diferente da de revenda (32%, e não 8% e 12%).

Só o padrão nacional. Município que ainda emite no próprio leiaute (ABRASF e
variantes) precisa de um leitor à parte; e_nfse() devolve False para esses, e
o arquivo aparece como "ignorado" na importação — em vez de ser lido errado.
"""
import hashlib
import os
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation

NS = {"s": "http://www.sped.fazenda.gov.br/nfse"}


def dec(s):
    try:
        return Decimal(str(s).strip()) if s not in (None, "") else None
    except InvalidOperation:
        return None


def _sha(caminho):
    h = hashlib.sha256()
    with open(caminho, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def e_nfse(caminho):
    with open(caminho, "rb") as fh:
        cab = fh.read(1500).decode("utf-8", "ignore")
    return "<NFSe" in cab and "sped.fazenda.gov.br/nfse" in cab


@dataclass
class NFSe:
    nome_arquivo: str
    sha256: str
    chave: str = ""
    numero: str = ""
    c_stat: str = ""
    dh_proc: str = ""
    dh_emi: str = ""
    d_compet: str = ""
    prest_cnpj: str = ""
    prest_nome: str = ""
    toma_doc: str = ""
    toma_nome: str = ""
    c_trib_nac: str = ""
    x_trib_nac: str = ""
    descricao: str = ""
    municipio: str = ""
    v_serv: Decimal = None
    v_bc: Decimal = None
    p_aliq: Decimal = None
    v_iss: Decimal = None
    v_liq: Decimal = None
    ret_iss: str = ""      # 1 = não retido; 2 = retido pelo tomador; 3 = pelo intermediário


def _t(no, caminho):
    if no is None:
        return ""
    a = no.find(caminho, NS)
    return (a.text or "").strip() if a is not None else ""


def parse(caminho):
    import xml.etree.ElementTree as ET
    n = NFSe(nome_arquivo=os.path.basename(caminho), sha256=_sha(caminho))
    raiz = ET.parse(caminho).getroot()
    inf = raiz.find("s:infNFSe", NS) if raiz.tag.endswith("NFSe") else raiz.find(".//s:infNFSe", NS)
    if inf is None:
        raise ValueError(f"{n.nome_arquivo}: não contém infNFSe — não é uma NFS-e nacional.")
    n.chave = (inf.get("Id") or "").replace("NFS", "", 1)
    n.numero = _t(inf, "s:nNFSe")
    n.c_stat = _t(inf, "s:cStat")
    n.dh_proc = _t(inf, "s:dhProc")
    n.x_trib_nac = _t(inf, "s:xTribNac")
    n.municipio = _t(inf, "s:xLocPrestacao") or _t(inf, "s:xLocEmi")
    n.prest_cnpj = _t(inf, "s:emit/s:CNPJ")
    n.prest_nome = _t(inf, "s:emit/s:xNome")
    n.v_bc = dec(_t(inf, "s:valores/s:vBC"))
    n.p_aliq = dec(_t(inf, "s:valores/s:pAliqAplic"))
    n.v_iss = dec(_t(inf, "s:valores/s:vISSQN"))
    n.v_liq = dec(_t(inf, "s:valores/s:vLiq"))
    dps = inf.find("s:DPS/s:infDPS", NS)
    n.dh_emi = _t(dps, "s:dhEmi")
    n.d_compet = _t(dps, "s:dCompet")
    n.toma_doc = _t(dps, "s:toma/s:CNPJ") or _t(dps, "s:toma/s:CPF")
    n.toma_nome = _t(dps, "s:toma/s:xNome")
    n.c_trib_nac = _t(dps, "s:serv/s:cServ/s:cTribNac")
    n.descricao = _t(dps, "s:serv/s:cServ/s:xDescServ")
    n.v_serv = dec(_t(dps, "s:valores/s:vServPrest/s:vServ"))
    n.ret_iss = _t(dps, "s:valores/s:trib/s:tribMun/s:tpRetISSQN")
    if not n.prest_cnpj:
        n.prest_cnpj = _t(dps, "s:prest/s:CNPJ")
    return n
