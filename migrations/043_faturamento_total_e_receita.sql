-- 043 — Faturamento em duas medidas: total das notas e receita bruta.
--
-- O ERP da empresa deu R$ 741.643,84 de faturamento de SP em julho/2026 (sem
-- NFS-e); a auditoria, R$ 683.827,31. Nenhuma nota faltava. A diferenca era de
-- conceito, e decompos-se no centavo:
--
--   mercadoria (vProd - vDesc) ............ 683.827,31   o que a 040 somava
--   + IPI destacado ....................... 55.314,75
--   + frete, seguro e outras despesas ..... 2.501,78
--   = total das notas (vNF) ............... 741.643,84   o que o ERP soma
--
-- As duas medidas servem, para coisas diferentes:
--
--   TOTAL FATURADO  o que foi cobrado do cliente: a nota inteira, com IPI e
--                   ICMS-ST. E o numero do ERP.
--   RECEITA BRUTA   base de PIS, COFINS, IRPJ e CSLL: mercadoria, frete,
--                   seguro e outras despesas cobradas, SEM o IPI e o ICMS-ST,
--                   que sao tributos cobrados do comprador por conta do fisco.
--
-- E a 040 tinha um erro: deixava frete, seguro e outras despesas cobrados FORA
-- da receita. Eles compoem a receita bruta. A base dos tributos federais estava
-- subestimada em R$ 2.501,78 so em SP em julho.

drop function if exists faturamento_notas(date, date, text);
drop function if exists faturamento_periodo(date, date, text);
drop function if exists faturamento_linhas(date, date, text);

create function faturamento_linhas(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  nfe_id bigint, num_nf text, dt_emi date, cnpj text, contraparte text,
  cfop text, grupo text, sinal int, descricao text,
  valor numeric,        -- receita bruta: mercadoria + frete/seguro/outras - desconto
  valor_total numeric,  -- total faturado: receita + IPI + ICMS-ST (soma = vNF)
  ipi numeric, st numeric, vl_nf numeric
)
language sql stable as $$
  select n.id, n.num_nf, n.dt_emi,
         case f.lado when 'emitente' then n.emit_cnpj else n.dest_doc end,
         case f.lado when 'emitente' then n.dest_nome else n.emit_nome end,
         i.cfop, f.grupo, f.sinal, f.descricao,
         coalesce(i.v_prod,0) - coalesce(i.v_desc,0)
           + coalesce(i.v_frete,0) + coalesce(i.v_seg,0) + coalesce(i.v_outro,0),
         coalesce(i.v_prod,0) - coalesce(i.v_desc,0)
           + coalesce(i.v_frete,0) + coalesce(i.v_seg,0) + coalesce(i.v_outro,0)
           + coalesce(t.ipi_v,0) + coalesce(t.st_v,0) + coalesce(t.fcpst_v,0),
         coalesce(t.ipi_v,0), coalesce(t.st_v,0) + coalesce(t.fcpst_v,0),
         n.vl_nf
    from nfe n
    join nfe_item i on i.nfe_id = n.id
    join cfop_faturamento f on f.cfop = i.cfop
    left join nfe_item_imposto t on t.nfe_item_id = i.id
   where n.situacao = 'autorizada'
     and n.dt_emi between p_ini and p_fim
     and ( (f.lado = 'emitente'
            and n.emit_cnpj in (select e.cnpj from estabelecimento e)
            and (p_cnpj is null or n.emit_cnpj = p_cnpj))
        or (f.lado = 'destino'
            and n.dest_doc in (select e.cnpj from estabelecimento e)
            and (p_cnpj is null or n.dest_doc = p_cnpj)) )
     and not (p_cnpj is null
              and n.emit_cnpj in (select e.cnpj from estabelecimento e)
              and n.dest_doc  in (select e.cnpj from estabelecimento e));
$$;

create function faturamento_periodo(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  grupo text, sinal int, cfop text, descricao text,
  notas bigint, linhas bigint, valor numeric, valor_total numeric, ipi numeric, st numeric
)
language sql stable as $$
  select grupo, sinal, cfop, min(descricao),
         count(distinct nfe_id)::bigint, count(*)::bigint,
         round(sum(valor), 2), round(sum(valor_total), 2),
         round(sum(ipi), 2), round(sum(st), 2)
    from faturamento_linhas(p_ini, p_fim, p_cnpj)
   group by grupo, sinal, cfop
   order by case grupo when 'venda' then 1 when 'devolucao_venda' then 2
                       when 'entrega_futura_faturamento' then 3 else 4 end,
            8 desc;
$$;

create function faturamento_notas(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  nfe_id bigint, num_nf text, dt_emi date, contraparte text, cfops text,
  grupo text, sinal int, valor numeric, valor_total numeric, vl_nf numeric
)
language sql stable as $$
  select nfe_id, num_nf, dt_emi, min(contraparte),
         string_agg(distinct cfop, ', '), grupo, sinal,
         round(sum(valor), 2), round(sum(valor_total), 2), max(vl_nf)
    from faturamento_linhas(p_ini, p_fim, p_cnpj)
   group by nfe_id, num_nf, dt_emi, grupo, sinal
   order by dt_emi, num_nf;
$$;


-- Base dos federais passa a incluir frete, seguro e outras despesas cobradas.
create or replace function apuracao_federal_calculada(p_ini date, p_fim date)
returns table (rubrica text, valor numeric, detalhe text)
language sql stable as $$
  with est as (select cnpj from estabelecimento),
  linhas as (
    -- lida direto do item: religar a linha de faturamento ao item por CFOP e
    -- valor multiplicaria dois itens iguais da mesma nota
    select f.sinal,
           coalesce(i.v_prod,0) - coalesce(i.v_desc,0) + coalesce(i.v_frete,0)
             + coalesce(i.v_seg,0) + coalesce(i.v_outro,0) as valor,
           t.icms_v, t.pis_v, t.cofins_v, t.ibs_v, t.cbs_v
      from nfe n
      join nfe_item i on i.nfe_id = n.id
      join cfop_faturamento f on f.cfop = i.cfop
      left join nfe_item_imposto t on t.nfe_item_id = i.id
     where n.situacao = 'autorizada' and n.dt_emi between p_ini and p_fim
       and f.sinal <> 0
       and ((f.lado = 'emitente' and n.emit_cnpj in (select cnpj from est))
         or (f.lado = 'destino'  and n.dest_doc  in (select cnpj from est)))
       and not (n.emit_cnpj in (select cnpj from est) and n.dest_doc in (select cnpj from est))
  ), b as (
    select coalesce(sum(valor) filter (where sinal = 1), 0) receita,
           coalesce(sum(valor) filter (where sinal = -1), 0) devol,
           coalesce(sum(icms_v * sinal), 0) icms,
           coalesce(sum(pis_v * sinal), 0) pis_dest,
           coalesce(sum(cofins_v * sinal), 0) cofins_dest,
           coalesce(sum(ibs_v * sinal), 0) ibs, coalesce(sum(cbs_v * sinal), 0) cbs,
           count(*) filter (where pis_v is null) sem_imposto
      from linhas
  ), m as (
    select greatest(1, (extract(year from age(p_fim + 1, p_ini)) * 12
                        + extract(month from age(p_fim + 1, p_ini))))::int meses
  )
  select 'receita_bruta', receita, 'mercadoria, frete, seguro e outras despesas cobradas; sem IPI e ICMS-ST; sem as notas entre filiais' from b
  union all select 'devolucoes', devol, 'devolucao de venda' from b
  union all select 'base_pis_cofins', receita - devol, 'receita bruta menos devolucoes' from b
  union all select 'pis', round((receita - devol) * 0.0065, 2), '0,65% cumulativo' from b
  union all select 'cofins', round((receita - devol) * 0.03, 2), '3% cumulativo' from b
  union all select 'icms_na_base', icms, 'ICMS destacado nas vendas (Tema 69 do STF)' from b
  union all select 'pis_sem_icms', round((receita - devol - icms) * 0.0065, 2), 'PIS com o ICMS excluido da base' from b
  union all select 'cofins_sem_icms', round((receita - devol - icms) * 0.03, 2), 'COFINS com o ICMS excluido da base' from b
  union all select 'pis_destacado', pis_dest, 'PIS destacado nas notas de venda' from b
  union all select 'cofins_destacado', cofins_dest, 'COFINS destacado nas notas de venda' from b
  union all select 'base_irpj', round((receita - devol) * 0.08, 2), '8% da receita de revenda' from b
  union all select 'irpj', round((receita - devol) * 0.08 * 0.15
                     + greatest(0, (receita - devol) * 0.08 - 20000 * (select meses from m)) * 0.10, 2),
                   '15% + adicional de 10% acima de R$ 20.000/mes de base' from b
  union all select 'base_csll', round((receita - devol) * 0.12, 2), '12% da receita de revenda' from b
  union all select 'csll', round((receita - devol) * 0.12 * 0.09, 2), '9%' from b
  union all select 'ibs_destacado', ibs, 'IBS destacado (2026: fase de teste)' from b
  union all select 'cbs_destacado', cbs, 'CBS destacada (2026: fase de teste)' from b
  union all select 'linhas_sem_imposto', sem_imposto, 'linhas de venda sem impostos gravados — reimportar o XML' from b;
$$;
