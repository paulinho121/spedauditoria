# -*- coding: utf-8 -*-
"""
Cria um usuário no Supabase Auth para acessar o painel.

A senha é digitada por você, aqui no terminal: não aparece na tela, não é
gravada em arquivo e não passa por lugar nenhum além da chamada ao Supabase.

Uso:
    python criar_usuario.py
    python criar_usuario.py --listar
"""
import getpass
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from auditoria import config  # noqa: E402  (carrega o .env)

REF = config.PROJECT_REF
SERVICE = os.environ.get("SUPABASE_SERVICE_KEY", "").strip()


def http(metodo, caminho, corpo=None):
    url = f"https://{REF}.supabase.co{caminho}"
    cmd = ["curl", "-s", "-m", "40", "-X", metodo, url,
           "-H", f"apikey: {SERVICE}",
           "-H", f"Authorization: Bearer {SERVICE}",
           "-H", "Content-Type: application/json",
           "-w", "\n__HTTP__%{http_code}"]
    if corpo is not None:
        cmd += ["--data-binary", "@-"]
    p = subprocess.run(cmd, input=json.dumps(corpo) if corpo else None,
                       capture_output=True, text=True, encoding="utf-8")
    saida, _, codigo = p.stdout.rpartition("__HTTP__")
    try:
        dados = json.loads(saida.strip()) if saida.strip() else {}
    except json.JSONDecodeError:
        dados = {"raw": saida[:300]}
    return int(codigo.strip() or 0), dados


def listar():
    codigo, d = http("GET", "/auth/v1/admin/users")
    if codigo != 200:
        print(f"  erro {codigo}: {str(d)[:200]}")
        return 1
    usuarios = d.get("users", d if isinstance(d, list) else [])
    if not usuarios:
        print("  Nenhum usuário cadastrado.")
        return 0
    print(f"  {len(usuarios)} usuário(s):")
    for u in usuarios:
        conf = "confirmado" if u.get("email_confirmed_at") else "NÃO confirmado"
        print(f"    {u.get('email'):<40} {conf}  criado {(u.get('created_at') or '')[:10]}")
    return 0


def criar():
    if not SERVICE:
        print("\n  ERRO: SUPABASE_SERVICE_KEY não está no .env.")
        print("  Pegue em Supabase → Project Settings → API → service_role.\n")
        return 1

    print("\n  Criar acesso ao painel de auditoria")
    print("  " + "-" * 52)
    email = input("  E-mail: ").strip()
    if not email or "@" not in email:
        print("  E-mail inválido.")
        return 1

    senha = getpass.getpass("  Senha (não aparece enquanto digita): ")
    if len(senha) < 8:
        print("  A senha precisa de pelo menos 8 caracteres.")
        return 1
    if senha != getpass.getpass("  Repita a senha: "):
        print("  As senhas não conferem.")
        return 1

    codigo, d = http("POST", "/auth/v1/admin/users", {
        "email": email,
        "password": senha,
        "email_confirm": True,          # sem isso o login recusa por e-mail não confirmado
    })
    del senha

    if codigo in (200, 201):
        print(f"\n  Usuário criado: {d.get('email')}")
        print("  Já dá para entrar em http://localhost:8777/login\n")
        return 0
    msg = d.get("msg") or d.get("message") or d.get("error_description") or str(d)[:200]
    if "already been registered" in str(msg) or codigo == 422:
        print(f"\n  Esse e-mail já existe. Para trocar a senha, use o painel do "
              f"Supabase → Authentication → Users.\n")
        return 1
    print(f"\n  Falhou (HTTP {codigo}): {msg}\n")
    return 1


if __name__ == "__main__":
    for f in (sys.stdout, sys.stderr):
        try:
            f.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    sys.exit(listar() if "--listar" in sys.argv else criar())
