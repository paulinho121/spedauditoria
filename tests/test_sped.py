# -*- coding: utf-8 -*-
"""
Testes do parser.

O golden guarda apenas contagens, totais e hashes — nunca os dados fiscais do
cliente. Assim o teste pode viver no repositório sem carregar informação
sigilosa junto.

Para (re)gerar o golden depois de uma mudança intencional:
    python -m tests.test_sped --gerar

Rodar:
    python -m pytest tests -q          (se pytest existir)
    python -m tests.test_sped          (sem dependência nenhuma)
"""
import json
import os
import sys
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from auditoria import config, sped  # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(AQUI, "golden_efd.json")

ARQUIVOS = [
    "05502390000383-136361022119-20230201-20230228-1-"
    "FDD8ACBC0E5B50284A5788D9513947EFB732EC8E-SPED-EFD.txt",
    "SpedEFD-05502390000111-066757550-Remessa de arquivo substituto-fev2023.txt",
    "05502390000200-261266659-20230201-20230228-1-"
    "F05610F017142E43121EEB8E6703404CFEB02A11-SPED-EFD.txt",
]


def caminhos():
    achados, faltando = [], []
    for nome in ARQUIVOS:
        p = os.path.join(config.DIR_EFD, nome)
        (achados if os.path.exists(p) else faltando).append(p)
    return achados, faltando


# ----------------------------------------------------------- testes unitários
def test_dec():
    assert sped.dec("1.234,56") == Decimal("1234.56")
    assert sped.dec("845,71") == Decimal("845.71")
    assert sped.dec("13842,8") == Decimal("13842.8")
    assert sped.dec("0") == Decimal("0")
    assert sped.dec("") is None, "campo vazio não é zero — a distinção importa"
    assert sped.dec(None) is None
    assert sped.dec("lixo") is None
    assert sped.dec("-5,00") == Decimal("-5.00")
    # sem perda de precisão: o valor tem que sobreviver ao ida e volta
    assert str(sped.dec("11114,26")) == "11114.26"


def test_data():
    from datetime import date
    assert sped.data("31122022") == date(2022, 12, 31)
    assert sped.data("01022023") == date(2023, 2, 1)
    assert sped.data("") is None
    assert sped.data("3112202") is None
    assert sped.data("32122022") is None, "dia inválido deve virar None, não estourar"


def test_norm_descr():
    a = sped.norm_descr("LIGHT DOME MINI II - ACESSÓRIO TIPO GRID")
    b = sped.norm_descr("light dome mini ii. acessorio tipo grid")
    assert a == b, "acento e pontuação não podem separar o mesmo produto"
    assert sped.norm_descr("") == ""
    assert len(sped.norm_descr("X" * 200)) == 40


def test_regex_registro():
    assert sped.RE_REGISTRO.match("|0000|017|1|")
    assert sped.RE_REGISTRO.match("|H010|3990|UN|")
    assert sped.RE_REGISTRO.match("|C170|1|4082|")
    assert not sped.RE_REGISTRO.match("0000|017|"), "sem pipe inicial não é registro"
    assert not sped.RE_REGISTRO.match("|\x80\x9d lixo binário|")


def test_campo_fora_do_limite():
    assert sped.campo(["", "H010", "3990"], 99) == "", \
        "linha curta não pode estourar IndexError"


# ------------------------------------------------------------- testes golden
def _digest_todos(ps):
    return {os.path.basename(p): sped.digest(sped.parse(p)) for p in ps}


def test_golden():
    achados, faltando = caminhos()
    if not achados:
        print("  PULADO: nenhum EFD encontrado em", config.DIR_EFD)
        return
    if not os.path.exists(GOLDEN):
        print("  PULADO: golden ausente. Gere com: python -m tests.test_sped --gerar")
        return

    esperado = json.load(open(GOLDEN, encoding="utf-8"))
    atual = _digest_todos(achados)

    for nome, esp in esperado.items():
        assert nome in atual, f"arquivo do golden não encontrado: {nome}"
        got = atual[nome]
        for chave, valor in esp.items():
            assert got[chave] == valor, (
                f"\n  {nome}\n  campo '{chave}'\n"
                f"  esperado: {valor}\n  obtido:   {got[chave]}")
    print(f"  golden ok para {len(esperado)} arquivo(s)")


def test_invariantes_dos_arquivos_reais():
    """Verdades que precisam valer para qualquer EFD, não só para estes."""
    achados, _ = caminhos()
    if not achados:
        print("  PULADO: sem arquivos")
        return
    for p in achados:
        efd = sped.parse(p)
        nome = os.path.basename(p)[:28]

        assert efd.cnpj and len(efd.cnpj) == 14, f"{nome}: CNPJ inválido"
        assert efd.dt_ini and efd.dt_fin and efd.dt_ini <= efd.dt_fin, f"{nome}: período"

        for reg, declarado in efd.contadores_9900.items():
            assert efd.contagem.get(reg, 0) == declarado, (
                f"{nome}: registro {reg} — 9900 diz {declarado}, "
                f"li {efd.contagem.get(reg, 0)}")

        if efd.inventario:
            soma = sum(i["vl_item"] for i in efd.inventario_itens)
            assert abs(efd.inventario["vl_inv"] - soma) < Decimal("0.01"), (
                f"{nome}: H005 {efd.inventario['vl_inv']} ≠ soma H010 {soma}")

        cods = {i["cod_item"] for i in efd.itens}
        orfaos = {h["cod_item"] for h in efd.inventario_itens} - cods
        assert not orfaos, f"{nome}: itens do H010 sem 0200: {sorted(orfaos)[:3]}"

        for d in efd.documentos:
            for it in d["itens"]:
                assert it["cod_item"], f"{nome}: C170 sem COD_ITEM (índice de campo errado?)"
        print(f"  invariantes ok  {nome}")


def gerar_golden():
    achados, faltando = caminhos()
    if faltando:
        for f in faltando:
            print(f"  ausente: {os.path.basename(f)}")
    if not achados:
        print("Nenhum arquivo para gerar o golden.")
        return 1
    d = _digest_todos(achados)
    with open(GOLDEN, "w", encoding="utf-8") as fh:
        json.dump(d, fh, ensure_ascii=False, indent=2, sort_keys=True)
    print(f"Golden gravado com {len(d)} arquivo(s) em {GOLDEN}")
    return 0


def main():
    if "--gerar" in sys.argv:
        return gerar_golden()
    testes = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    falhas = 0
    for t in testes:
        try:
            t()
            print(f"  PASSOU  {t.__name__}")
        except AssertionError as e:
            falhas += 1
            print(f"  FALHOU  {t.__name__}: {e}")
        except Exception as e:
            falhas += 1
            print(f"  ERRO    {t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(testes) - falhas}/{len(testes)} testes passaram")
    return 1 if falhas else 0


if __name__ == "__main__":
    for f in (sys.stdout, sys.stderr):
        try:
            f.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    sys.exit(main())
