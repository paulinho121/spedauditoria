# -*- coding: utf-8 -*-
"""
Acesso ao banco com dois backends.

  Postgres direto (psycopg 3 + pool) .... quando DATABASE_URL existe. ~15 ms.
  Management API do Supabase ........... fallback. ~1.400 ms, sem transação.

O fallback existe só para o sistema não parar enquanto a senha do banco não
estiver no .env. Carga de dados exige o backend transacional.
"""
import json
import subprocess
import sys
from contextlib import contextmanager

from . import config


class ErroBanco(RuntimeError):
    pass


# --------------------------------------------------------------- backend real
class BackendPostgres:
    transacional = True
    nome = "postgres"

    def __init__(self, dsn):
        from psycopg_pool import ConnectionPool
        from psycopg.rows import dict_row
        self._dict_row = dict_row
        self.pool = ConnectionPool(
            dsn, min_size=1, max_size=8, timeout=20, open=True,
            kwargs={"row_factory": dict_row, "application_name": "auditoria-fiscal"},
        )

    def consulta(self, sql, params=None):
        with self.pool.connection() as con, con.cursor() as cur:
            cur.execute(sql, params)
            if cur.description is None:
                return []
            return cur.fetchall()

    def executa(self, sql, params=None):
        with self.pool.connection() as con, con.cursor() as cur:
            cur.execute(sql, params)
            return cur.rowcount

    @contextmanager
    def transacao(self):
        """Tudo ou nada: um arquivo inteiro entra ou nenhum registro dele entra."""
        with self.pool.connection() as con:
            with con.transaction():
                with con.cursor() as cur:
                    yield _Cursor(cur)

    def fecha(self):
        self.pool.close()


class _Cursor:
    def __init__(self, cur):
        self.cur = cur

    def consulta(self, sql, params=None):
        self.cur.execute(sql, params)
        return self.cur.fetchall() if self.cur.description else []

    def executa(self, sql, params=None):
        self.cur.execute(sql, params)
        return self.cur.rowcount

    def executa_varios(self, sql, seq):
        self.cur.executemany(sql, seq)
        return self.cur.rowcount


# ------------------------------------------------------------ backend fallback
class BackendManagementAPI:
    transacional = False
    nome = "management-api"

    def __init__(self, token, ref):
        if not token:
            raise ErroBanco(
                "Sem DATABASE_URL e sem SBT no .env — não há como falar com o banco.")
        self.url = f"https://api.supabase.com/v1/projects/{ref}/database/query"
        self.token = token

    def _post(self, sql):
        # payload por stdin: arquivo temporário compartilhado gera corrida
        # entre chamadas concorrentes.
        p = subprocess.run(
            ["curl", "-s", "-m", "120", "-X", "POST", self.url,
             "-H", f"Authorization: Bearer {self.token}",
             "-H", "Content-Type: application/json",
             "--data-binary", "@-", "-w", "\n__HTTP__%{http_code}"],
            input=json.dumps({"query": sql}),
            capture_output=True, text=True, encoding="utf-8")
        corpo, _, codigo = p.stdout.rpartition("__HTTP__")
        corpo = corpo.strip()
        if codigo.strip() not in ("200", "201"):
            raise ErroBanco(f"HTTP {codigo.strip()}: {corpo[:400]}")
        return json.loads(corpo) if corpo else []

    def consulta(self, sql, params=None):
        return self._post(_interpola(sql, params))

    def executa(self, sql, params=None):
        self._post(_interpola(sql, params))
        return -1

    @contextmanager
    def transacao(self):
        sys.stderr.write(
            "  AVISO: backend sem transação. Uma falha no meio da carga deixa "
            "dados parciais. Preencha DATABASE_URL no .env.\n")
        yield _CursorFake(self)

    def fecha(self):
        pass


class _CursorFake:
    """
    Emula o cursor sobre a Management API. Sem transação de verdade.

    executa_varios agrupa tudo num INSERT multi-linha: uma chamada por linha
    custaria ~1,4 s cada e uma carga de 2.000 registros levaria 45 minutos.
    """
    LOTE = 400

    def __init__(self, backend):
        self.b = backend

    def consulta(self, sql, params=None):
        return self.b.consulta(sql, params)

    def executa(self, sql, params=None):
        return self.b.executa(sql, params)

    def executa_varios(self, sql, seq):
        linhas = list(seq)
        if not linhas:
            return 0
        cabeca, sep, _ = sql.partition(" values ")
        if not sep:
            for p in linhas:
                self.b.executa(sql, p)
            return len(linhas)
        for i in range(0, len(linhas), self.LOTE):
            parte = linhas[i:i + self.LOTE]
            valores = ",".join(
                "(" + ",".join(_literal(c) for c in linha) + ")" for linha in parte)
            self.b._post(f"{cabeca} values {valores}")
        return len(linhas)


def _literal(v):
    from decimal import Decimal
    import datetime as _dt
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float, Decimal)):
        return str(v)
    if isinstance(v, (_dt.date, _dt.datetime)):
        return "'" + v.isoformat() + "'"
    return "'" + str(v).replace("'", "''") + "'"


def _interpola(sql, params):
    """Só para o fallback: o psycopg faz isso direito no backend real."""
    if not params:
        return sql
    out, i = [], 0
    resto = sql
    for p in params:
        pos = resto.find("%s")
        if pos < 0:
            break
        out.append(resto[:pos])
        out.append(_literal(p))
        resto = resto[pos + 2:]
    out.append(resto)
    return "".join(out)


# ------------------------------------------------------------------- fachada
_backend = None


def conecta(forcar_postgres=False):
    global _backend
    if _backend is not None:
        return _backend
    if config.DATABASE_URL:
        _backend = BackendPostgres(config.DATABASE_URL)
    elif forcar_postgres:
        raise ErroBanco(
            "Esta operação exige conexão direta ao Postgres.\n"
            "Preencha DATABASE_URL no arquivo .env (Supabase → Database → "
            "Connection string → Transaction pooler).")
    else:
        _backend = BackendManagementAPI(config.SUPABASE_TOKEN, config.PROJECT_REF)
    return _backend


def consulta(sql, params=None):
    return conecta().consulta(sql, params)


def executa(sql, params=None):
    return conecta().executa(sql, params)
