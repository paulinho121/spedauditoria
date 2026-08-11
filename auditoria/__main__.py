# -*- coding: utf-8 -*-
"""Entrypoint. Força UTF-8 na saída: o console do Windows usa cp1252 por
padrão e quebra em acentos e sinais tipográficos."""
import sys

for fluxo in (sys.stdout, sys.stderr):
    try:
        fluxo.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

from .cli import main

sys.exit(main())
