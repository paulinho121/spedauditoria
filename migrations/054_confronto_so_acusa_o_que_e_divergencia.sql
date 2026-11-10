-- 054 — O confronto com o ERP so acusa o que e divergencia.
--
-- O primeiro confronto classificou como "so na nossa apuracao" todo item que
-- tinha saldo nosso e nao aparecia no extrato. Mas o extrato lista o que se
-- MOVEU no periodo: item parado nao aparece nele, e isso nao e divergencia
-- nenhuma. Em dezembro/2023 isso encheu a tela com 85 itens que estavam certos.
--
-- Agora "so na nossa apuracao" exige que a gente tenha MOVIMENTADO o item no
-- periodo. Item com saldo e sem movimento dos dois lados vira 'sem_movimento',
-- que e informacao, nao achado.
--
-- E o resumo passa a dizer quantas notas nossas existem no periodo. Sem essa
-- informacao, um mes que ninguem importou aparece como "o ERP movimentou 88
-- notas que nos nao temos" — verdadeiro e enganoso ao mesmo tempo. O numero
-- muda a leitura inteira da tela, entao tem de estar nela.

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
           -- O extrato lista o que se moveu. Item parado nao estar nele e o
           -- esperado; so vira achado se NOS movimentamos e ele nao registrou.
           when e.cod_item is null and coalesce(p.entradas,0) + coalesce(p.saidas,0) > 0
                then 'so_nosso'
           when e.cod_item is null then 'sem_movimento'
           when coalesce(f.qtd,0) = 0 and coalesce(p.entradas,0) + coalesce(p.saidas,0) = 0
                and coalesce(i.qtd,0) = 0 then 'so_erp'
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


drop function if exists erp_confronto_resumo(bigint);
create or replace function erp_confronto_resumo(p_arquivo_id bigint)
returns table (
  cnpj text, uf text, deposito text, dt_ini date, dt_fin date,
  itens bigint, confere bigint, saldo_difere bigint, abertura_difere bigint,
  valor_difere bigint, so_erp bigint, so_nosso bigint, sem_movimento bigint,
  erp_valor_final numeric, nosso_valor_final numeric, dif_valor numeric,
  docs_so_erp bigint, docs_so_nosso bigint, docs_qtd_difere bigint,
  linhas_sem_documento bigint,
  nossas_notas bigint, nossos_movimentos bigint
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
         count(*) filter (where i.situacao = 'sem_movimento')::bigint,
         round(coalesce(sum(i.erp_valor), 0), 2),
         round(coalesce(sum(i.nosso_valor), 0), 2),
         round(coalesce(sum(i.erp_valor) - sum(i.nosso_valor), 0), 2),
         (select count(*) from erp_confronto_documento(p_arquivo_id) d where d.situacao = 'so_erp'),
         (select count(*) from erp_confronto_documento(p_arquivo_id) d where d.situacao = 'so_nosso'),
         (select count(*) from erp_confronto_documento(p_arquivo_id) d where d.situacao = 'qtd_difere'),
         (select count(*) from erp_extrato_linha l
           where l.arquivo_id = p_arquivo_id and not l.abertura
             and coalesce(l.doc_num, '') = ''),
         -- Quantas notas nossas existem no periodo do extrato. Zero aqui muda
         -- a leitura da tela inteira: nao ha divergencia, ha mes sem importar.
         (select count(distinct m.nfe_id) from movimento m
           where m.cnpj = a.cnpj and m.dt between a.dt_ini and a.dt_fin
             and m.nfe_id is not null),
         (select count(*) from movimento m
           where m.cnpj = a.cnpj and m.dt between a.dt_ini and a.dt_fin)
    from erp_extrato_arquivo a
    left join erp_confronto_item(p_arquivo_id) i on true
   where a.id = p_arquivo_id
   group by a.cnpj, a.uf, a.deposito, a.dt_ini, a.dt_fin;
$$;
