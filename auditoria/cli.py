# -*- coding: utf-8 -*-
"""
Linha de comando da auditoria.

  python -m auditoria config              diagnóstico de configuração
  python -m auditoria migrar              aplica migrações pendentes
  python -m auditoria status              o que já está no banco
  python -m auditoria importar <arqs...>  importa EFDs (idempotente)
  python -m auditoria conferir <arqs...>  só valida, não grava
  python -m auditoria varrer [data]       executa as regras e concilia os achados
  python -m auditoria achados [filtro]    lista os achados em aberto
  python -m auditoria materialidade       mostra ou define os limiares
"""
import glob
import os
import sys

from . import carga, config, db, migra, sped


def _fmt(v, casas=2):
    return f"{float(v):,.{casas}f}".replace(",", "@").replace(".", ",").replace("@", ".")


def cmd_config(_):
    print("\nConfiguração\n" + "-" * 60)
    for k, v in config.resumo().items():
        print(f"  {k:<14} {v}")
    if not config.DATABASE_URL:
        print("\n  Para ativar o backend rápido, adicione ao .env:")
        print("    DATABASE_URL=postgresql://postgres.ccquyncwgtszhicicvye:"
              "SUA_SENHA@aws-1-sa-east-1.pooler.supabase.com:6543/postgres")
        print("  A senha está em Supabase → Database → Connection string.")
    return 0


def cmd_migrar(_):
    print("\nMigrações\n" + "-" * 60)
    for m in migra.estado():
        marca = {"aplicada": "  ok    ", "pendente": "  ...   ", "ALTERADA": "  ALVO! "}
        print(f"{marca[m['situacao']]}{m['arquivo']:<28} {m['situacao']}")
    print()
    migra.aplica()
    return 0


def cmd_status(_):
    con = db.conecta()
    print(f"\nBanco  ({con.nome})\n" + "-" * 88)
    arqs = con.consulta("""
        select a.id, a.nome_arquivo, a.cnpj, a.uf, a.dt_ini, a.dt_fin, a.cod_fin,
               a.ind_perfil, a.vigente, a.substituido_por, a.linhas_lidas,
               left(coalesce(a.sha256,''), 12) as sha, a.importado_por, a.importado_em,
               (select count(*) from importacao_problema p where p.arquivo_id = a.id) as probs
        from sped_arquivo a order by a.cnpj, a.dt_ini, a.id""")
    if not arqs:
        print("  Nenhum arquivo importado.")
    for a in arqs:
        v = "vigente" if a["vigente"] else f"substituído por #{a['substituido_por']}"
        fin = {"0": "original", "1": "substituto"}.get(a["cod_fin"], a["cod_fin"])
        print(f"  #{a['id']} {a['cnpj']} {a['uf']}  {a['dt_ini']}..{a['dt_fin']}  "
              f"perfil {a['ind_perfil']}  {fin}  {v}")
        print(f"       sha {a['sha']}…  {a['linhas_lidas']} linhas  "
              f"{a['probs']} problemas  por {a['importado_por']}")
        print(f"       {a['nome_arquivo'][:74]}")

    inv = con.consulta("select * from v_inventario_conferencia order by uf")
    if inv:
        print("\nInventário\n" + "-" * 88)
        for r in inv:
            ok = "confere" if abs(float(r["diferenca"])) < 0.005 else "DIVERGENTE"
            print(f"  {r['uf']} {r['cnpj']} {r['dt_inv']}  {r['qtd_itens']:>4} itens  "
                  f"R$ {_fmt(r['vl_somado_h010']):>16}  {ok}")
        t = con.consulta("select count(*) n, coalesce(sum(vl_item),0) v "
                         "from inventario_item")[0]
        print(f"  TOTAL {t['n']} itens  R$ {_fmt(t['v'])}")
    return 0


def _expande(padroes):
    out = []
    for p in padroes:
        achados = glob.glob(p)
        if not achados:
            print(f"  aviso: nada encontrado para {p}")
        out.extend(sorted(achados))
    return out


def cmd_importar(args):
    caminhos = _expande(args)
    if not caminhos:
        print("  Nada a importar.")
        return 1
    print(f"\nImportando {len(caminhos)} arquivo(s)\n" + "-" * 72)
    for c in caminhos:
        r = carga.importa(c)
        rot = {"importado": "importado ", "ja_importado": "já estava ",
               "substituiu": "SUBSTITUIU"}[r.situacao]
        print(f"  {rot} #{r.arquivo_id}  {r.arquivo[:56]}")
        if r.contagens:
            print("             " + "  ".join(f"{k} {v}" for k, v in r.contagens.items()))
        for tipo, det in r.problemas:
            print(f"             ! {tipo}: {det[:96]}")
    return 0


def cmd_conferir(args):
    caminhos = _expande(args)
    print(f"\nConferência de {len(caminhos)} arquivo(s) — nada será gravado\n" + "-" * 72)
    houve = False
    for c in caminhos:
        efd = sped.parse(c)
        probs = sped.confere(efd)
        soma = sum(i["vl_item"] for i in efd.inventario_itens)
        print(f"\n  {efd.nome_arquivo[:66]}")
        print(f"    {efd.cnpj} {efd.uf}  {efd.dt_ini}..{efd.dt_fin}  "
              f"perfil {efd.ind_perfil}  sha {efd.sha256[:12]}…")
        print(f"    {efd.linhas_lidas} linhas · {len(efd.itens)} itens no 0200 · "
              f"{len(efd.inventario_itens)} no inventário · R$ {_fmt(soma)}")
        com, tot = efd.detalha_itens
        print(f"    detalhe por item: {com}/{tot} documentos")
        if probs:
            houve = True
            for tipo, det in probs:
                print(f"    ! {tipo}: {det[:100]}")
        else:
            print("    sem problemas")
    return 1 if houve else 0


def cmd_congelar(args):
    """Congela o inventário de uma data como saldo de abertura do Kardex."""
    import getpass
    data_base = args[0] if args else "2022-12-31"
    con = db.conecta()
    quem = os.environ.get("AUDITOR") or getpass.getuser()

    ja = con.consulta("select count(*) n, coalesce(sum(vl_item),0) v "
                      "from saldo_abertura where data_base = %s", (data_base,))[0]
    if ja["n"]:
        print(f"\n  Momento zero de {data_base} já congelado: "
              f"{ja['n']} itens, R$ {_fmt(ja['v'])}")
        print("  Saldo de abertura é imutável. Nada foi alterado.")
        return 0

    con.executa("""
        insert into saldo_abertura
          (cnpj, data_base, cod_item, descr_item, unid, qtd, vl_unit, vl_item,
           ind_prop, cod_part, origem_item, congelado_por)
        select ii.cnpj, ii.dt_inv, ii.cod_item, si.descr_item, ii.unid, ii.qtd,
               ii.vl_unit, ii.vl_item, ii.ind_prop, ii.cod_part, ii.id, %s
        from inventario_item ii
        join inventario i on i.id = ii.inventario_id
        join sped_arquivo a on a.id = i.arquivo_id and a.vigente
        left join sped_item si on si.arquivo_id = a.id and si.cod_item = ii.cod_item
        where ii.dt_inv = %s
        on conflict do nothing""", (quem, data_base))

    con.executa("""
        insert into movimento
          (cnpj, dt, cod_item, origem, efeito, qtd, vl_unit, vl_total, ind_prop, observacao)
        select cnpj, data_base, cod_item, 'abertura', 'soma', qtd, vl_unit, vl_item,
               coalesce(ind_prop,'0'), 'Saldo de abertura congelado (momento zero)'
        from saldo_abertura where data_base = %s""", (data_base,))

    r = con.consulta("select count(*) n, coalesce(sum(vl_item),0) v, coalesce(sum(qtd),0) q "
                     "from saldo_abertura where data_base = %s", (data_base,))[0]
    print(f"\n  Momento zero congelado em {data_base}")
    print(f"  {r['n']} itens · {_fmt(r['q'], 0)} unidades · R$ {_fmt(r['v'])}")
    for x in con.consulta("select cnpj, count(*) n, sum(vl_item) v from saldo_abertura "
                          "where data_base = %s group by cnpj order by 3 desc", (data_base,)):
        print(f"    {x['cnpj']}  {x['n']:>4} itens  R$ {_fmt(x['v']):>16}")
    return 0


def cmd_ressalvas(_):
    con = db.conecta()
    rs = con.consulta("select * from auditoria_ressalva order by valor desc nulls last")
    print("\nRessalvas registradas\n" + "-" * 78)
    if not rs:
        print("  Nenhuma.")
    for r in rs:
        v = f"R$ {_fmt(r['valor'])}" if r["valor"] is not None else "—"
        print(f"  [{r['escopo']}] {r['tipo']}  {v}"
              + (f"  ({r['qtd_itens']} itens)" if r["qtd_itens"] else ""))
        print(f"     {r['descricao']}")
        print(f"     decidido por {r['decidido_por']} em {r['decidido_em']}")
    return 0


def cmd_varrer(args):
    """Executa as regras e concilia com os achados já registrados."""
    import getpass
    data = args[0] if args else "2022-12-31"
    quem = os.environ.get("AUDITOR") or getpass.getuser()
    con = db.conecta()
    m = con.consulta("select * from materialidade_vigente()")
    if not m:
        print("\n  ERRO: nenhuma materialidade definida.")
        return 1
    m = m[0]
    print(f"\nVarredura em {data}\n" + "-" * 66)
    print(f"  materialidade  planejamento R$ {_fmt(m['planejamento'])} · "
          f"execução R$ {_fmt(m['execucao'])} · trivial R$ {_fmt(m['trivial'])}")
    r = con.consulta("select * from varrer(%s::date, %s)", (data, quem))[0]
    print(f"  novos {r['novos']} · mantidos {r['mantidos']} · "
          f"resolvidos {r['resolvidos']} · em aberto {r['total_aberto']}\n")
    for x in con.consulta("select severidade, status, count(*) n from achado "
                          "where status <> 'resolvido' group by 1,2 order by 1,2"):
        print(f"    {x['severidade']:<13}{x['status']:<13}{x['n']:>4}")
    return 0


def cmd_achados(args):
    con = db.conecta()
    filtro = args[0] if args else ""
    w = "1=1" if filtro == "todos" else "status <> 'resolvido'"
    if filtro in ("critico", "alto", "medio", "informativo"):
        w = f"status <> 'resolvido' and severidade = '{filtro}'"
    print("\nAchados\n" + "-" * 96)
    for a in con.consulta(f"""select id, severidade, status, uf, cod_item,
                              left(coalesce(descr_item,''),34) d, valor
                              from v_achado_painel where {w}
                              order by ordem_sev, valor desc nulls last limit 60"""):
        v = f"R$ {_fmt(a['valor'])}" if a["valor"] is not None else "—"
        print(f"  #{a['id']:<4}{a['severidade']:<11}{a['status']:<12}"
              f"{(a['uf'] or '--'):<4}{(a['cod_item'] or ''):<12}{a['d']:<36}{v:>16}")
    r = con.consulta("select * from v_achado_resumo")[0]
    print(f"\n  aberto {r['aberto']} · em análise {r['em_analise']} · respondido "
          f"{r['respondido']} · aceito {r['aceito']} · refutado {r['refutado']} "
          f"· resolvido {r['resolvido']}")
    if r["atrasados"]:
        print(f"  ATENÇÃO: {r['atrasados']} achado(s) com prazo vencido")
    return 0


def cmd_materialidade(args):
    """Sem argumento mostra a vigente; com três números, registra uma nova."""
    import getpass
    con = db.conecta()
    if not args:
        m = con.consulta("select * from materialidade_vigente()")[0]
        print("\nMaterialidade vigente\n" + "-" * 66)
        print(f"  planejamento .......... R$ {_fmt(m['planejamento'])}")
        print(f"  execução .............. R$ {_fmt(m['execucao'])}")
        print(f"  claramente trivial .... R$ {_fmt(m['trivial'])}")
        print(f"\n  divergência de valoração a partir de {m['mult_valoracao']}x")
        print(f"  dispersão entre filiais a partir de {m['mult_dispersao']}x")
        print(f"  margem negativa a partir de {m['pct_margem_negativa']}%")
        print(f"  sem giro a partir de {m['meses_sem_giro']} meses")
        print(f"\n  definida por {m['definido_por']} em {m['definido_em']}")
        if m["observacao"]:
            print(f"  {m['observacao']}")
        print("\n  Para alterar:")
        print("    python -m auditoria materialidade <planejamento> <execução> <trivial>")
        return 0
    if len(args) < 3:
        print("  Informe os três valores: planejamento, execução e trivial.")
        return 1
    vals = [float(a.replace(".", "").replace(",", ".")) for a in args[:3]]
    quem = os.environ.get("AUDITOR") or getpass.getuser()
    con.executa("insert into materialidade (escopo, planejamento, execucao, trivial,"
                " definido_por, observacao) values ('padrao', %s, %s, %s, %s, %s)",
                (vals[0], vals[1], vals[2], quem, "Definida pelo auditor"))
    print(f"\n  Registrada: planejamento R$ {_fmt(vals[0])} · "
          f"execução R$ {_fmt(vals[1])} · trivial R$ {_fmt(vals[2])}")
    print("  Rode 'varrer' de novo para reavaliar os achados com os novos limiares.")
    return 0


COMANDOS = {"varrer": cmd_varrer, "achados": cmd_achados,
            "materialidade": cmd_materialidade,
            "config": cmd_config, "migrar": cmd_migrar, "status": cmd_status,
            "importar": cmd_importar, "conferir": cmd_conferir,
            "congelar": cmd_congelar, "ressalvas": cmd_ressalvas}


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "ajuda"):
        print(__doc__)
        return 0
    cmd = COMANDOS.get(argv[0])
    if not cmd:
        print(f"Comando desconhecido: {argv[0]}")
        print(__doc__)
        return 2
    try:
        return cmd(argv[1:])
    except (db.ErroBanco, RuntimeError, ValueError) as e:
        print(f"\nERRO: {e}\n")
        return 1
