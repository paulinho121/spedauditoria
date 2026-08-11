# -*- coding: utf-8 -*-
"""
Função serverless do Vercel — painel de leitura.

Diferenças em relação ao servidor local (app/server.py):

  · Vercel executa funções efêmeras, não um processo contínuo. Não há disco
    persistente nem `curl`, e o tempo de execução é limitado. Por isso a
    IMPORTAÇÃO NÃO EXISTE AQUI: ela continua local, via `python -m auditoria`.
  · Os dados vêm por PostgREST com a chave service_role, que nunca sai do
    servidor. Se DATABASE_URL estiver definida, usa Postgres direto (mais rápido).
  · Sessão validada a cada requisição contra o Supabase Auth: a função é
    stateless, não há cache entre invocações.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ESTATICO = os.path.join(RAIZ, "app", "static")

REF = os.environ.get("SUPABASE_PROJECT_REF", "").strip()
ANON = os.environ.get("SUPABASE_ANON_KEY", "").strip()
SERVICE = os.environ.get("SUPABASE_SERVICE_KEY", "").strip()
DATABASE_URL = os.environ.get("DATABASE_URL", "").strip()
COOKIE = "fs_sessao"

MIME = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
        ".js": "application/javascript; charset=utf-8", ".svg": "image/svg+xml",
        ".ico": "image/x-icon"}

LIVRES = {"/login", "/login.html", "/app.css", "/app.js", "/favicon.ico",
          "/api/auth/login"}


class Erro(Exception):
    pass


def _http(metodo, url, corpo=None, headers=None, timeout=20):
    dados = json.dumps(corpo).encode() if corpo is not None else None
    req = urllib.request.Request(url, data=dados, method=metodo)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if dados is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            texto = r.read().decode("utf-8")
            return r.status, (json.loads(texto) if texto.strip() else None)
    except urllib.error.HTTPError as e:
        texto = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(texto)
        except json.JSONDecodeError:
            return e.code, {"raw": texto[:300]}
    except Exception as e:
        raise Erro(f"falha de rede: {e}")


# ------------------------------------------------------------------ dados
def consulta_rest(view, params=None):
    """Lê uma view por PostgREST. A service_role nunca sai do servidor."""
    if not (REF and SERVICE):
        raise Erro("SUPABASE_PROJECT_REF e SUPABASE_SERVICE_KEY não configuradas "
                   "nas variáveis de ambiente do projeto.")
    url = f"https://{REF}.supabase.co/rest/v1/{view}"
    if params:
        url += "?" + urllib.parse.urlencode(params, safe="*.,()")
    codigo, dados = _http("GET", url, headers={
        "apikey": SERVICE, "Authorization": f"Bearer {SERVICE}"})
    if codigo >= 400:
        raise Erro(f"PostgREST {codigo}: {str(dados)[:200]}")
    return dados or []


def consulta_pg(sql, params=None):
    import psycopg
    from psycopg.rows import dict_row
    with psycopg.connect(DATABASE_URL, row_factory=dict_row, connect_timeout=10) as c:
        with c.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall() if cur.description else []


def um(lista):
    return lista[0] if lista else {}


# ------------------------------------------------------------------ sessão
def usuario_de(token):
    if not token or not (REF and ANON):
        return None
    codigo, d = _http("GET", f"https://{REF}.supabase.co/auth/v1/user",
                      headers={"apikey": ANON, "Authorization": f"Bearer {token}"})
    if codigo != 200 or not isinstance(d, dict) or not d.get("id"):
        return None
    return {"id": d["id"], "email": d.get("email")}


def entrar(email, senha):
    if not (REF and ANON):
        raise Erro("Supabase não configurado nas variáveis de ambiente.")
    codigo, d = _http(
        "POST", f"https://{REF}.supabase.co/auth/v1/token?grant_type=password",
        {"email": email, "password": senha}, {"apikey": ANON})
    if codigo != 200:
        msg = (d or {}).get("error_description") or (d or {}).get("msg") or ""
        raise Erro("E-mail ou senha incorretos." if codigo in (400, 401)
                   else (msg or f"Falha na autenticação (HTTP {codigo})."))
    return d.get("access_token"), d.get("user") or {}


# ------------------------------------------------------------------ rotas
def rota_estoque(qs):
    """Posição do estoque numa data. Funcao STABLE: PostgREST aceita por GET."""
    data = (qs.get("data") or [""])[0].strip()
    if not data:
        raise Erro("informe a data")
    limite = min(int((qs.get("limit") or ["60"])[0]), 500)
    offset = int((qs.get("offset") or ["0"])[0])
    ordem = {"valor": "valor.desc", "qtd": "qtd.desc",
             "custo": "custo_medio.desc", "codigo": "cod_item.asc"}.get(
                 (qs.get("ordem") or ["valor"])[0], "valor.desc")
    situacao = (qs.get("situacao") or [""])[0]
    p = {"p_data": data, "order": ordem, "limit": limite, "offset": offset}
    if situacao == "negativo":
        p["qtd"] = "lt.0"
    else:
        p["qtd"] = "neq.0"
        if situacao == "terceiros":
            p["qtd_terceiros"] = "neq.0"
        elif situacao == "proprio":
            p["qtd_proprio"] = "neq.0"
    uf = (qs.get("uf") or [""])[0]
    if uf in ("SP", "CE", "SC"):
        p["uf"] = f"eq.{uf}"
    termo = (qs.get("q") or [""])[0].strip()
    if termo:
        p["busca"] = f"ilike.*{termo.upper()}*"
    linhas = consulta_rest("rpc/estoque_em_detalhe", p)
    total = offset + len(linhas) + (limite if len(linhas) == limite else 0)
    for x in linhas:
        x["total_geral"] = total
    return linhas


def rota_inventario(qs):
    limite = min(int((qs.get("limit") or ["60"])[0]), 500)
    offset = int((qs.get("offset") or ["0"])[0])
    ordem = {"valor": "vl_item.desc", "qtd": "qtd.desc",
             "custo": "vl_unit.desc", "codigo": "cod_item.asc"}.get(
                 (qs.get("ordem") or ["valor"])[0], "vl_item.desc")
    p = {"select": "*", "order": ordem, "limit": limite, "offset": offset}
    uf = (qs.get("uf") or [""])[0]
    if uf in ("SP", "CE", "SC"):
        p["uf"] = f"eq.{uf}"
    termo = (qs.get("q") or [""])[0].strip()
    if termo:
        p["busca"] = f"ilike.*{termo.upper()}*"
    linhas = consulta_rest("v_inventario_busca", p)
    total = len(linhas)
    if linhas:
        # PostgREST devolve a contagem no header; sem ela, estima pelo lote.
        total = offset + len(linhas) + (limite if len(linhas) == limite else 0)
    for x in linhas:
        x["total_geral"] = total
    return linhas


ROTAS = {
    "/api/kpis": lambda qs: um(consulta_rest("v_kpis")),
    "/api/filiais": lambda qs: consulta_rest("v_filiais", {"order": "valor.desc"}),
    "/api/divergencias": lambda qs: consulta_rest(
        "v_custo_inventario_vs_entrada", {"order": "exposicao.desc"}),
    "/api/terceiros": lambda qs: consulta_rest("v_terceiros", {"order": "valor.desc"}),
    "/api/divergencias/detalhe": lambda qs: consulta_rest(
        "v_divergencia_detalhe", {"order": "exposicao.desc"}),
    "/api/divergencias/documentos": lambda qs: consulta_rest(
        "rpc/divergencia_documentos", {
            "p_cnpj": (qs.get("cnpj") or [""])[0],
            "p_cod_item": (qs.get("item") or [""])[0]}),
    "/api/top": lambda qs: consulta_rest(
        "v_inventario", {"order": "vl_item.desc", "limit": 12}),
    "/api/kardex": lambda qs: consulta_rest("rpc/kardex_item", {
        "p_cnpj": (qs.get("cnpj") or [""])[0],
        "p_cod_item": (qs.get("item") or [""])[0],
        "p_ate": (qs.get("ate") or [""])[0] or None,
        "order": "seq.asc"}),
    "/api/inventario": rota_inventario,
    "/api/estoque": rota_estoque,
    "/api/estoque/resumo": lambda qs: um(consulta_rest(
        "rpc/estoque_resumo", {"p_data": (qs.get("data") or [""])[0]})),
    "/api/datas": lambda qs: consulta_rest("v_datas_movimento",
                                           {"order": "dt.desc"}),
    "/api/import/status": lambda qs: dict(um(consulta_rest("v_import_status")),
                                          importacao=bool(DATABASE_URL)),
    "/api/import/pendentes": lambda qs: consulta_rest(
        "item_pendente", {"status": "eq.aberto", "order": "vl_total.desc", "limit": 200}),
    "/api/import/cfops": lambda qs: consulta_rest("v_cfop_nao_classificado"),
    "/api/import/notas": lambda qs: consulta_rest(
        "v_notas", {"order": "dt_emi.desc", "limit": 200}),
}


def estatico(caminho):
    alvo = os.path.normpath(os.path.join(ESTATICO, caminho.lstrip("/")))
    if not alvo.startswith(ESTATICO) or not os.path.isfile(alvo):
        return None, None
    with open(alvo, "rb") as fh:
        return fh.read(), MIME.get(os.path.splitext(alvo)[1], "application/octet-stream")


def app(environ, start_response):
    """WSGI. O runtime Python do Vercel procura por `app`."""
    caminho = environ.get("PATH_INFO", "/") or "/"
    metodo = environ.get("REQUEST_METHOD", "GET")
    qs = urllib.parse.parse_qs(environ.get("QUERY_STRING", ""))

    def responde(status, corpo, ctype="application/json; charset=utf-8", cookie=None):
        if isinstance(corpo, str):
            corpo = corpo.encode("utf-8")
        cabecalhos = [("Content-Type", ctype), ("Content-Length", str(len(corpo))),
                      ("Cache-Control", "no-store"),
                      ("X-Content-Type-Options", "nosniff"),
                      ("Referrer-Policy", "same-origin")]
        if cookie is not None:
            cabecalhos.append(("Set-Cookie", (
                f"{COOKIE}={cookie}; HttpOnly; Secure; SameSite=Strict; Path=/; "
                f"Max-Age={43200 if cookie else 0}")))
        start_response(status, cabecalhos)
        return [corpo]

    token = None
    bruto = environ.get("HTTP_COOKIE")
    if bruto:
        try:
            c = SimpleCookie()
            c.load(bruto)
            token = c[COOKIE].value if COOKIE in c else None
        except Exception:
            token = None

    corpo = {}
    if metodo == "POST":
        try:
            n = int(environ.get("CONTENT_LENGTH") or 0)
            if n:
                corpo = json.loads(environ["wsgi.input"].read(n).decode("utf-8"))
        except Exception as e:
            return responde("400 Bad Request", json.dumps({"erro": f"corpo inválido: {e}"}))

    if caminho == "/api/auth/login" and metodo == "POST":
        try:
            tok, u = entrar((corpo.get("email") or "").strip(), corpo.get("senha") or "")
        except Erro as e:
            return responde("401 Unauthorized", json.dumps({"erro": str(e)}))
        return responde("200 OK",
                        json.dumps({"ok": True, "usuario": {"email": u.get("email")}}),
                        cookie=tok)

    if caminho == "/api/auth/logout":
        return responde("200 OK", json.dumps({"ok": True}), cookie="")

    if caminho in ("/", ""):
        caminho = "/index.html"
    elif caminho == "/reconstrucao":
        caminho = "/reconstrucao.html"
    elif caminho == "/importar":
        caminho = "/importar.html"
    elif caminho == "/login":
        caminho = "/login.html"

    livre = caminho in LIVRES or caminho == "/login.html"
    u = usuario_de(token) if not livre else None
    if not livre and not u:
        if caminho.startswith("/api/"):
            return responde("401 Unauthorized", json.dumps({"erro": "sessão expirada"}))
        destino = urllib.parse.quote(environ.get("PATH_INFO", "/"))
        start_response("302 Found", [("Location", f"/login?de={destino}"),
                                     ("Content-Length", "0")])
        return [b""]

    if caminho == "/api/auth/me":
        return responde("200 OK", json.dumps({"usuario": u}))

    if caminho in ROTAS:
        try:
            return responde("200 OK", json.dumps(ROTAS[caminho](qs), default=str))
        except Erro as e:
            return responde("500 Internal Server Error", json.dumps({"erro": str(e)}))
        except Exception as e:
            return responde("500 Internal Server Error",
                            json.dumps({"erro": f"{type(e).__name__}: {e}"}))

    # Importação não roda em serverless: sem disco e com limite de tempo.
    if caminho.startswith("/api/import/") and metodo == "POST":
        return responde("501 Not Implemented", json.dumps({
            "erro": "A importação roda apenas localmente. Use: "
                    "python -m auditoria importar <arquivos>"}))

    dados, ctype = estatico(caminho)
    if dados is None:
        return responde("404 Not Found", json.dumps({"erro": "não encontrado"}))
    return responde("200 OK", dados, ctype)


# Alguns runtimes procuram `handler` em vez de `app`.
handler = app
