-- 053 — O extrato de estoque do ERP, e o confronto com o que apuramos.
--
-- Ate aqui o sistema so conhecia a versao fiscal da historia: XML, EFD, ECD.
-- O extrato de produtos do ERP e a versao do cliente — o mesmo estoque, pelo
-- sistema que emitiu as notas. Auditar e comparar as duas.
--
-- O extrato NAO vira movimento. Ele e guardado como declaracao de terceiro,
-- ao lado da nossa apuracao, nunca dentro dela: se o numero do ERP entrasse no
-- Kardex, a conferencia estaria comparando o ERP com ele mesmo.
--
-- Tres confrontos, do mais grosso ao mais fino:
--   item      — saldo inicial, entradas, saidas, saldo final e custo medio
--   documento — nota a nota: o que o ERP movimentou e nos nao, e o contrario
--   interno   — o que o proprio extrato mostra sem precisar de nos (movimento
--               sem documento fiscal, quantidade absurda, custo que desaba)

create table if not exists erp_extrato_arquivo_todos (
  id            bigserial primary key,
  trabalho_id   bigint not null default trabalho_atual()
                references trabalho(id) on delete cascade,
  nome_arquivo  text not null,
  sha256        text not null,
  deposito      text,
  cnpj          text,
  uf            text,
  dt_ini        date,
  dt_fin        date,
  linhas        int,
  itens         int,
  movimentos    int,
  aberturas     int,
  vigente       boolean not null default true,
  problemas     jsonb,
  importado_por text,
  importado_em  timestamptz not null default now()
);
create unique index if not exists ux_erp_arq_sha
  on erp_extrato_arquivo_todos (trabalho_id, sha256);
comment on table erp_extrato_arquivo_todos is
  'Extrato de produtos do ERP. Declaracao do cliente, guardada ao lado da '
  'apuracao pelos XML — nunca dentro dela.';
create or replace view erp_extrato_arquivo as
  select * from erp_extrato_arquivo_todos where trabalho_id = trabalho_atual();

create table if not exists erp_extrato_linha_todos (
  id          bigserial primary key,
  trabalho_id bigint not null default trabalho_atual()
              references trabalho(id) on delete cascade,
  arquivo_id  bigint not null references erp_extrato_arquivo_todos(id) on delete cascade,
  seq         int,
  abertura    boolean not null default false,
  cod_item    text not null,
  descr_item  text,
  unid        text,
  deposito    text,
  cnpj        text,
  dt          date,
  hora        text,
  ch_mov      text,
  ch_doc      text,
  doc_modelo  text,
  doc_serie   text,
  doc_num     text,
  doc_texto   text,
  tipo        text,
  entidade    text,
  qtd_entrada   numeric(18,3),
  qtd_saida     numeric(18,3),
  qtd_saldo     numeric(18,3),
  custo_entrada numeric(18,6),
  custo_saida   numeric(18,6),
  custo_saldo   numeric(18,6),
  custo_medio   numeric(18,6)
);
create index if not exists ix_erp_linha on erp_extrato_linha_todos (arquivo_id, cod_item, seq);
create index if not exists ix_erp_linha_doc on erp_extrato_linha_todos (arquivo_id, doc_num);
comment on column erp_extrato_linha_todos.abertura is
  'Linha sem chave de movimento: saldo do item no inicio do periodo.';
create or replace view erp_extrato_linha as
  select * from erp_extrato_linha_todos where trabalho_id = trabalho_atual();

-- Deposito -> filial. O nome do deposito termina na UF ("DEP MCI SP"), mas
-- isso e costume do cliente, nao regra: a tabela permite corrigir sem mexer
-- em codigo, e a funcao so adivinha quando ninguem disse o contrario.
create table if not exists erp_deposito_todos (
  id          bigserial primary key,
  trabalho_id bigint not null default trabalho_atual()
              references trabalho(id) on delete cascade,
  deposito    text not null,
  cnpj        text not null,
  criado_em   timestamptz not null default now()
);
create unique index if not exists ux_erp_deposito
  on erp_deposito_todos (trabalho_id, deposito);
create or replace view erp_deposito as
  select * from erp_deposito_todos where trabalho_id = trabalho_atual();

create or replace function erp_cnpj_do_deposito(p_deposito text)
returns text language sql stable as $$
  select coalesce(
    (select d.cnpj from erp_deposito d where d.deposito = p_deposito),
    (select e.cnpj from estabelecimento e
      where e.uf = upper(right(trim(p_deposito), 2)) limit 1));
$$;
comment on function erp_cnpj_do_deposito(text) is
  'Filial de um deposito do ERP: pelo que foi cadastrado ou, na falta, pela '
  'UF no fim do nome.';


create or replace function importar_erp_extrato(p jsonb)
returns jsonb language plpgsql as $$
declare
  a jsonb := p->'arquivo';
  v_ja bigint; v_id bigint; v_ant int; v_cnpj text; v_dep text;
begin
  select id into v_ja from erp_extrato_arquivo where sha256 = a->>'sha256';
  if v_ja is not null then
    return jsonb_build_object('situacao', 'ja_importado', 'arquivo_id', v_ja);
  end if;

  v_dep := a->>'deposito';
  v_cnpj := erp_cnpj_do_deposito(v_dep);

  -- Extrato novo do mesmo deposito e periodo substitui o anterior, que fica
  -- guardado: o cliente reemite o relatorio depois de corrigir lancamento.
  update erp_extrato_arquivo set vigente = false
   where coalesce(deposito,'') = coalesce(v_dep,'')
     and dt_ini = (a->>'dt_ini')::date and dt_fin = (a->>'dt_fin')::date and vigente;
  get diagnostics v_ant = row_count;

  insert into erp_extrato_arquivo (
    nome_arquivo, sha256, deposito, cnpj,
    uf, dt_ini, dt_fin, linhas, itens, movimentos, aberturas, problemas, importado_por)
  values (
    a->>'nome_arquivo', a->>'sha256', v_dep, v_cnpj,
    (select uf from estabelecimento where cnpj = v_cnpj),
    (a->>'dt_ini')::date, (a->>'dt_fin')::date, (a->>'linhas')::int,
    (a->>'itens')::int, (a->>'movimentos')::int, (a->>'aberturas')::int,
    a->'problemas', a->>'importado_por')
  returning id into v_id;

  insert into erp_extrato_linha (
    arquivo_id, seq, abertura, cod_item, descr_item, unid, deposito, cnpj, dt, hora,
    ch_mov, ch_doc, doc_modelo, doc_serie, doc_num, doc_texto, tipo, entidade,
    qtd_entrada, qtd_saida, qtd_saldo, custo_entrada, custo_saida, custo_saldo, custo_medio)
  select v_id, (x->>'seq')::int, (x->>'abertura')::boolean,
         x->>'cod_item', nullif(x->>'descr_item',''), nullif(x->>'unid',''),
         coalesce(nullif(x->>'deposito',''), v_dep),
         erp_cnpj_do_deposito(coalesce(nullif(x->>'deposito',''), v_dep)),
         (x->>'dt')::date, x->>'hora', x->>'ch_mov', x->>'ch_doc',
         x->>'doc_modelo', x->>'doc_serie', x->>'doc_num', x->>'doc_texto',
         x->>'tipo', x->>'entidade',
         (x->>'qtd_entrada')::numeric, (x->>'qtd_saida')::numeric, (x->>'qtd_saldo')::numeric,
         (x->>'custo_entrada')::numeric, (x->>'custo_saida')::numeric,
         (x->>'custo_saldo')::numeric, (x->>'custo_medio')::numeric
    from jsonb_array_elements(coalesce(p->'linhas','[]')) x;

  return jsonb_build_object(
    'situacao', case when v_ant > 0 then 'substituiu' else 'importado' end,
    'arquivo_id', v_id, 'cnpj', v_cnpj, 'deposito', v_dep,
    'linhas', (select count(*) from erp_extrato_linha where arquivo_id = v_id));
end $$;
comment on function importar_erp_extrato(jsonb) is
  'Grava um extrato do ERP numa chamada. Reimportar o mesmo arquivo nao faz '
  'nada; extrato novo do mesmo deposito e periodo substitui o anterior.';


-- ------------------------------------------------------------------ item
create or replace function erp_confronto_item(p_arquivo_id bigint)
returns table (
  cod_item text, descr_item text, unid text, cnpj text,
  erp_inicial numeric, erp_entradas numeric, erp_saidas numeric,
  erp_final numeric, erp_custo_medio numeric, erp_valor numeric,
  nosso_inicial numeric, nossas_entradas numeric, nossas_saidas numeric,
  nosso_final numeric, nosso_custo_medio numeric, nosso_valor numeric,
  dif_inicial numeric, dif_final numeric, dif_valor numeric, situacao text
)
language plpgsql stable as $$
declare a record;
begin
  select * into a from erp_extrato_arquivo where id = p_arquivo_id;
  if a.id is null then return; end if;

  return query
  with erp as (
    select l.cod_item,
           max(l.descr_item) filter (where l.descr_item is not null) descr_item,
           max(l.unid) unid, max(l.cnpj) cnpj,
           coalesce(sum(l.qtd_saldo) filter (where l.abertura), 0) inicial,
           coalesce(sum(l.qtd_entrada) filter (where not l.abertura), 0) entradas,
           coalesce(sum(l.qtd_saida) filter (where not l.abertura), 0) saidas,
           -- O saldo final e o que o ERP imprime na ultima linha do item, e
           -- nao a soma: se os dois discordarem, o problema e do relatorio, e
           -- a funcao confere_extrato o aponta.
           (array_agg(l.qtd_saldo order by l.seq desc))[1] final,
           (array_agg(l.custo_medio order by l.seq desc))[1] custo_medio,
           (array_agg(l.custo_saldo order by l.seq desc))[1] valor
      from erp_extrato_linha l
     where l.arquivo_id = p_arquivo_id
     group by l.cod_item
  ), ini as (
    select e.cod_item, e.qtd from estoque_em(a.dt_ini - 1) e where e.cnpj = a.cnpj
  ), fim as (
    select e.cod_item, e.qtd, e.custo_medio, e.valor
      from estoque_em(a.dt_fin) e where e.cnpj = a.cnpj
  ), per as (
    select m.cod_item,
           coalesce(sum(m.qtd) filter (where m.qtd > 0), 0) entradas,
           coalesce(-sum(m.qtd) filter (where m.qtd < 0), 0) saidas
      from movimento m
     where m.cnpj = a.cnpj and m.dt between a.dt_ini and a.dt_fin
       and coalesce(m.ind_prop,'0') = '0'
     group by m.cod_item
  )
  select coalesce(e.cod_item, f.cod_item, p.cod_item),
         e.descr_item, e.unid, a.cnpj,
         coalesce(e.inicial, 0), coalesce(e.entradas, 0), coalesce(e.saidas, 0),
         coalesce(e.final, 0), e.custo_medio, round(coalesce(e.valor, 0), 2),
         coalesce(i.qtd, 0), coalesce(p.entradas, 0), coalesce(p.saidas, 0),
         coalesce(f.qtd, 0), f.custo_medio, round(coalesce(f.valor, 0), 2),
         coalesce(e.inicial, 0) - coalesce(i.qtd, 0),
         coalesce(e.final, 0) - coalesce(f.qtd, 0),
         round(coalesce(e.valor, 0) - coalesce(f.valor, 0), 2),
         case
           when e.cod_item is null then 'so_nosso'
           when f.cod_item is null and coalesce(f.qtd,0) = 0
                and coalesce(p.entradas,0) = 0 and coalesce(p.saidas,0) = 0
                then 'so_erp'
           when abs(coalesce(e.final,0) - coalesce(f.qtd,0)) > 0.001 then 'saldo_difere'
           when abs(coalesce(e.inicial,0) - coalesce(i.qtd,0)) > 0.001 then 'abertura_difere'
           when abs(coalesce(e.valor,0) - coalesce(f.valor,0)) > 0.01 then 'valor_difere'
           else 'confere'
         end
    from erp e
    full join fim f on f.cod_item = e.cod_item
    full join per p on p.cod_item = coalesce(e.cod_item, f.cod_item)
    left join ini i on i.cod_item = coalesce(e.cod_item, f.cod_item, p.cod_item)
   order by abs(coalesce(e.final,0) - coalesce(f.qtd,0)) desc,
            abs(coalesce(e.valor,0) - coalesce(f.valor,0)) desc;
end $$;
comment on function erp_confronto_item(bigint) is
  'Item a item: saldo inicial, movimentacao, saldo final e custo, pelo ERP e '
  'pela nossa apuracao dos XML.';


-- -------------------------------------------------------------- documento
create or replace function erp_confronto_documento(p_arquivo_id bigint)
returns table (
  origem text, num_nf text, dt date, cod_item text, descr_item text,
  tipo text, contraparte text,
  erp_entrada numeric, erp_saida numeric,
  nossa_entrada numeric, nossa_saida numeric,
  cfop text, diferenca numeric, situacao text
)
language plpgsql stable as $$
declare a record;
begin
  select * into a from erp_extrato_arquivo where id = p_arquivo_id;
  if a.id is null then return; end if;

  return query
  with calc as (
  with erp as (
    select l.doc_num, l.dt, l.cod_item,
           max(l.descr_item) descr_item, max(l.tipo) tipo, max(l.entidade) entidade,
           coalesce(sum(l.qtd_entrada), 0) ent, coalesce(sum(l.qtd_saida), 0) sai
      from erp_extrato_linha l
     where l.arquivo_id = p_arquivo_id and not l.abertura
     group by l.doc_num, l.dt, l.cod_item
  ), nosso as (
    select v.num_nf, m.dt, m.cod_item,
           coalesce(sum(m.qtd) filter (where m.qtd > 0), 0) ent,
           coalesce(-sum(m.qtd) filter (where m.qtd < 0), 0) sai,
           string_agg(distinct m.cfop, ', ') cfop,
           max(case when v.emit_cnpj = a.cnpj then v.dest_nome else v.emit_nome end) parceiro
      from movimento m
      join nfe v on v.id = m.nfe_id
     where m.cnpj = a.cnpj and m.dt between a.dt_ini and a.dt_fin
       and coalesce(m.ind_prop,'0') = '0'
     group by v.num_nf, m.dt, m.cod_item
  )
  select case when e.doc_num is null then 'só na nossa apuração'
              when n.num_nf is null then 'só no ERP'
              else 'nos dois' end origem,
         coalesce(e.doc_num, n.num_nf) num_nf, coalesce(e.dt, n.dt) dt,
         coalesce(e.cod_item, n.cod_item) cod_item, e.descr_item,
         e.tipo, coalesce(e.entidade, n.parceiro) contraparte,
         coalesce(e.ent, 0) erp_entrada, coalesce(e.sai, 0) erp_saida,
         coalesce(n.ent, 0) nossa_entrada, coalesce(n.sai, 0) nossa_saida, n.cfop,
         (coalesce(e.ent,0) - coalesce(e.sai,0))
           - (coalesce(n.ent,0) - coalesce(n.sai,0)) diferenca,
         case
           when e.doc_num is null then 'so_nosso'
           when n.num_nf is null and coalesce(e.doc_num,'') = '' then 'sem_documento'
           when n.num_nf is null then 'so_erp'
           when abs((coalesce(e.ent,0) - coalesce(e.sai,0))
                    - (coalesce(n.ent,0) - coalesce(n.sai,0))) > 0.001 then 'qtd_difere'
           else 'confere'
         end situacao
    from erp e
    full join nosso n
      on n.num_nf = e.doc_num and n.cod_item = e.cod_item and n.dt = e.dt
  )
  -- O que diverge vem primeiro, e o maior primeiro: a tela abre no problema.
  select c.origem, c.num_nf, c.dt, c.cod_item, c.descr_item, c.tipo, c.contraparte,
         c.erp_entrada, c.erp_saida, c.nossa_entrada, c.nossa_saida, c.cfop,
         c.diferenca, c.situacao
    from calc c
   order by (c.situacao <> 'confere') desc, abs(c.diferenca) desc, c.num_nf, c.cod_item;
end $$;
comment on function erp_confronto_documento(bigint) is
  'Nota a nota: o que o ERP movimentou e nos nao, o que nos movimentamos e o '
  'ERP nao, e onde a quantidade difere.';


-- ---------------------------------------------------------------- resumo
create or replace function erp_confronto_resumo(p_arquivo_id bigint)
returns table (
  cnpj text, uf text, deposito text, dt_ini date, dt_fin date,
  itens bigint, confere bigint, saldo_difere bigint, abertura_difere bigint,
  valor_difere bigint, so_erp bigint, so_nosso bigint,
  erp_valor_final numeric, nosso_valor_final numeric, dif_valor numeric,
  docs_so_erp bigint, docs_so_nosso bigint, docs_qtd_difere bigint,
  linhas_sem_documento bigint
)
language sql stable as $$
  select a.cnpj, a.uf, a.deposito, a.dt_ini, a.dt_fin,
         count(i.*)::bigint,
         count(*) filter (where i.situacao = 'confere')::bigint,
         count(*) filter (where i.situacao = 'saldo_difere')::bigint,
         count(*) filter (where i.situacao = 'abertura_difere')::bigint,
         count(*) filter (where i.situacao = 'valor_difere')::bigint,
         count(*) filter (where i.situacao = 'so_erp')::bigint,
         count(*) filter (where i.situacao = 'so_nosso')::bigint,
         round(coalesce(sum(i.erp_valor), 0), 2),
         round(coalesce(sum(i.nosso_valor), 0), 2),
         round(coalesce(sum(i.erp_valor) - sum(i.nosso_valor), 0), 2),
         (select count(*) from erp_confronto_documento(p_arquivo_id) d where d.situacao = 'so_erp'),
         (select count(*) from erp_confronto_documento(p_arquivo_id) d where d.situacao = 'so_nosso'),
         (select count(*) from erp_confronto_documento(p_arquivo_id) d where d.situacao = 'qtd_difere'),
         (select count(*) from erp_extrato_linha l
           where l.arquivo_id = p_arquivo_id and not l.abertura
             and coalesce(l.doc_num, '') = '')
    from erp_extrato_arquivo a
    left join erp_confronto_item(p_arquivo_id) i on true
   where a.id = p_arquivo_id
   group by a.cnpj, a.uf, a.deposito, a.dt_ini, a.dt_fin;
$$;


-- ------------------------------------------- o que o extrato mostra sozinho
create or replace function erp_extrato_alertas(p_arquivo_id bigint)
returns table (
  tipo text, titulo text, cod_item text, descr_item text, dt date,
  doc text, detalhe text, quantidade numeric, valor numeric
)
language sql stable as $$
  -- Movimento sem documento fiscal: o estoque do ERP andou sem nota.
  select 'sem_documento', 'Movimento sem documento fiscal',
         l.cod_item, l.descr_item, l.dt, coalesce(l.ch_mov, '—'),
         coalesce(l.tipo, '') || coalesce(' · ' || l.entidade, ''),
         coalesce(l.qtd_entrada, 0) - coalesce(l.qtd_saida, 0),
         round(coalesce(l.custo_entrada, 0) - coalesce(l.custo_saida, 0), 2)
    from erp_extrato_linha l
   where l.arquivo_id = p_arquivo_id and not l.abertura
     and coalesce(l.doc_num, '') = ''

  union all
  -- Custo medio que desaba ou dispara de um movimento para o outro. O custo
  -- medio so muda por entrada; variar mais de 50% e sinal de lancamento com
  -- quantidade ou valor errado — e e o custo que vai para o CMV.
  select 'custo_pula', 'Custo médio saltou de um movimento para o outro',
         l.cod_item, l.descr_item, l.dt, coalesce(l.doc_texto, l.ch_mov, '—'),
         'de ' || to_char(ant.custo_medio, 'FM999G999G990D00') ||
         ' para ' || to_char(l.custo_medio, 'FM999G999G990D00'),
         coalesce(l.qtd_entrada, 0) - coalesce(l.qtd_saida, 0),
         round(l.custo_medio - ant.custo_medio, 2)
    from erp_extrato_linha l
    join lateral (
      select p.custo_medio, p.qtd_saldo from erp_extrato_linha p
       where p.arquivo_id = l.arquivo_id and p.cod_item = l.cod_item and p.seq < l.seq
       order by p.seq desc limit 1) ant on true
   where l.arquivo_id = p_arquivo_id
     and ant.custo_medio > 0 and l.custo_medio is not null
     and abs(l.custo_medio - ant.custo_medio) > 0.5 * ant.custo_medio

  union all
  -- Quantidade fora de escala: cem vezes o saldo que o item tinha na linha
  -- anterior. Comparar com o saldo de antes, e nao com o maior do periodo,
  -- importa — o maior do periodo costuma ser o proprio lancamento errado.
  select 'quantidade_fora_de_escala', 'Quantidade desproporcional ao item',
         l.cod_item, l.descr_item, l.dt, coalesce(l.doc_texto, l.ch_mov, '—'),
         'saldo antes: ' || to_char(coalesce(ant.qtd_saldo, 0), 'FM999G999G990D000')
           || coalesce(' · ' || l.tipo, ''),
         coalesce(l.qtd_entrada, 0) - coalesce(l.qtd_saida, 0),
         round(coalesce(l.custo_entrada, 0) - coalesce(l.custo_saida, 0), 2)
    from erp_extrato_linha l
    join lateral (
      select p.qtd_saldo from erp_extrato_linha p
       where p.arquivo_id = l.arquivo_id and p.cod_item = l.cod_item and p.seq < l.seq
       order by p.seq desc limit 1) ant on true
   where l.arquivo_id = p_arquivo_id and not l.abertura
     and greatest(coalesce(l.qtd_entrada, 0), coalesce(l.qtd_saida, 0))
         > greatest(abs(coalesce(ant.qtd_saldo, 0)), 1) * 100

  union all
  -- Quantidade quebrada em item contado por unidade. 2.015,02 unidades de um
  -- equipamento nao existe: e numero digitado no campo errado.
  select 'quantidade_fracionada', 'Quantidade fracionada em item contado por unidade',
         l.cod_item, l.descr_item, l.dt, coalesce(l.doc_texto, l.ch_mov, '—'),
         coalesce(l.tipo, '') || ' · unidade ' || coalesce(l.unid, '?'),
         coalesce(l.qtd_entrada, 0) - coalesce(l.qtd_saida, 0),
         round(coalesce(l.custo_entrada, 0) - coalesce(l.custo_saida, 0), 2)
    from erp_extrato_linha l
   where l.arquivo_id = p_arquivo_id
     and upper(coalesce(l.unid, '')) in ('UN', 'UND', 'UNID', 'PC', 'PÇ', 'PEC')
     and (coalesce(l.qtd_entrada, 0) <> trunc(coalesce(l.qtd_entrada, 0))
          or coalesce(l.qtd_saida, 0) <> trunc(coalesce(l.qtd_saida, 0)))

  order by 5, 3;
$$;
comment on function erp_extrato_alertas(bigint) is
  'O que o proprio extrato denuncia sem precisar da nossa apuracao: movimento '
  'sem nota, custo medio que pula, quantidade fora de escala.';
