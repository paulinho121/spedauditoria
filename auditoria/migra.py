# -*- coding: utf-8 -*-
"""
Aplicador de migrações.

Regras:
  1. Migrações rodam em ordem numérica e só uma vez.
  2. O SHA-256 de cada arquivo aplicado fica registrado.
  3. Se um arquivo já aplicado mudar no disco, a aplicação PARA e avisa.

A regra 3 é o ponto. O que nos custou o schema foi mudança silenciosa de estado:
o projeto restaurou um snapshot e apagou as tabelas sem nenhum sinal. Detectar
divergência entre o que o repositório diz e o que o banco tem é o mínimo para
que um resultado de auditoria seja reproduzível.
"""
import hashlib
import os
import re

from . import config, db

CONTROLE = """
create table if not exists schema_migracao (
  versao      text primary key,
  nome        text not null,
  sha256      text not null,
  aplicada_em timestamptz not null default now(),
  duracao_ms  int
);
comment on table schema_migracao is
  'Controle de migracoes. O sha256 detecta alteracao em migracao ja aplicada.';
"""

RE_NOME = re.compile(r"^(\d+)[_-](.+)\.sql$", re.I)


def _arquivos():
    if not os.path.isdir(config.MIGRACOES):
        return []
    out = []
    for nome in sorted(os.listdir(config.MIGRACOES)):
        m = RE_NOME.match(nome)
        if m:
            caminho = os.path.join(config.MIGRACOES, nome)
            sql = open(caminho, encoding="utf-8").read()
            out.append({
                "versao": m.group(1),
                "nome": m.group(2),
                "arquivo": nome,
                "sql": sql,
                "sha256": hashlib.sha256(sql.encode("utf-8")).hexdigest(),
            })
    return out


def _confere_numeracao(arquivos):
    """
    Dois arquivos com o mesmo número são a mesma migração para o controle, que
    guarda só o número. O segundo chegava como 'ALTERADA' e o aplicador mandava
    criar uma migração nova — quando o problema era outro. Melhor recusar cedo,
    com o diagnóstico certo.
    """
    vistos = {}
    for m in arquivos:
        vistos.setdefault(m["versao"], []).append(m["arquivo"])
    duplicados = {v: nomes for v, nomes in vistos.items() if len(nomes) > 1}
    if duplicados:
        linhas = "\n".join(f"    {v}: " + ", ".join(sorted(n))
                           for v, n in sorted(duplicados.items()))
        raise RuntimeError(
            "Número de migração repetido:\n" + linhas +
            "\n  Cada migração precisa de um número próprio. Renumere a mais "
            "recente para o próximo livre.")


def estado():
    con = db.conecta()
    con.executa(CONTROLE)
    aplicadas = {r["versao"]: r for r in
                 con.consulta("select versao, nome, sha256, aplicada_em from schema_migracao")}
    arquivos = _arquivos()
    _confere_numeracao(arquivos)
    saida = []
    for mig in arquivos:
        ap = aplicadas.get(mig["versao"])
        if ap is None:
            situacao = "pendente"
        elif ap["sha256"] != mig["sha256"]:
            situacao = "ALTERADA"
        else:
            situacao = "aplicada"
        saida.append({**mig, "situacao": situacao,
                      "aplicada_em": ap["aplicada_em"] if ap else None})
    return saida


def aplica(forcar_reaplicar=False):
    import time
    con = db.conecta()
    con.executa(CONTROLE)

    itens = estado()
    alteradas = [m for m in itens if m["situacao"] == "ALTERADA"]
    if alteradas and not forcar_reaplicar:
        linhas = "\n".join(f"    {m['arquivo']}" for m in alteradas)
        raise RuntimeError(
            "Migração já aplicada foi alterada no disco:\n" + linhas +
            "\n  O banco pode não corresponder ao repositório. Crie uma migração "
            "nova em vez de editar uma antiga.")

    pendentes = [m for m in itens if m["situacao"] == "pendente"]
    if not pendentes:
        print(f"  Nada a aplicar. {len(itens)} migrações já estão no banco.")
        return []

    feitas = []
    for m in pendentes:
        t0 = time.time()
        con.executa(m["sql"])
        ms = int((time.time() - t0) * 1000)
        con.executa(
            "insert into schema_migracao (versao, nome, sha256, duracao_ms) "
            "values (%s, %s, %s, %s) on conflict (versao) do update set "
            "sha256 = excluded.sha256, aplicada_em = now(), duracao_ms = excluded.duracao_ms",
            (m["versao"], m["nome"], m["sha256"], ms))
        print(f"  aplicada  {m['arquivo']}  ({ms} ms)")
        feitas.append(m["versao"])
    return feitas
