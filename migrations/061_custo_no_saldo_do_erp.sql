-- 061 — o relatório de saldo do ERP pode trazer custo
--
-- O "Saldo de produtos" vem com as colunas que quem exportou deixou visíveis.
-- Com Custo Unitário e Valor Total, a foto passa a dizer não só o que o ERP
-- declara ter, mas quanto ele declara que vale.
--
-- Esse custo vira a primeira fonte do estoque declarado: o relatório é a
-- posição DO ERP, e o valor dela é o que o ERP atribui. As fontes da nossa base
-- (custo médio, entrada, remessa para armazém, outra filial, extrato) continuam
-- valendo para duas coisas:
--
--   · completar a linha em que o ERP declara custo ZERO — produto com saldo e
--     custo zero é falha do ERP, e a base muitas vezes tem o documento;
--   · ficar ao lado do custo declarado, com a diferença em %: é aí que o custo
--     do ERP é conferido contra documento.
--
-- Custo zero no arquivo é guardado como zero (é o que o ERP disse), mas não
-- vale como custo.

alter table erp_saldo_linha_todos
  add column if not exists custo_unit  numeric,
  add column if not exists valor_total numeric;
comment on column erp_saldo_linha_todos.custo_unit is
  'Custo unitario declarado pelo ERP no relatorio. Zero e zero declarado; nulo '
  'e relatorio exportado sem a coluna.';

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
                               fabricante, deposito, local_escrituracao, cnpj, qtd,
                               custo_unit, valor_total)
  select v_id, (x->>'seq')::int, x->>'cod_item', nullif(x->>'descr_item',''),
         nullif(x->>'unid',''), nullif(x->>'ncm',''), nullif(x->>'fabricante',''),
         coalesce(nullif(x->>'deposito',''), v_dep),
         nullif(x->>'local',''),
         erp_cnpj_do_deposito(coalesce(nullif(x->>'deposito',''), v_dep)),
         (x->>'qtd')::numeric,
         nullif(x->>'custo_unit','')::numeric,
         nullif(x->>'valor_total','')::numeric
    from jsonb_array_elements(coalesce(p->'linhas','[]')) x;

  return jsonb_build_object(
    'situacao', case when v_ant > 0 then 'substituiu' else 'importado' end,
    'arquivo_id', v_id, 'cnpj', v_cnpj, 'deposito', v_dep, 'dt', v_dt,
    'linhas', (select count(*) from erp_saldo_linha where arquivo_id = v_id),
    'com_ncm', (select count(*) from erp_saldo_linha
                 where arquivo_id = v_id and ncm is not null),
    'com_custo', (select count(*) from erp_saldo_linha
                   where arquivo_id = v_id and custo_unit > 0));
end $$;
comment on function importar_erp_saldo(jsonb) is
  'Grava a foto do saldo do ERP numa chamada. Reimportar o mesmo arquivo nao '
  'faz nada; foto nova do mesmo deposito e data substitui a anterior.';


drop function if exists erp_saldo_valorado(bigint);

create function erp_saldo_valorado(p_arquivo_id bigint)
returns table (
  seq int, cod_item text, descr_item text, unid text, ncm text, qtd numeric,
  custo_unit numeric, valor numeric,
  custo_origem text, custo_fonte text, custo_dt date,
  linhas_no_arquivo bigint,
  custo_erp numeric, valor_erp numeric,
  custo_base numeric, custo_base_fonte text, custo_base_dt date,
  dif_pct numeric
)
language plpgsql stable as $$
declare a record;
begin
  select * into a from erp_saldo_arquivo where id = p_arquivo_id;
  if a.id is null then return; end if;

  return query
  with erp as (
    select l.seq, l.cod_item, l.descr_item descr, l.unid, l.ncm, l.qtd,
           -- Custo zero é o ERP dizendo zero; não vale como custo.
           nullif(greatest(l.custo_unit, 0), 0) custo_erp,
           l.valor_total,
           count(*) over (partition by l.cod_item) linhas
      from erp_saldo_linha l
     where l.arquivo_id = p_arquivo_id
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
  ), remessa as (
    -- Remessa para armazém geral ou depósito fechado, emitida pela própria
    -- filial: a mercadoria continua sendo dela e a nota sai pelo valor da
    -- mercadoria, sem margem. Não é entrada, mas é o custo que a própria
    -- empresa declarou para o item — e é documento fiscal, não cadastro.
    select distinct on (m.cod_item) m.cod_item, m.vl_unit, m.dt,
           (select n.num_nf from nfe n where n.id = m.nfe_id) num_nf
      from movimento m
     where m.cnpj = a.cnpj and m.cfop in ('5905', '6905')
       and m.vl_unit > 0 and m.dt <= a.dt
     order by m.cod_item, m.dt desc, m.id desc
  ), extrato as (
    select distinct on (l.cod_item) l.cod_item, l.custo_medio,
           coalesce(l.dt, x.dt_ini) dt, l.deposito
      from erp_extrato_linha l
      join erp_extrato_arquivo x on x.id = l.arquivo_id and x.vigente
     where l.custo_medio > 0 and coalesce(l.dt, x.dt_ini) <= a.dt
     order by l.cod_item, coalesce(l.dt, x.dt_ini) desc, l.seq desc
  ), custo as (
    select e.*,
           coalesce(md.custo_medio, p.vl_unit, r.vl_unit, o.vl_unit, x.custo_medio) unit,
           case when md.cod_item is not null then 'custo_medio_filial'
                when p.cod_item  is not null then 'entrada_filial'
                when r.cod_item  is not null then 'remessa_armazem'
                when o.cod_item  is not null then 'entrada_outra_filial'
                when x.cod_item  is not null then 'erp_extrato'
           end origem,
           case when md.cod_item is not null then
                  'Custo médio ' || coalesce(a.uf, 'da filial') || ' (nossa apuração)'
                when p.cod_item is not null then
                  'Última entrada ' || coalesce(a.uf, 'na filial') ||
                  case when p.origem = 'abertura' then ' — inventário' else ' — nota' end
                when r.cod_item is not null then
                  'Remessa p/ armazém ' || coalesce(a.uf, '') ||
                  coalesce(' — NF ' || r.num_nf, '')
                when o.cod_item is not null then
                  'Última entrada ' || coalesce(o.uf, 'outra filial') ||
                  case when o.origem = 'abertura' then ' — inventário' else ' — nota' end
                when x.cod_item is not null then
                  'Custo médio do ERP — extrato ' || coalesce(x.deposito, '')
           end fonte,
           coalesce(md.ultima_mov, p.dt, r.dt, o.dt, x.dt) dt_custo
      from erp e
      left join medio   md on md.cod_item = e.cod_item
      left join propria p  on p.cod_item  = e.cod_item
      left join remessa r  on r.cod_item  = e.cod_item
      left join outra   o  on o.cod_item  = e.cod_item
      left join extrato x  on x.cod_item  = e.cod_item
  )
  select c.seq, c.cod_item, c.descr, c.unid, c.ncm, c.qtd,
         round(coalesce(c.custo_erp, c.unit), 4),
         -- Com custo do ERP vale o total que o ERP imprimiu: ele multiplica
         -- com todas as casas, e o relatório tem de fechar com o dele.
         round(case when c.custo_erp is not null
                    then coalesce(c.valor_total, c.qtd * c.custo_erp)
                    else c.qtd * c.unit end, 2),
         case when c.custo_erp is not null then 'erp_arquivo' else c.origem end,
         case when c.custo_erp is not null then 'Custo do ERP (o próprio relatório)'
              else c.fonte end,
         case when c.custo_erp is not null then a.dt else c.dt_custo end,
         c.linhas,
         round(c.custo_erp, 4),
         round(case when c.custo_erp is not null
                    then coalesce(c.valor_total, c.qtd * c.custo_erp) end, 2),
         round(c.unit, 4), c.fonte, c.dt_custo,
         case when c.custo_erp is not null and c.unit > 0
              then round((c.custo_erp / c.unit - 1) * 100, 1) end
    from custo c
   order by case when c.cod_item ~ '^\d+$' then lpad(c.cod_item, 20, '0')
                 else c.cod_item end, c.seq;
end $$;
comment on function erp_saldo_valorado(bigint) is
  'A foto do ERP isolada, linha a linha como veio no arquivo. Valor pelo custo '
  'que o proprio ERP declarou; onde ele declara zero, pelo custo que a base '
  'conhece. custo_base e dif_pct mostram o custo documentado ao lado do '
  'declarado. Linha sem nenhum custo fica sem valor.';
