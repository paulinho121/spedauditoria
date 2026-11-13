-- 067 — custo pela última compra, e nota contada como a tela agrupa
--
-- Duas correções na conta do estoque real (064):
--
-- 1. O custo usado para dar valor ao estoque era o da última entrada de
--    qualquer tipo. O último movimento de entrada de muito produto é um retorno
--    de locação, que vem pelo valor declarado do bem — bem acima do custo. A
--    ordem passa a ser: última COMPRA, depois último retorno de armazém, depois
--    qualquer entrada; e a origem do custo sai em coluna própria.
--
-- 2. O resumo contava "notas" pelo texto do documento. A tela agrupa por
--    documento, data, operação e entidade — o mesmo número de nota aparece em
--    mais de uma operação, e lançamento sem documento não pode virar uma nota
--    só. As duas contas passam a ser a mesma.

drop function if exists erp_real_produtos(bigint);

-- O produto: onde está, quanto falta, quanto é o estoque real.
create function erp_real_produtos(p_arquivo_id bigint)
returns table (
  cod_item text, descr_item text, unid text, ncm text,
  movimentos bigint, primeira date, ultima date,
  entradas numeric, saidas numeric,
  saldo_erp numeric, saldo_impresso numeric, menor_saldo numeric,
  em_armazem numeric, em_locacao numeric, em_comodato numeric,
  em_demonstracao numeric, em_outros numeric, em_terceiros numeric,
  retorno_sem_remessa numeric, falta_entrada numeric, estoque_real numeric,
  situacao text, cadastros bigint,
  custo numeric, custo_origem text, custo_erp numeric, valor_real numeric,
  saldo_foto numeric
)
language plpgsql stable as $$
#variable_conflict use_column
declare a record; v_foto bigint;
begin
  select * into a from erp_extrato_arquivo where id = p_arquivo_id;
  if a.id is null then return; end if;
  -- A foto de saldo mais recente do mesmo depósito dá o NCM e o custo médio
  -- que o ERP declara, para ficar ao lado do custo da última entrada.
  select f.id into v_foto from erp_saldo_arquivo f
   where f.vigente and f.cnpj is not distinct from a.cnpj
   order by f.dt desc, f.id desc limit 1;

  return query
  with b as (select * from erp_real_linhas(p_arquivo_id)),
  par as (                       -- saldo final de cada (natureza, terceiro)
    select l.cod_item, l.descr_item, l.natureza, l.entidade_chave,
           sum(l.sai - l.ent) fora
      from b l where l.terceiro
     group by 1, 2, 3, 4
  ), terc as (
    select p.cod_item, p.descr_item,
           sum(greatest(p.fora, 0)) filter (where p.natureza = 'armazem')      armazem,
           sum(greatest(p.fora, 0)) filter (where p.natureza = 'locacao')      locacao,
           sum(greatest(p.fora, 0)) filter (where p.natureza = 'comodato')     comodato,
           sum(greatest(p.fora, 0)) filter (where p.natureza = 'demonstracao') demonstracao,
           sum(greatest(p.fora, 0)) filter (where p.natureza in
                 ('exposicao','conserto','garantia'))                          outros,
           sum(greatest(p.fora, 0))  total,
           sum(greatest(-p.fora, 0)) volta_a_mais
      from par p group by 1, 2
  ), prod as (
    select l.cod_item, l.descr_item, max(l.unid) unid,
           count(*) movimentos, min(l.dt) primeira, max(l.dt) ultima,
           sum(l.ent) entradas, sum(l.sai) saidas,
           sum(l.ent - l.sai) saldo,
           (array_agg(l.saldo_impresso order by l.seq desc))[1] impresso,
           least(min(l.saldo), 0) menor,
           -- O custo MÉDIO do extrato não serve: a saída por venda vem com custo
           -- zero, o custo do saldo não baixa, e a média seguinte sai inflada
           -- (ou negativa, quando o saldo passou por negativo). Vale o custo
           -- unitário de um documento de entrada, nesta ordem: a última
           -- COMPRA; sem compra, o último retorno de armazém (que volta pelo
           -- valor da remessa); por fim, qualquer entrada. Retorno de locação
           -- ou de comodato vem pelo valor declarado do bem, não pelo custo —
           -- por isso fica por último.
           (array_agg(l.custo_entrada / l.ent order by l.seq desc)
              filter (where l.ent > 0 and l.custo_entrada > 0
                        and l.natureza = 'compra'))[1] c_compra,
           (array_agg(l.custo_entrada / l.ent order by l.seq desc)
              filter (where l.ent > 0 and l.custo_entrada > 0
                        and l.natureza = 'armazem'))[1] c_armazem,
           (array_agg(l.custo_entrada / l.ent order by l.seq desc)
              filter (where l.ent > 0 and l.custo_entrada > 0))[1] c_outra
      from b l group by 1, 2
  ), calc as (
    select p.*, coalesce(p.c_compra, p.c_armazem, p.c_outra) cm,
           coalesce(t.armazem, 0) armazem, coalesce(t.locacao, 0) locacao,
           coalesce(t.comodato, 0) comodato, coalesce(t.demonstracao, 0) demonstracao,
           coalesce(t.outros, 0) outros, coalesce(t.total, 0) terceiros,
           coalesce(t.volta_a_mais, 0) volta_a_mais,
           p.saldo + coalesce(t.total, 0) posicao,
           count(*) over (partition by p.cod_item) cadastros
      from prod p
      left join terc t on t.cod_item = p.cod_item and t.descr_item = p.descr_item
  )
  select c.cod_item, c.descr_item, c.unid, f.ncm,
         c.movimentos, c.primeira, c.ultima, c.entradas, c.saidas,
         c.saldo, c.impresso, c.menor,
         c.armazem, c.locacao, c.comodato, c.demonstracao, c.outros, c.terceiros,
         c.volta_a_mais,
         greatest(-c.posicao, 0), greatest(c.posicao, 0),
         case when c.posicao < 0      then 'falta_entrada'
              when c.saldo < 0        then 'negativo_hoje'
              when c.volta_a_mais > 0 then 'retorno_sem_remessa'
              when c.menor < 0        then 'ficou_negativo'
              else 'ok' end,
         c.cadastros,
         round(c.cm, 4),
         case when c.c_compra is not null then 'compra'
              when c.c_armazem is not null then 'armazem'
              when c.c_outra is not null then 'entrada' end,
         round(f.custo, 4),
         round(greatest(c.posicao, 0) * c.cm, 2),
         f.qtd
    from calc c
    left join lateral (
      -- Mesmo código em dois cadastros: casa primeiro pela descrição.
      select s.ncm, nullif(greatest(s.custo_unit, 0), 0) custo, s.qtd
        from erp_saldo_linha s
       where s.arquivo_id = v_foto and s.cod_item = c.cod_item
       order by (coalesce(s.descr_item, '') = c.descr_item) desc, s.seq
       limit 1
    ) f on true
   order by case when c.cod_item ~ '^\d+$' then lpad(c.cod_item, 20, '0')
                 else c.cod_item end, c.descr_item;
end $$;
comment on function erp_real_produtos(bigint) is
  'Por produto do extrato: saldo do deposito, em poder de terceiros por '
  'natureza, retorno sem remessa, entrada que falta e estoque real.';


create or replace function erp_real_resumo(p_arquivo_id bigint)
returns jsonb language sql stable as $$
  with p as (select * from erp_real_produtos(p_arquivo_id)),
       se as (select * from erp_real_sem_estoque(p_arquivo_id)),
       sr as (select * from erp_real_sem_remessa(p_arquivo_id)),
       et as (select * from erp_real_em_terceiros(p_arquivo_id))
  select jsonb_build_object(
    'produtos', (select count(*) from p),
    'movimentos', (select coalesce(sum(movimentos), 0) from p),
    'primeira', (select min(primeira) from p),
    'ultima', (select max(ultima) from p),
    'saldo_erp', (select coalesce(sum(saldo_erp), 0) from p),
    'negativos_hoje', (select count(*) from p where saldo_erp < 0),
    'qtd_negativa_hoje', (select coalesce(-sum(saldo_erp), 0) from p where saldo_erp < 0),
    'em_terceiros', (select coalesce(sum(em_terceiros), 0) from p),
    'em_armazem', (select coalesce(sum(em_armazem), 0) from p),
    'em_locacao', (select coalesce(sum(em_locacao), 0) from p),
    'em_comodato', (select coalesce(sum(em_comodato), 0) from p),
    'em_demonstracao', (select coalesce(sum(em_demonstracao), 0) from p),
    'em_outros', (select coalesce(sum(em_outros), 0) from p),
    'retorno_sem_remessa', (select coalesce(sum(retorno_sem_remessa), 0) from p),
    'falta_entrada', (select coalesce(sum(falta_entrada), 0) from p),
    'produtos_falta_entrada', (select count(*) from p where falta_entrada > 0),
    'estoque_real', (select coalesce(sum(estoque_real), 0) from p),
    'valor_real', (select coalesce(sum(valor_real), 0) from p),
    'sem_custo', (select count(*) from p where estoque_real > 0 and custo is null),
    'custo_por_compra', (select count(*) from p where custo_origem = 'compra'),
    'situacoes', (select jsonb_object_agg(situacao, n)
                    from (select situacao, count(*) n from p group by 1) x),
    'sem_estoque_linhas', (select count(*) from se),
    'sem_estoque_notas', (select count(distinct (doc_texto, dt, tipo, entidade)) from se),
    'sem_estoque_qtd', (select coalesce(sum(descoberto), 0) from se),
    'sem_estoque_abertas', (select count(*) from se where situacao = 'aberta'),
    'sem_estoque_abertas_notas',
       (select count(*) from (select 1 from se group by doc_texto, dt, tipo, entidade
                               having bool_or(situacao = 'aberta')) x),
    'sem_estoque_abertas_qtd',
       (select coalesce(sum(descoberto), 0) from se where situacao = 'aberta'),
    'sem_remessa_linhas', (select count(*) from sr),
    'sem_remessa_notas', (select count(distinct (doc_texto, dt, tipo, entidade)) from sr),
    'sem_remessa_qtd', (select coalesce(sum(sem_lastro), 0) from sr),
    'sem_remessa_abertas', (select count(*) from sr where situacao = 'aberta'),
    'sem_remessa_abertas_notas',
       (select count(*) from (select 1 from sr group by doc_texto, dt, tipo, entidade
                               having bool_or(situacao = 'aberta')) x),
    'em_terceiros_linhas', (select count(*) from et),
    'em_terceiros_notas', (select count(distinct (doc_texto, dt, tipo, entidade)) from et),
    'em_terceiros_qtd', (select coalesce(sum(pendente), 0) from et),
    'inconsistencias', (select count(*) from erp_real_inconsistencias(p_arquivo_id))
  ) || (
    -- O custo do extrato: saída sem custo não baixa o custo do saldo, e o custo
    -- médio seguinte sai errado. Contado aqui para a tela dizer o tamanho.
    select jsonb_build_object(
      'saidas', count(*) filter (where x.qtd_saida > 0),
      'saidas_custo_zero',
         count(*) filter (where x.qtd_saida > 0 and coalesce(x.custo_saida, 0) = 0),
      'vendas', count(*) filter (where x.qtd_saida > 0 and erp_natureza(x.tipo) = 'venda'),
      'vendas_custo_zero',
         count(*) filter (where x.qtd_saida > 0 and coalesce(x.custo_saida, 0) = 0
                            and erp_natureza(x.tipo) = 'venda'),
      'custo_medio_negativo', count(*) filter (where x.custo_medio < 0),
      'saldo_zero_com_custo',
         count(*) filter (where x.qtd_saldo = 0 and x.custo_saldo > 0.01))
      from erp_extrato_linha x
     where x.arquivo_id = p_arquivo_id and not x.abertura
  )
$$;
comment on function erp_real_resumo(bigint) is
  'Os numeros do topo da tela Estoque real.';
