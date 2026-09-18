# -*- coding: utf-8 -*-
"""
Leitor da ECD — Escrituração Contábil Digital (SPED Contábil).

Serve para responder uma pergunta que as notas não respondem: houve lucro ou
prejuízo? O resultado depende de despesas que não estão em documento fiscal —
folha, aluguel, frete, juros. Estão na contabilidade.

O que se lê, e por quê:

  0000   empresa e período
  I050   plano de contas: natureza (04 = resultado), analítica/sintética, pai
  I051   conta do plano referencial da Receita — dá o significado padronizado
         da conta, independente do nome que o escritório deu
  I150   abre um período de saldos (normalmente um mês)
  I155   saldo de cada conta no período: inicial, débitos, créditos, final
  I200   cabeçalho de lançamento — só importa o indicador: "E" é ENCERRAMENTO
  I250   partidas do lançamento — só as de encerramento são guardadas
  I355   saldo das contas de resultado ANTES do encerramento

O encerramento é o motivo de ler lançamento. No fechamento, as contas de
resultado são zeradas contra o patrimônio líquido. Essas partidas entram nos
débitos e créditos do I155 do mês em que ocorrem; sem descontá-las, o mês de
fechamento mostraria resultado zero. Os demais lançamentos são pulados: uma
ECD pode ter milhões de partidas, e o saldo já está no I155.

Funções puras, uma passada pelo arquivo.
"""
import hashlib
import os
import re
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal, InvalidOperation

ENCODING = "latin-1"
RE_REG = re.compile(r"^\|([0-9A-Z]{4})\|")


def dec(s):
    s = (s or "").strip()
    if not s:
        return Decimal("0")
    try:
        return Decimal(s.replace(".", "").replace(",", "."))
    except InvalidOperation:
        return Decimal("0")


def data(s):
    s = (s or "").strip()
    return date(int(s[4:8]), int(s[2:4]), int(s[0:2])) if len(s) == 8 else None


def campo(p, i):
    return p[i] if len(p) > i else ""


def sha256(caminho):
    h = hashlib.sha256()
    with open(caminho, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def e_ecd(caminho):
    """O arquivo é uma ECD? Pelo conteúdo: o 0000 começa com LECD."""
    with open(caminho, "rb") as fh:
        return fh.read(20).decode(ENCODING, "ignore").startswith("|0000|LECD|")


@dataclass
class Ecd:
    caminho: str
    nome_arquivo: str
    sha256: str
    cnpj: str = ""
    nome: str = ""
    uf: str = ""
    dt_ini: date = None
    dt_fin: date = None
    ind_fin_esc: str = ""
    contas: list = field(default_factory=list)
    saldos: list = field(default_factory=list)
    encerramento: list = field(default_factory=list)
    antes_encerramento: list = field(default_factory=list)
    linhas_lidas: int = 0
    lancamentos: int = 0


def _saldo_assinado(valor, ind):
    """Saldo com sinal: devedor positivo, credor negativo."""
    return valor if ind == "D" else -valor


def parse(caminho):
    ecd = Ecd(caminho=caminho, nome_arquivo=os.path.basename(caminho),
              sha256=sha256(caminho))
    conta_atual = None
    per_ini = per_fin = None
    lcto_encerramento = False
    lcto_data = None
    enc = {}       # (mes, conta) -> [deb, cred]
    dt_res = None

    with open(caminho, "rb") as fh:
        for n, bruto in enumerate(fh, 1):
            linha = bruto.decode(ENCODING, "replace").rstrip("\r\n")
            m = RE_REG.match(linha)
            if not m:
                continue
            reg = m.group(1)
            p = linha.split("|")
            ecd.linhas_lidas += 1

            if reg == "0000":
                # |0000|LECD|DT_INI|DT_FIN|NOME|CNPJ|UF|IE|COD_MUN|IM|IND_SIT_ESP|
                #  IND_SIT_INI_PER|IND_NIRE|IND_FIN_ESC|...
                ecd.dt_ini, ecd.dt_fin = data(campo(p, 3)), data(campo(p, 4))
                ecd.nome, ecd.cnpj, ecd.uf = campo(p, 5), campo(p, 6), campo(p, 7)
                ecd.ind_fin_esc = campo(p, 14)

            elif reg == "I050":
                # |I050|DT_ALT|COD_NAT|IND_CTA|NIVEL|COD_CTA|COD_CTA_SUP|CTA|
                conta_atual = {
                    "cod_cta": campo(p, 6), "cod_cta_sup": campo(p, 7),
                    "nome": campo(p, 8), "cod_nat": campo(p, 3),
                    "ind_cta": campo(p, 4), "nivel": int(campo(p, 5) or 0),
                    "cod_cta_ref": "", "linha": n}
                ecd.contas.append(conta_atual)

            elif reg == "I051" and conta_atual is not None:
                # Leiaute antigo: |I051|COD_PLAN_REF|COD_CCUS|COD_CTA_REF|
                # Leiaute atual:  |I051|COD_CCUS|COD_CTA_REF|
                # Nos dois, a conta referencial é o último campo preenchido.
                valores = [x for x in p[2:-1]]
                if valores and not conta_atual["cod_cta_ref"]:
                    conta_atual["cod_cta_ref"] = valores[-1]

            elif reg == "I150":
                per_ini, per_fin = data(campo(p, 2)), data(campo(p, 3))

            elif reg == "I155":
                # |I155|COD_CTA|COD_CCUS|VL_SL_INI|IND_DC_INI|VL_DEB|VL_CRED|
                #  VL_SL_FIN|IND_DC_FIN|
                ecd.saldos.append({
                    "dt_ini": per_ini, "dt_fin": per_fin,
                    "cod_cta": campo(p, 2), "cod_ccus": campo(p, 3),
                    "sl_ini": _saldo_assinado(dec(campo(p, 4)), campo(p, 5)),
                    "debitos": dec(campo(p, 6)), "creditos": dec(campo(p, 7)),
                    "sl_fin": _saldo_assinado(dec(campo(p, 8)), campo(p, 9)),
                    "linha": n})

            elif reg == "I200":
                # |I200|NUM_LCTO|DT_LCTO|VL_LCTO|IND_LCTO|...
                ecd.lancamentos += 1
                lcto_encerramento = campo(p, 5) == "E"
                lcto_data = data(campo(p, 3))

            elif reg == "I250" and lcto_encerramento and lcto_data:
                # |I250|COD_CTA|COD_CCUS|VL_DC|IND_DC|...
                chave = (lcto_data.replace(day=1), campo(p, 2), campo(p, 3))
                v = dec(campo(p, 4))
                acc = enc.setdefault(chave, [Decimal("0"), Decimal("0")])
                acc[0 if campo(p, 5) == "D" else 1] += v

            elif reg == "I350":
                dt_res = data(campo(p, 2))

            elif reg == "I355":
                # |I355|COD_CTA|COD_CCUS|VL_CTA|IND_DC|
                ecd.antes_encerramento.append({
                    "dt_res": dt_res, "cod_cta": campo(p, 2), "cod_ccus": campo(p, 3),
                    "valor": _saldo_assinado(dec(campo(p, 4)), campo(p, 5)),
                    "linha": n})

    ecd.encerramento = [{"mes": k[0], "cod_cta": k[1], "cod_ccus": k[2],
                         "debitos": v[0], "creditos": v[1]} for k, v in enc.items()]
    return ecd


def confere(ecd):
    """Problemas que impedem ou enfraquecem a leitura do resultado."""
    probs = []
    if not ecd.cnpj:
        probs.append(("sem_0000", "registro 0000 ausente ou sem CNPJ"))
    if not ecd.saldos:
        probs.append(("sem_saldos", "nenhum I155: sem saldos não há balancete"))
    if not any(c["cod_nat"] == "04" for c in ecd.contas):
        probs.append(("sem_resultado", "nenhuma conta de resultado (natureza 04) no plano"))
    meses = {s["dt_ini"] for s in ecd.saldos}
    if ecd.saldos and len(meses) == 1 and ecd.dt_ini and ecd.dt_fin and \
            (ecd.dt_fin - ecd.dt_ini).days > 40:
        probs.append(("saldo_anual", "saldos em um único período para o ano todo: "
                                     "não há resultado mês a mês"))
    sem_ref = sum(1 for c in ecd.contas if c["cod_nat"] == "04" and c["ind_cta"] == "A"
                  and not c["cod_cta_ref"])
    if sem_ref:
        probs.append(("sem_referencial", f"{sem_ref} conta(s) de resultado sem conta "
                                         f"referencial (I051)"))
    return probs
