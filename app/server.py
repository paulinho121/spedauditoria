# -*- coding: utf-8 -*-
"""
Servidor local da auditoria fiscal de estoque.

Le os dados do Supabase (projeto ccquyncwgtszhicicvye) e serve o painel.
O token NUNCA vai para o browser: fica so aqui no servidor.

Token: variavel de ambiente SBT, ou arquivo .env na pasta pai com SBT=...
Uso:   python server.py [porta]
"""
import json
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
PROJECT_REF = "ccquyncwgtszhicicvye"
API = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
CACHE_TTL = 30          # segundos
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8777


def load_token():
    tok = os.environ.get("SBT", "").strip()
    if tok:
        return tok
    for env in (os.path.join(HERE, ".env"), os.path.join(os.path.dirname(HERE), ".env")):
        if os.path.exists(env):
            for line in open(env, encoding="utf-8"):
                m = re.match(r"\s*(?:export\s+)?SBT\s*=\s*(.+)", line)
                if m:
                    return m.group(1).strip().strip('"').strip("'")
    sys.exit("ERRO: token nao encontrado. Defina SBT no ambiente ou em um arquivo .env")


TOKEN = load_token()
_cache = {}


def query(sql):
    """Consulta o Postgres via Management API. Usa curl: o urllib e barrado pelo Cloudflare."""
    now = time.time()
    hit = _cache.get(sql)
    if hit and now - hit[0] < CACHE_TTL:
        return hit[1]
    # payload por stdin: com arquivo temporario fixo, chamadas concorrentes
    # sobrescreviam o payload umas das outras e o curl mandava a query errada.
    p = subprocess.run(
        ["curl", "-s", "-m", "60", "-X", "POST", API,
         "-H", f"Authorization: Bearer {TOKEN}",
         "-H", "Content-Type: application/json",
         "--data-binary", "@-",
         "-w", "\n__HTTP__%{http_code}"],
        input=json.dumps({"query": sql}),
        capture_output=True, text=True, encoding="utf-8")
    body, _, code = p.stdout.rpartition("__HTTP__")
    body = body.strip()
    if code.strip() not in ("200", "201"):
        raise RuntimeError(f"HTTP {code.strip()}: {body[:300]}")
    data = json.loads(body) if body else []
    _cache[sql] = (now, data)
    return data


# ------------------------------------------------------------------ consultas
SQL_KPIS = """
select
  (select count(*) from inventario_item)                       as itens,
  (select sum(qtd) from inventario_item)                       as unidades,
  (select sum(vl_item) from inventario_item)                   as valor,
  (select count(*) from estabelecimento)                       as filiais,
  (select count(*) from sped_arquivo)                          as arquivos,
  (select count(*) from doc_fiscal)                            as documentos,
  (select count(*) from inventario_item where qtd < 0)         as negativos,
  (select count(*) from v_custo_inventario_vs_entrada)         as div_itens,
  (select coalesce(sum(exposicao),0)
     from v_custo_inventario_vs_entrada)                       as div_exposicao,
  (select coalesce(sum(vl_item),0) from inventario_item
     where ind_prop = '1')                                     as em_terceiros,
  (select count(*) from v_inventario_conferencia
     where abs(diferenca) < 0.005)                             as conf_ok,
  (select count(*) from v_inventario_conferencia)              as conf_total,
  (select max(dt_inv)::text from inventario)                   as data_base
"""

SQL_FILIAIS = """
select c.uf, c.cnpj, e.nome, c.qtd_itens, c.qtd_total, c.vl_somado_h010 as valor,
       c.vl_declarado_h005 as declarado, c.diferenca
from v_inventario_conferencia c
join estabelecimento e on e.cnpj = c.cnpj
order by c.vl_somado_h010 desc
"""

SQL_DIVERG = """
select uf, cod_item, descr_item, qtd, custo_inventario, custo_entrada, multiplo, exposicao
from v_custo_inventario_vs_entrada order by exposicao desc
"""

SQL_TERCEIROS = """
select uf, cnpj, depositario, count(*) as itens, sum(vl_item) as valor
from v_inventario where ind_prop = '1'
group by uf, cnpj, depositario order by valor desc
"""

SQL_TOP = """
select uf, cod_item, descr_item, qtd, vl_unit, vl_item
from v_inventario order by vl_item desc limit 12
"""


def sql_kardex(cnpj, cod_item, ate):
    lim = lambda v: str(v).replace("'", "")[:44]
    ate_sql = f"date '{lim(ate)}'" if ate else "null"
    return (f"select * from kardex_item('{lim(cnpj)}', '{lim(cod_item)}', {ate_sql})")


def sql_estoque(data, uf, termo, limit, offset, ordem, situacao=""):
    d = data.replace("'", "")
    # "negativo" e o unico filtro que precisa enxergar saldo <= 0; os demais
    # ignoram itens zerados, que so poluem a lista.
    w = ["qtd < 0"] if situacao == "negativo" else ["qtd <> 0"]
    if situacao == "terceiros":
        w.append("qtd_terceiros <> 0")
    elif situacao == "proprio":
        w.append("qtd_proprio <> 0")
    if uf in ("SP", "CE", "SC"):
        w.append(f"uf = '{uf}'")
    if termo:
        w.append("busca like '%" + termo.replace("'", "''").upper() + "%'")
    cols = {"valor": "valor desc", "qtd": "qtd desc",
            "custo": "custo_medio desc", "codigo": "cod_item"}
    return (f"select *, count(*) over() as total_geral "
            f"from estoque_em_detalhe(date '{d}') where {' and '.join(w)} "
            f"order by {cols.get(ordem, 'valor desc')} "
            f"limit {int(limit)} offset {int(offset)}")


def sql_inventario(uf, termo, limit, offset, ordem):
    w = ["1=1"]
    if uf in ("SP", "CE", "SC"):
        w.append(f"uf = '{uf}'")
    if termo:
        t = termo.replace("'", "''").upper()
        w.append(f"(upper(descr_item) like '%{t}%' or upper(cod_item) like '%{t}%' "
                 f"or coalesce(ncm,'') like '%{t}%')")
    cols = {"valor": "vl_item desc", "qtd": "qtd desc",
            "custo": "vl_unit desc", "codigo": "cod_item"}
    return (f"select uf, cnpj, cod_item, descr_item, ncm, unid, qtd, vl_unit, vl_item, "
            f"ind_prop, ind_prop_desc, depositario, "
            f"count(*) over() as total_geral "
            f"from v_inventario where {' and '.join(w)} "
            f"order by {cols.get(ordem, 'vl_item desc')} limit {int(limit)} offset {int(offset)}")


SQL_IMPORT_STATUS = """
select
  (select count(*) from nfe)                                   as notas,
  (select count(*) from nfe where situacao <> 'autorizada')     as nao_autorizadas,
  (select count(*) from nfe_item)                               as itens_nota,
  (select count(*) from movimento where origem = 'nfe')         as movimentos,
  (select count(*) from item_pendente where status = 'aberto')  as pendentes,
  (select count(*) from v_cfop_nao_classificado)                as cfops_abertos,
  (select min(dt_emi)::text from nfe)                           as primeira,
  (select max(dt_emi)::text from nfe)                           as ultima,
  (select coalesce(sum(vl_item),0) from saldo_abertura)         as abertura
"""

SQL_PENDENTES = """
select cnpj, parceiro_doc, parceiro_nome, c_prod_externo, x_prod, ncm, u_com,
       ocorrencias, qtd_total, vl_total, primeira_chave
from item_pendente where status = 'aberto'
order by vl_total desc nulls last limit 200
"""

SQL_NOTAS = """
select n.chave, n.num_nf, n.serie, n.dt_emi, n.nat_op, n.emit_cnpj, n.emit_nome,
       n.dest_doc, n.dest_nome, n.vl_nf, n.situacao, n.nome_arquivo,
       (select count(*) from nfe_item i where i.nfe_id = n.id)  as itens,
       (select count(*) from movimento m where m.nfe_id = n.id) as movs
from nfe n order by n.dt_emi desc nulls last, n.id desc limit 200
"""


def _sobe_auditoria():
    raiz = os.path.dirname(HERE)
    if raiz not in sys.path:
        sys.path.insert(0, raiz)


def importar_pasta(body):
    _sobe_auditoria()
    from auditoria import carga_nfe
    pasta = (body or {}).get("pasta") or os.path.join(os.path.dirname(HERE), "xmls")
    if not os.path.isdir(pasta):
        return {"erro": f"pasta não encontrada: {pasta}"}
    res = carga_nfe.importa_pasta(pasta)
    _cache.clear()
    return {"pasta": pasta, "resumo": carga_nfe.resumo(res),
            "arquivos": [r.dict() for r in res]}


def importar_upload(body):
    """Recebe os XMLs enviados pelo navegador, grava em disco e importa."""
    _sobe_auditoria()
    from auditoria import carga_nfe
    destino = os.path.join(os.path.dirname(HERE), "xmls", "recebidos")
    os.makedirs(destino, exist_ok=True)
    gravados = []
    for arq in (body or {}).get("arquivos", []):
        nome = os.path.basename(arq.get("nome") or "")
        if not nome.lower().endswith(".xml"):
            continue
        caminho = os.path.join(destino, nome)
        with open(caminho, "w", encoding="utf-8", newline="") as fh:
            fh.write(arq.get("conteudo") or "")
        gravados.append(caminho)
    if not gravados:
        return {"erro": "nenhum arquivo .xml recebido"}
    cache, res = {}, []
    for c in gravados:
        res.append(carga_nfe.importa(c, cache=cache))
    _cache.clear()
    return {"destino": destino, "resumo": carga_nfe.resumo(res),
            "arquivos": [r.dict() for r in res]}


def _auth():
    _sobe_auditoria()
    from auditoria import auth
    return auth


def entrar(body):
    a = _auth()
    try:
        token, _refresh, u = a.entrar((body or {}).get("email", "").strip(),
                                      (body or {}).get("senha", ""))
    except a.ErroAuth as e:
        return {"erro": str(e)}, None
    return {"ok": True, "usuario": {"email": u.get("email")}}, token


def sair(body, token=None):
    _auth().sair(token)
    return {"ok": True}, ""


POSTS = {"/api/import/pasta": importar_pasta, "/api/import/upload": importar_upload}

# Rotas que dispensam sessão. Todo o resto exige login.
LIVRES = {"/login", "/login.html", "/app.css", "/app.js", "/favicon.ico",
          "/api/auth/login"}

ROUTES = {
    "/api/import/status": lambda qs: dict(query(SQL_IMPORT_STATUS)[0], importacao=True),
    "/api/import/pendentes": lambda qs: query(SQL_PENDENTES),
    "/api/import/cfop/detalhe": lambda qs: query(
        "select * from cfop_aberto_detalhe('"
        + (qs.get("cfop") or [""])[0].replace("'", "") + "')"),
    "/api/import/sugestoes": lambda qs: query(
        "select * from item_pendente_sugestoes('"
        + (qs.get("cnpj") or [""])[0].replace("'", "") + "','"
        + (qs.get("prod") or [""])[0].replace("'", "") + "')"),
    "/api/import/cfops": lambda qs: query("select * from v_cfop_nao_classificado limit 100"),
    "/api/import/notas": lambda qs: query(SQL_NOTAS),
    "/api/kpis": lambda qs: query(SQL_KPIS)[0],
    "/api/filiais": lambda qs: query(SQL_FILIAIS),
    "/api/divergencias": lambda qs: query(SQL_DIVERG),
    "/api/divergencias/detalhe": lambda qs: query(
        "select * from v_divergencia_detalhe order by exposicao desc"),
    "/api/divergencias/documentos": lambda qs: query(
        "select * from divergencia_documentos('"
        + (qs.get("cnpj") or [""])[0].replace("'", "") + "','"
        + (qs.get("item") or [""])[0].replace("'", "") + "')"),
    "/api/terceiros": lambda qs: query(SQL_TERCEIROS),
    "/api/top": lambda qs: query(SQL_TOP),
    "/api/relatorio": lambda qs: query(
        "select * from relatorio_achados(date '"
        + (qs.get("data") or ["2022-12-31"])[0].replace("'", "") + "')"),
    "/api/relatorio/resumo": lambda qs: query(
        "select * from relatorio_resumo(date '"
        + (qs.get("data") or ["2022-12-31"])[0].replace("'", "") + "')")[0],
    "/api/relatorio/fontes": lambda qs: query("select * from v_relatorio_fontes"),
    "/api/kardex": lambda qs: query(sql_kardex(
        (qs.get("cnpj") or [""])[0],
        (qs.get("item") or [""])[0],
        (qs.get("ate") or [""])[0])),
    "/api/estoque": lambda qs: query(sql_estoque(
        (qs.get("data") or ["2022-12-31"])[0],
        (qs.get("uf") or [""])[0],
        (qs.get("q") or [""])[0],
        min(int((qs.get("limit") or ["60"])[0]), 500),
        int((qs.get("offset") or ["0"])[0]),
        (qs.get("ordem") or ["valor"])[0],
        (qs.get("situacao") or [""])[0])),
    "/api/estoque/resumo": lambda qs: query(
        "select * from estoque_resumo(date '"
        + (qs.get("data") or ["2022-12-31"])[0].replace("'", "") + "')")[0],
    "/api/datas": lambda qs: query(
        "select dt::text, movimentos, filiais from v_datas_movimento order by dt desc"),
    "/api/inventario": lambda qs: query(sql_inventario(
        (qs.get("uf") or [""])[0],
        (qs.get("q") or [""])[0],
        min(int((qs.get("limit") or ["60"])[0]), 500),
        int((qs.get("offset") or ["0"])[0]),
        (qs.get("ordem") or ["valor"])[0])),
}

MIME = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
        ".js": "application/javascript; charset=utf-8", ".svg": "image/svg+xml"}


def vigia_arquivos(intervalo=1.0):
    """
    Reinicia o processo quando um .py do projeto muda.

    Sem isto, editar o servidor e esquecer de reiniciá-lo faz a interface nova
    conversar com a lógica antiga. O sintoma não parece um servidor velho:
    parece funcionalidade quebrada. Aconteceu com o filtro de saldo negativo,
    que devolvia a lista inteira porque o processo em memória não conhecia o
    parâmetro que a página passou a enviar.

    Antes de reiniciar, confere se o arquivo compila. Editor salvando pela
    metade, ou erro de sintaxe, derrubaria o servidor num ciclo de reinícios.
    """
    import threading

    raiz = os.path.dirname(HERE)
    alvos = [os.path.join(HERE, "server.py")]
    pasta = os.path.join(raiz, "auditoria")
    if os.path.isdir(pasta):
        alvos += [os.path.join(pasta, f)
                  for f in sorted(os.listdir(pasta)) if f.endswith(".py")]
    marca = {a: os.path.getmtime(a) for a in alvos if os.path.exists(a)}

    def laco():
        while True:
            time.sleep(intervalo)
            for alvo in list(marca):
                try:
                    agora = os.path.getmtime(alvo)
                except OSError:
                    continue
                if agora == marca[alvo]:
                    continue
                marca[alvo] = agora
                nome = os.path.basename(alvo)
                try:
                    # compile() nao escreve nada. py_compile com cfile=os.devnull
                    # falha no Windows: 'nul' nao e arquivo regular, a checagem
                    # errava sempre e a recarga nunca acontecia.
                    with open(alvo, "rb") as fh:
                        compile(fh.read(), alvo, "exec")
                except (SyntaxError, ValueError) as e:
                    sys.stderr.write(
                        "\n  " + nome + " nao compila — servidor mantido no ar\n"
                        "    " + type(e).__name__ + ": " + str(e)[:160] + "\n\n")
                    sys.stderr.flush()
                    continue
                sys.stderr.write("\n  " + nome + " mudou — reiniciando\n\n")
                sys.stderr.flush()
                os.execv(sys.executable, [sys.executable] + sys.argv)

    threading.Thread(target=laco, daemon=True).start()
    return len(marca)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        try:
            msg = fmt % args
        except Exception:
            msg = " ".join(str(a) for a in args)
        if "/api/" in msg or " 4" in msg or " 5" in msg:
            sys.stderr.write("  %s\n" % msg)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            n = int(self.headers.get("Content-Length") or 0)
            corpo = json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
        except Exception as e:
            return self._send(400, json.dumps({"erro": f"corpo inválido: {e}"}))

        if path == "/api/auth/login":
            try:
                dados, token = entrar(corpo)
            except Exception as e:
                return self._send(500, json.dumps({"erro": str(e)}))
            if token is None:
                return self._send(401, json.dumps(dados))
            sys.stderr.write(f"  login: {dados['usuario']['email']}\n")
            return self._send(200, json.dumps(dados), cookie=token)

        if path == "/api/auth/logout":
            dados, _ = sair(corpo, self._token())
            return self._send(200, json.dumps(dados), cookie="")

        if not self._usuario():
            return self._send(401, json.dumps({"erro": "sessão expirada"}))

        rota = POSTS.get(path)
        if not rota:
            return self._send(404, json.dumps({"erro": "rota inexistente"}))
        try:
            return self._send(200, json.dumps(rota(corpo), default=str))
        except Exception as e:
            import traceback
            traceback.print_exc()
            return self._send(500, json.dumps({"erro": f"{type(e).__name__}: {e}"}))

    COOKIE = "fs_sessao"

    def _send(self, code, body, ctype="application/json; charset=utf-8",
              cookie=None, extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        if cookie is not None:
            if cookie:
                self.send_header(
                    "Set-Cookie",
                    f"{self.COOKIE}={cookie}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200")
            else:
                self.send_header(
                    "Set-Cookie",
                    f"{self.COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _token(self):
        from http.cookies import SimpleCookie
        bruto = self.headers.get("Cookie")
        if not bruto:
            return None
        try:
            c = SimpleCookie()
            c.load(bruto)
            m = c.get(self.COOKIE)
            return m.value if m else None
        except Exception:
            return None

    def _usuario(self):
        return _auth().usuario(self._token())

    def do_GET(self):
        u = urlparse(self.path)
        path, qs = u.path, parse_qs(u.query)

        if path not in LIVRES and not self._usuario():
            if path.startswith("/api/"):
                return self._send(401, json.dumps({"erro": "sessão expirada"}))
            from urllib.parse import quote
            return self._send(302, b"", "text/plain",
                              extra={"Location": f"/login?de={quote(path)}"})

        if path == "/api/auth/me":
            return self._send(200, json.dumps({"usuario": self._usuario()}))

        if path in ROUTES:
            try:
                return self._send(200, json.dumps(ROUTES[path](qs), default=str))
            except Exception as e:
                sys.stderr.write(f"  ERRO {path}: {e}\n")
                return self._send(500, json.dumps({"erro": str(e)}))

        if path == "/":
            path = "/index.html"
        if path == "/reconstrucao":
            path = "/reconstrucao.html"
        if path == "/importar":
            path = "/importar.html"
        if path == "/relatorio":
            path = "/relatorio.html"
        if path == "/login":
            path = "/login.html"

        alvo = os.path.normpath(os.path.join(STATIC, path.lstrip("/")))
        if not alvo.startswith(STATIC) or not os.path.isfile(alvo):
            return self._send(404, "404", "text/plain; charset=utf-8")
        ext = os.path.splitext(alvo)[1]
        with open(alvo, "rb") as fh:
            self._send(200, fh.read(), MIME.get(ext, "application/octet-stream"))


if __name__ == "__main__":
    try:
        k = query(SQL_KPIS)[0]
        print(f"Banco OK  -> {k['itens']} itens de inventario, R$ {float(k['valor']):,.2f}, "
              f"data base {k['data_base']}")
    except Exception as e:
        print(f"AVISO: nao consegui falar com o banco agora ({e}).")
        print("O servidor sobe assim mesmo; o painel mostra o erro na tela.")
    if os.environ.get("SEM_RELOAD"):
        print("  Recarga automatica: desligada (SEM_RELOAD)")
    else:
        print(f"  Recarga automatica: vigiando {vigia_arquivos()} arquivos .py")
    print(f"\n  Auditoria Fiscal de Estoque")
    print(f"  http://localhost:{PORT}\n")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
# toque para testar a recarga automatica
