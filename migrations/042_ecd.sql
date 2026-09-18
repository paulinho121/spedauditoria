-- 042 — Contabilidade: a ECD e o resultado do periodo.
--
-- As notas dao receita, imposto e custo de mercadoria. Lucro ou prejuizo
-- depende do resto — folha, aluguel, frete, juros —, que esta na contabilidade.
-- A ECD traz o balancete de cada mes (I155) e o plano de contas (I050).
--
-- Resultado do mes = soma, nas contas ANALITICAS de RESULTADO (natureza 04),
-- de creditos menos debitos — tirando as partidas de ENCERRAMENTO. No
-- fechamento as contas de resultado sao zeradas contra o patrimonio liquido;
-- sem descontar essas partidas, o mes de fechamento mostraria resultado zero.
-- Positivo e lucro, negativo e prejuizo.
--
-- A ECD e da EMPRESA (matriz), nao da filial.

create table if not exists ecd_arquivo_todos (
  id            bigserial primary key,
  trabalho_id   bigint not null default trabalho_atual()
                references trabalho(id) on delete cascade,
  cnpj text, nome text, uf text, dt_ini date, dt_fin date, ind_fin_esc text,
  nome_arquivo text, sha256 text not null,
  vigente boolean not null default true,
  linhas int, lancamentos int, problemas jsonb,
  importado_por text, importado_em timestamptz not null default now()
);
create unique index if not exists ux_ecd_sha on ecd_arquivo_todos (trabalho_id, sha256);
create or replace view ecd_arquivo as
  select * from ecd_arquivo_todos where trabalho_id = trabalho_atual();

create table if not exists ecd_conta_todos (
  id bigserial primary key,
  trabalho_id bigint not null default trabalho_atual() references trabalho(id) on delete cascade,
  arquivo_id bigint not null references ecd_arquivo_todos(id) on delete cascade,
  cod_cta text not null, cod_cta_sup text, nome text, cod_nat text, ind_cta text,
  nivel int, cod_cta_ref text, linha_arquivo int
);
create index if not exists ix_ecd_conta on ecd_conta_todos (arquivo_id, cod_cta);
create or replace view ecd_conta as
  select * from ecd_conta_todos where trabalho_id = trabalho_atual();

create table if not exists ecd_saldo_todos (
  id bigserial primary key,
  trabalho_id bigint not null default trabalho_atual() references trabalho(id) on delete cascade,
  arquivo_id bigint not null references ecd_arquivo_todos(id) on delete cascade,
  dt_ini date, dt_fin date, cod_cta text not null, cod_ccus text,
  sl_ini numeric(18,2), debitos numeric(18,2), creditos numeric(18,2), sl_fin numeric(18,2),
  linha_arquivo int
);
create index if not exists ix_ecd_saldo on ecd_saldo_todos (arquivo_id, dt_ini, cod_cta);
comment on table ecd_saldo_todos is
  'I155: saldo de cada conta em cada periodo. Devedor positivo, credor negativo.';
create or replace view ecd_saldo as
  select * from ecd_saldo_todos where trabalho_id = trabalho_atual();

create table if not exists ecd_encerramento_todos (
  id bigserial primary key,
  trabalho_id bigint not null default trabalho_atual() references trabalho(id) on delete cascade,
  arquivo_id bigint not null references ecd_arquivo_todos(id) on delete cascade,
  mes date, cod_cta text, cod_ccus text, debitos numeric(18,2), creditos numeric(18,2)
);
comment on table ecd_encerramento_todos is
  'Partidas dos lancamentos de encerramento (I200 com IND_LCTO = E), por mes e conta.';
create or replace view ecd_encerramento as
  select * from ecd_encerramento_todos where trabalho_id = trabalho_atual();


create or replace function importar_ecd(p jsonb)
returns jsonb language plpgsql as $$
declare
  a jsonb := p->'arquivo';
  v_ja bigint; v_id bigint; v_ant int;
begin
  select id into v_ja from ecd_arquivo where sha256 = a->>'sha256';
  if v_ja is not null then
    return jsonb_build_object('situacao', 'ja_importado', 'arquivo_id', v_ja);
  end if;

  -- Retificadora: a anterior do mesmo periodo deixa de valer, mas fica.
  update ecd_arquivo set vigente = false
   where left(cnpj, 8) = left(a->>'cnpj', 8)
     and dt_ini = (a->>'dt_ini')::date and dt_fin = (a->>'dt_fin')::date and vigente;
  get diagnostics v_ant = row_count;

  insert into ecd_arquivo (cnpj, nome, uf, dt_ini, dt_fin, ind_fin_esc, nome_arquivo,
                           sha256, linhas, lancamentos, problemas, importado_por)
  values (a->>'cnpj', a->>'nome', a->>'uf', (a->>'dt_ini')::date, (a->>'dt_fin')::date,
          a->>'ind_fin_esc', a->>'nome_arquivo', a->>'sha256', (a->>'linhas')::int,
          (a->>'lancamentos')::int, a->'problemas', a->>'importado_por')
  returning id into v_id;

  insert into ecd_conta (arquivo_id, cod_cta, cod_cta_sup, nome, cod_nat, ind_cta,
                         nivel, cod_cta_ref, linha_arquivo)
  select v_id, x->>'cod_cta', nullif(x->>'cod_cta_sup',''), x->>'nome', x->>'cod_nat',
         x->>'ind_cta', (x->>'nivel')::int, nullif(x->>'cod_cta_ref',''), (x->>'linha')::int
    from jsonb_array_elements(coalesce(p->'contas','[]')) x;

  insert into ecd_saldo (arquivo_id, dt_ini, dt_fin, cod_cta, cod_ccus, sl_ini,
                         debitos, creditos, sl_fin, linha_arquivo)
  select v_id, (x->>'dt_ini')::date, (x->>'dt_fin')::date, x->>'cod_cta',
         nullif(x->>'cod_ccus',''), (x->>'sl_ini')::numeric, (x->>'debitos')::numeric,
         (x->>'creditos')::numeric, (x->>'sl_fin')::numeric, (x->>'linha')::int
    from jsonb_array_elements(coalesce(p->'saldos','[]')) x;

  insert into ecd_encerramento (arquivo_id, mes, cod_cta, cod_ccus, debitos, creditos)
  select v_id, (x->>'mes')::date, x->>'cod_cta', nullif(x->>'cod_ccus',''),
         (x->>'debitos')::numeric, (x->>'creditos')::numeric
    from jsonb_array_elements(coalesce(p->'encerramento','[]')) x;

  return jsonb_build_object(
    'situacao', case when v_ant > 0 then 'substituiu' else 'importado' end,
    'arquivo_id', v_id,
    'contas', (select count(*) from ecd_conta where arquivo_id = v_id),
    'saldos', (select count(*) from ecd_saldo where arquivo_id = v_id));
end $$;


-- ============================================================ resultado
-- Movimento de cada conta analitica de resultado, por mes, sem o encerramento.
-- valor > 0 = credor (receita, reducao de despesa); < 0 = devedor (custo, despesa).
create or replace function ecd_movimento_resultado(p_ini date, p_fim date)
returns table (arquivo_id bigint, mes date, cod_cta text, valor numeric)
language sql stable as $$
  with arq as (select id from ecd_arquivo where vigente),
  conta as (select c.arquivo_id, c.cod_cta from ecd_conta c
             where c.arquivo_id in (select id from arq)
               and c.cod_nat = '04' and c.ind_cta = 'A'),
  s as (select s.arquivo_id, s.dt_ini as mes, s.cod_cta,
               sum(s.creditos - s.debitos) v
          from ecd_saldo s
          join conta c on c.arquivo_id = s.arquivo_id and c.cod_cta = s.cod_cta
         where s.dt_ini between p_ini and p_fim
         group by 1, 2, 3),
  e as (select e.arquivo_id, e.mes, e.cod_cta, sum(e.creditos - e.debitos) v
          from ecd_encerramento e
          join conta c on c.arquivo_id = e.arquivo_id and c.cod_cta = e.cod_cta
         where e.mes between p_ini and p_fim
         group by 1, 2, 3)
  select s.arquivo_id, s.mes, s.cod_cta, s.v - coalesce(e.v, 0)
    from s left join e using (arquivo_id, mes, cod_cta);
$$;


create or replace function ecd_resultado_mensal(p_ini date, p_fim date)
returns table (mes date, receitas numeric, custos_despesas numeric, resultado numeric,
               contas bigint)
language sql stable as $$
  select mes,
         round(sum(valor) filter (where valor > 0), 2),
         round(-sum(valor) filter (where valor < 0), 2),
         round(sum(valor), 2),
         count(*)
    from ecd_movimento_resultado(p_ini, p_fim)
   group by mes order by mes;
$$;
comment on function ecd_resultado_mensal(date, date) is
  'Resultado contabil de cada mes: creditos menos debitos das contas de '
  'resultado, sem o encerramento. Positivo e lucro.';


-- A DRE com a estrutura do proprio plano de contas: cada conta de resultado,
-- sintetica ou analitica, com a soma das analiticas que estao abaixo dela.
create or replace function ecd_dre(p_ini date, p_fim date)
returns table (cod_cta text, cod_cta_sup text, nome text, nivel int, ind_cta text,
               cod_cta_ref text, valor numeric)
language sql stable as $$
  with recursive mov as (
    select arquivo_id, cod_cta, sum(valor) v
      from ecd_movimento_resultado(p_ini, p_fim) group by 1, 2
  ), conta as (
    select c.* from ecd_conta c
     where c.arquivo_id in (select id from ecd_arquivo where vigente) and c.cod_nat = '04'
  ), sobe as (
    -- cada analitica com movimento sobe a arvore, levando o valor
    select c.arquivo_id, c.cod_cta, c.cod_cta_sup, m.v
      from conta c join mov m on m.arquivo_id = c.arquivo_id and m.cod_cta = c.cod_cta
    union all
    select p.arquivo_id, p.cod_cta, p.cod_cta_sup, s.v
      from sobe s join conta p on p.arquivo_id = s.arquivo_id and p.cod_cta = s.cod_cta_sup
  )
  select c.cod_cta, c.cod_cta_sup, min(c.nome), min(c.nivel), min(c.ind_cta),
         min(c.cod_cta_ref), round(sum(s.v), 2)
    from sobe s join conta c on c.arquivo_id = s.arquivo_id and c.cod_cta = s.cod_cta
   group by c.cod_cta, c.cod_cta_sup
   order by c.cod_cta;
$$;


-- Receita de vendas na contabilidade x faturamento pelas notas, mes a mes.
-- Quais contas sao "receita de venda" se identifica pelo plano referencial
-- (3.01.01.01...) e, na falta dele, pelo nome. As contas escolhidas aparecem
-- na tela, para o auditor conferir o criterio.
create or replace function ecd_contas_receita_venda()
returns table (cod_cta text, nome text, cod_cta_ref text, criterio text)
language sql stable as $$
  select c.cod_cta, c.nome, c.cod_cta_ref,
         case when c.cod_cta_ref like '3.01.01.01%' then 'plano referencial'
              else 'nome da conta' end
    from ecd_conta c
   where c.arquivo_id in (select id from ecd_arquivo where vigente)
     and c.cod_nat = '04' and c.ind_cta = 'A'
     and (c.cod_cta_ref like '3.01.01.01%'
          or (coalesce(c.cod_cta_ref, '') = ''
              and upper(c.nome) like '%VENDA%'
              and upper(c.nome) not like '%CUSTO%'
              and upper(c.nome) not like '%DEVOLU%'
              and upper(c.nome) not like '%CANCEL%'));
$$;

create or replace function confronto_receita(p_ini date, p_fim date)
returns table (mes date, receita_contabil numeric, faturamento_notas numeric, diferenca numeric)
language sql stable as $$
  with rc as (
    select m.mes, sum(m.valor) v
      from ecd_movimento_resultado(p_ini, p_fim) m
     where m.cod_cta in (select cod_cta from ecd_contas_receita_venda())
     group by 1
  ), meses as (
    select distinct mes from rc
  ), fn as (
    select ms.mes,
           -- Bruto: a contabilidade lanca devolucao em conta propria, e as
           -- contas de receita escolhidas excluem devolucao pelo nome.
           (select coalesce(sum(r.valor), 0)
              from faturamento_periodo(ms.mes, (ms.mes + interval '1 month - 1 day')::date, null) r
             where r.sinal = 1) v
      from meses ms
  )
  select rc.mes, round(rc.v, 2), round(fn.v, 2), round(rc.v - fn.v, 2)
    from rc join fn using (mes) order by rc.mes;
$$;
