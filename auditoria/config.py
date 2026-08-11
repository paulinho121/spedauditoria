# -*- coding: utf-8 -*-
"""Configuração: lê o .env da raiz do projeto. Nenhum segredo mora no código."""
import os
import re

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIGRACOES = os.path.join(RAIZ, "migrations")

_LINHA = re.compile(r"^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$")


def carrega_env(caminho=None):
    """Lê o .env sem depender de biblioteca externa. Não sobrescreve o ambiente."""
    caminho = caminho or os.path.join(RAIZ, ".env")
    if not os.path.exists(caminho):
        return {}
    achados = {}
    with open(caminho, encoding="utf-8") as fh:
        for linha in fh:
            if not linha.strip() or linha.lstrip().startswith("#"):
                continue
            m = _LINHA.match(linha.rstrip("\n"))
            if not m:
                continue
            chave, valor = m.group(1), m.group(2).strip()
            if len(valor) >= 2 and valor[0] == valor[-1] and valor[0] in "\"'":
                valor = valor[1:-1]
            achados[chave] = valor
            os.environ.setdefault(chave, valor)
    return achados


carrega_env()

DATABASE_URL = os.environ.get("DATABASE_URL", "").strip()
SUPABASE_TOKEN = os.environ.get("SBT", "").strip()
PROJECT_REF = os.environ.get("SUPABASE_PROJECT_REF", "ccquyncwgtszhicicvye").strip()

# Onde procurar os arquivos EFD por padrão.
DIR_EFD = os.environ.get("DIR_EFD", os.path.join(os.path.expanduser("~"), "Downloads"))


def resumo():
    """Diagnóstico de configuração, sem vazar segredo."""
    def mascara(v):
        if not v:
            return "(ausente)"
        return f"{v[:8]}…{v[-4:]} ({len(v)} chars)"
    return {
        "raiz": RAIZ,
        "DATABASE_URL": mascara(DATABASE_URL),
        "SBT": mascara(SUPABASE_TOKEN),
        "PROJECT_REF": PROJECT_REF,
        "backend": "postgres direto" if DATABASE_URL else "Management API (degradado)",
    }
