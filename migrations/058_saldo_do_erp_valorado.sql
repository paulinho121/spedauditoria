-- 058 — a foto do ERP sozinha, com valor
--
-- O confronto (057) mistura a foto do ERP com a nossa posição. Para o relatório
-- de auditoria é preciso o contrário: só o que o ERP declara ter — código,
-- descrição, NCM, quantidade — e quanto isso vale.
--
-- O arquivo de saldo não traz preço. O valor sai do custo que a nossa base
-- conhece para o mesmo código, nesta ordem, e a origem acompanha cada linha:
--
--   1. custo médio da própria filial na data da foto (a nossa apuração);
--   2. última entrada na própria filial (inventário de abertura ou nota);
--   3. última entrada do mesmo código em outra filial da empresa;
--   4. custo médio que o próprio ERP informou num extrato de movimentos.
--
-- Preço de venda não entra: estoque se mede a custo, e o preço da última saída
-- inflaria o total com a margem. Item sem nenhuma dessas fontes fica sem valor
-- — o total valorado é parcial e quem lê tem de ver quanto ficou de fora.

create or replace function erp_saldo_valorado(p_arquivo_id bigint)
returns table (
  cod_item text, descr_item text, unid text, ncm text, qtd numeric,
  custo_unit numeric, valor numeric,
  custo_origem text, custo_fonte text, custo_dt date,
  linhas_no_arquivo bigint
)
language plpgsql stable as $$
declare a record;
begin
  select * into a from erp_saldo_arquivo where id = p_arquivo_id;
  if a.id is null then return; end if;

  return query
  with erp as (
    select l.cod_item,
           (array_agg(l.descr_item order by length(coalesce(l.descr_item,'')) desc))[1] descr,
           max(l.unid) unid, max(l.ncm) ncm, sum(l.qtd) qtd, count(*)::bigint linhas
      from erp_saldo_linha l
     where l.arquivo_id = p_arquivo_id
     group by l.cod_item
  ), medio as (
    select e.cod_item, e.custo_medio, e.ultima_mov
      from estoque_em(a.dt) e
     where e.cnpj = a.cnpj and e.custo_medio > 0
  ), entrada as (
    -- A entrada mais recente de cada código em cada filial, até a data da foto.
    select distinct on (m.cnpj, m.cod_item)
           m.cnpj, m.cod_item, m.vl_unit, m.dt, m.origem
      from movimento m
     where m.efeito = 'soma' and m.vl_unit > 0 and m.dt <= a.dt
     order by m.cnpj, m.cod_item, m.dt desc, m.id desc
  ), propria as (
    select * from entrada where cnpj = a.cnpj
  ), outra as (
    select distinct on (e.cod_item) e.*,
           (select s.uf from estabelecimento s where s.cnpj = e.cnpj limit 1) uf
      from entrada e
     where e.cnpj <> a.cnpj
     order by e.cod_item, e.dt desc
  ), extrato as (
    select distinct on (l.cod_item) l.cod_item, l.custo_medio, l.dt, l.deposito
      from erp_extrato_linha l
      join erp_extrato_arquivo x on x.id = l.arquivo_id and x.vigente
     where l.custo_medio > 0 and coalesce(l.dt, x.dt_ini) <= a.dt
     order by l.cod_item, coalesce(l.dt, x.dt_ini) desc, l.seq desc
  ), custo as (
    select e.*,
           coalesce(md.custo_medio, p.vl_unit, o.vl_unit, x.custo_medio) unit,
           case when md.cod_item is not null then 'custo_medio_filial'
                when p.cod_item  is not null then 'entrada_filial'
                when o.cod_item  is not null then 'entrada_outra_filial'
                when x.cod_item  is not null then 'erp_extrato'
           end origem,
           case when md.cod_item is not null then
                  'Custo médio ' || coalesce(a.uf, 'da filial') || ' (nossa apuração)'
                when p.cod_item is not null then
                  'Última entrada ' || coalesce(a.uf, 'na filial') ||
                  case when p.origem = 'abertura' then ' — inventário' else ' — nota' end
                when o.cod_item is not null then
                  'Última entrada ' || coalesce(o.uf, 'outra filial') ||
                  case when o.origem = 'abertura' then ' — inventário' else ' — nota' end
                when x.cod_item is not null then
                  'Custo médio do ERP — extrato ' || coalesce(x.deposito, '')
           end fonte,
           coalesce(md.ultima_mov, p.dt, o.dt, x.dt) dt_custo
      from erp e
      left join medio   md on md.cod_item = e.cod_item
      left join propria p  on p.cod_item  = e.cod_item
      left join outra   o  on o.cod_item  = e.cod_item
      left join extrato x  on x.cod_item  = e.cod_item
  )
  select c.cod_item, c.descr, c.unid, c.ncm, c.qtd,
         round(c.unit, 4), round(c.qtd * c.unit, 2),
         c.origem, c.fonte, c.dt_custo, c.linhas
    from custo c
   order by case when c.cod_item ~ '^\d+$' then lpad(c.cod_item, 20, '0')
                 else c.cod_item end;
end $$;
comment on function erp_saldo_valorado(bigint) is
  'A foto do ERP isolada (codigo, descricao, NCM, quantidade) valorada pelo '
  'custo que a base conhece, com a origem do custo em cada linha. Item sem '
  'custo conhecido fica sem valor: o total e parcial.';
