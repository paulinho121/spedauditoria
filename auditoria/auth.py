# -*- coding: utf-8 -*-
"""
Autenticação via Supabase Auth.

Login com e-mail e senha contra o endpoint /auth/v1/token do projeto. O token
volta para o servidor e é guardado num cookie HttpOnly — o JavaScript da página
nunca o enxerga, então um XSS não consegue roubá-lo.

A validação chama /auth/v1/user com o token. É mais lento que conferir a
assinatura localmente, mas não exige o segredo do JWT e nunca aceita um token
revogado — o que numa ferramenta de auditoria vale a latência. Sessões válidas
ficam em cache por pouco tempo para não pagar o round-trip a cada requisição.
"""
import json
import os
import subprocess
import time

from . import config

_cache = {}
TTL_CACHE = 120          # segundos que uma sessão validada fica em cache


class ErroAuth(Exception):
    pass


def _base():
    ref = config.PROJECT_REF
    if not ref:
        raise ErroAuth("SUPABASE_PROJECT_REF não configurado")
    return f"https://{ref}.supabase.co"


def _anon():
    chave = (os.environ.get("SUPABASE_ANON_KEY") or "").strip()
    if not chave:
        raise ErroAuth(
            "SUPABASE_ANON_KEY ausente no .env. "
            "Pegue em Supabase → Project Settings → API → anon public.")
    return chave


def _http(metodo, url, corpo=None, token=None, timeout=25):
    """curl: o cliente HTTP do Python é barrado pelo Cloudflare nesta conta."""
    cmd = ["curl", "-s", "-m", str(timeout), "-X", metodo, url,
           "-H", f"apikey: {_anon()}",
           "-H", "Content-Type: application/json",
           "-w", "\n__HTTP__%{http_code}"]
    if token:
        cmd += ["-H", f"Authorization: Bearer {token}"]
    if corpo is not None:
        cmd += ["--data-binary", "@-"]
    p = subprocess.run(cmd, input=json.dumps(corpo) if corpo is not None else None,
                       capture_output=True, text=True, encoding="utf-8")
    saida, _, codigo = p.stdout.rpartition("__HTTP__")
    try:
        dados = json.loads(saida.strip()) if saida.strip() else {}
    except json.JSONDecodeError:
        dados = {"raw": saida[:300]}
    return int(codigo.strip() or 0), dados


def entrar(email, senha):
    """Devolve (access_token, refresh_token, usuario). Levanta ErroAuth."""
    if not email or not senha:
        raise ErroAuth("Informe e-mail e senha.")
    codigo, d = _http("POST", f"{_base()}/auth/v1/token?grant_type=password",
                      {"email": email, "password": senha})
    if codigo != 200:
        msg = d.get("error_description") or d.get("msg") or d.get("message") or ""
        if "Invalid login" in msg or codigo == 400:
            raise ErroAuth("E-mail ou senha incorretos.")
        if "Email not confirmed" in msg:
            raise ErroAuth("E-mail ainda não confirmado. Confirme no painel do Supabase.")
        raise ErroAuth(msg or f"Falha na autenticação (HTTP {codigo}).")
    return d.get("access_token"), d.get("refresh_token"), d.get("user") or {}


def usuario(token):
    """Valida o token. Devolve o usuário ou None."""
    if not token:
        return None
    agora = time.time()
    hit = _cache.get(token)
    if hit and agora - hit[0] < TTL_CACHE:
        return hit[1]
    codigo, d = _http("GET", f"{_base()}/auth/v1/user", token=token)
    if codigo != 200 or not d.get("id"):
        _cache.pop(token, None)
        return None
    u = {"id": d.get("id"), "email": d.get("email"),
         "nome": (d.get("user_metadata") or {}).get("nome") or d.get("email")}
    _cache[token] = (agora, u)
    return u


def sair(token):
    _cache.pop(token, None)
    if token:
        try:
            _http("POST", f"{_base()}/auth/v1/logout", corpo={}, token=token)
        except Exception:
            pass
    return True
