-- 057 — Saldo de produtos do ERP: a posicao declarada numa data.
--
-- O extrato (053) e o Kardex: movimento a movimento. Este aqui e a FOTO: o
-- saldo de cada produto num deposito, numa data. Nao tem movimento, nao tem
-- documento, nao tem custo — so quantidade.
--
-- Por isso ele nao vira Kardex nem abertura. Entra como posicao declarada, ao
-- lado da nossa apuracao, para ser confrontado com ela NA MESMA DATA. Virar
-- abertura seria outra coisa: mudaria a base de tudo o que ja foi apurado
-- naquela filial, e isso e decisao do auditor, nao efeito colateral de uma
-- importacao.
--
-- O confronto responde uma pergunta so, e e a pergunta que importa: o que o
-- ERP diz que tem, o que nos conseguimos explicar pelos documentos, e a
-- diferenca item a item.

create table if not exists erp_saldo_arquivo_todos (
  id            bigserial primary key,
  trabalho_id   bigint not null default trabalho_atual()
                references trabalho(id) on delete cascade,
  nome_arquivo  text not null,
  sha256        text not null,
  deposito      text,
  cnpj          text,
  uf            text,
  dt            date not null,
  linhas        int,
  itens         int,
  quantidade    numeric(18,3),
  vigente       boolean not null default true,
  problemas     jsonb,
  importado_por text,
  importado_em  timestamptz not null default now()
);
create unique index if not exists ux_erp_saldo_sha
  on erp_saldo_arquivo_todos (trabalho_id, sha256);
comment on table erp_saldo_arquivo_todos is
  'Foto do saldo do ERP numa data. Declaracao do cliente, guardada ao lado da '
  'apuracao pelos documentos — nunca dentro dela.';
create or replace view erp_saldo_arquivo as
  select * from erp_saldo_arquivo_todos where trabalho_id = trabalho_atual();

create table if not exists erp_saldo_linha_todos (
  id          bigserial primary key,
  trabalho_id bigint not null default trabalho_atual()
              references trabalho(id) on delete cascade,
  arquivo_id  bigint not null references erp_saldo_arquivo_todos(id) on delete cascade,
  seq         int,
  cod_item    text not null,
  descr_item  text,
  unid        text,
  ncm         text,
  fabricante  text,
  deposito    text,
  local_escrituracao text,
  cnpj        text,
  qtd         numeric(18,3) not null
);
create index if not exists ix_erp_saldo_linha
  on erp_saldo_linha_todos (arquivo_id, cod_item);
comment on table erp_saldo_linha_todos is
  'Uma linha por produto do relatorio. O mesmo codigo pode vir em mais de uma '
  'linha (cadastro ou lote); o saldo do item e a soma, e o aviso fica no '
  'arquivo.';
create or replace view erp_saldo_linha as
  select * from erp_saldo_linha_todos where trabalho_id = trabalho_atual();


create or replace function importar_erp_saldo(p jsonb)
returns jsonb language plpgsql as $$
declare
  a jsonb := p->'arquivo';
  v_ja bigint; v_id bigint; v_ant int; v_cnpj text; v_dep text; v_dt date;
begin
  select id into v_ja from erp_saldo_arquivo where sha256 = a->>'sha256';
  if v_ja is not null then
    return jsonb_build_object('situacao', 'ja_importado', 'arquivo_id', v_ja);
  end if;

  v_dep := a->>'deposito';
  v_dt := (a->>'dt')::date;
  v_cnpj := erp_cnpj_do_deposito(v_dep);

  -- Foto nova do mesmo deposito na mesma data substitui a anterior, que fica.
  update erp_saldo_arquivo set vigente = false
   where coalesce(deposito,'') = coalesce(v_dep,'') and dt = v_dt and vigente;
  get diagnostics v_ant = row_count;

  insert into erp_saldo_arquivo (nome_arquivo, sha256, deposito, cnpj, uf, dt,
                                 linhas, itens, quantidade, problemas, importado_por)
  values (a->>'nome_arquivo', a->>'sha256', v_dep, v_cnpj,
          (select uf from estabelecimento where cnpj = v_cnpj), v_dt,
          (a->>'linhas')::int, (a->>'itens')::int, (a->>'quantidade')::numeric,
          a->'problemas', a->>'importado_por')
  returning id into v_id;

  insert into erp_saldo_linha (arquivo_id, seq, cod_item, descr_item, unid, ncm,
                               fabricante, deposito, local_escrituracao, cnpj, qtd)
  select v_id, (x->>'seq')::int, x->>'cod_item', nullif(x->>'descr_item',''),
         nullif(x->>'unid',''), nullif(x->>'ncm',''), nullif(x->>'fabricante',''),
         coalesce(nullif(x->>'deposito',''), v_dep),
         nullif(x->>'local',''),
         erp_cnpj_do_deposito(coalesce(nullif(x->>'deposito',''), v_dep)),
         (x->>'qtd')::numeric
    from jsonb_array_elements(coalesce(p->'linhas','[]')) x;

  return jsonb_build_object(
    'situacao', case when v_ant > 0 then 'substituiu' else 'importado' end,
    'arquivo_id', v_id, 'cnpj', v_cnpj, 'deposito', v_dep, 'dt', v_dt,
    'linhas', (select count(*) from erp_saldo_linha where arquivo_id = v_id),
    'com_ncm', (select count(*) from erp_saldo_linha
                 where arquivo_id = v_id and ncm is not null));
end $$;
comment on function importar_erp_saldo(jsonb) is
  'Grava a foto do saldo do ERP numa chamada. Reimportar o mesmo arquivo nao '
  'faz nada; foto nova do mesmo deposito e data substitui a anterior.';


create or replace function erp_saldo_confronto(p_arquivo_id bigint)
returns table (
  cod_item text, descr_item text, unid text, ncm text, ncm_origem text,
  erp_qtd numeric, nossa_qtd numeric, diferenca numeric,
  nosso_custo_medio numeric, nosso_valor numeric, exposicao numeric,
  linhas_no_arquivo bigint, ultima_mov date, situacao text
)
language plpgsql stable as $$
declare a record;
begin
  select * into a from erp_saldo_arquivo where id = p_arquivo_id;
  if a.id is null then return; end if;

  return query
  with erp as (
    select l.cod_item,
           -- Mesmo codigo em varias linhas: a descricao mais longa costuma ser
           -- a completa; o ERP trunca a outra.
           (array_agg(l.descr_item order by length(coalesce(l.descr_item,'')) desc))[1] descr,
           max(l.unid) unid,
           max(l.ncm) ncm,
           sum(l.qtd) qtd,
           count(*)::bigint linhas
      from erp_saldo_linha l
     where l.arquivo_id = p_arquivo_id
     group by l.cod_item
  ), nosso as (
    select e.cod_item, e.qtd, e.custo_medio, e.valor, e.ultima_mov
      from estoque_em(a.dt) e where e.cnpj = a.cnpj
  )
  select coalesce(e.cod_item, n.cod_item),
         coalesce(e.descr, (select s.descr_item from sped_item s
                             where s.cnpj_estab = a.cnpj
                               and s.cod_item = n.cod_item limit 1)),
         e.unid, nc.ncm, nc.origem,
         coalesce(e.qtd, 0), coalesce(n.qtd, 0),
         coalesce(e.qtd, 0) - coalesce(n.qtd, 0),
         n.custo_medio, round(coalesce(n.valor, 0), 2),
         -- Quanto vale a diferenca, pelo nosso custo. Sem custo conhecido nao
         -- se finge um: fica nulo, e a tela mostra que nao da para medir.
         round((coalesce(e.qtd, 0) - coalesce(n.qtd, 0)) * n.custo_medio, 2),
         coalesce(e.linhas, 0), n.ultima_mov,
         case
           when n.cod_item is null then 'so_erp'
           when e.cod_item is null then 'so_nosso'
           when abs(coalesce(e.qtd,0) - coalesce(n.qtd,0)) < 0.001 then 'confere'
           when coalesce(e.qtd,0) > coalesce(n.qtd,0) then 'erp_maior'
           else 'erp_menor'
         end
    from erp e
    full join nosso n on n.cod_item = e.cod_item
    left join lateral erp_ncm_do_item(a.cnpj, coalesce(e.cod_item, n.cod_item), e.ncm) nc
      on true
   order by abs(coalesce(
              (coalesce(e.qtd,0) - coalesce(n.qtd,0)) * n.custo_medio, 0)) desc,
            abs(coalesce(e.qtd,0) - coalesce(n.qtd,0)) desc;
end $$;
comment on function erp_saldo_confronto(bigint) is
  'A foto do ERP contra a nossa posicao na mesma data, item a item.';


create or replace function erp_saldo_resumo(p_arquivo_id bigint)
returns table (
  cnpj text, uf text, deposito text, dt date,
  itens bigint, confere bigint, erp_maior bigint, erp_menor bigint,
  so_erp bigint, so_nosso bigint,
  erp_qtd numeric, nossa_qtd numeric, dif_qtd numeric,
  nosso_valor numeric, exposicao numeric, sem_custo bigint,
  itens_sem_ncm bigint, nossos_movimentos bigint, ultima_mov date
)
language sql stable as $$
  select a.cnpj, a.uf, a.deposito, a.dt,
         count(c.*)::bigint,
         count(*) filter (where c.situacao = 'confere')::bigint,
         count(*) filter (where c.situacao = 'erp_maior')::bigint,
         count(*) filter (where c.situacao = 'erp_menor')::bigint,
         count(*) filter (where c.situacao = 'so_erp')::bigint,
         count(*) filter (where c.situacao = 'so_nosso')::bigint,
         round(coalesce(sum(c.erp_qtd), 0), 3),
         round(coalesce(sum(c.nossa_qtd), 0), 3),
         round(coalesce(sum(c.diferenca), 0), 3),
         round(coalesce(sum(c.nosso_valor), 0), 2),
         round(coalesce(sum(c.exposicao), 0), 2),
         -- Itens cuja diferenca nao da para valorar: sem custo nosso, o furo
         -- existe em quantidade e some em valor. O total de exposicao acima
         -- esta incompleto por causa deles, e a tela tem de dizer isso.
         count(*) filter (where c.situacao <> 'confere'
                            and c.nosso_custo_medio is null)::bigint,
         count(*) filter (where c.ncm is null)::bigint,
         (select count(*) from movimento m
           where m.cnpj = a.cnpj and m.dt <= a.dt),
         (select max(m.dt) from movimento m
           where m.cnpj = a.cnpj and m.dt <= a.dt)
    from erp_saldo_arquivo a
    left join erp_saldo_confronto(p_arquivo_id) c on true
   where a.id = p_arquivo_id
   group by a.cnpj, a.uf, a.deposito, a.dt;
$$;
