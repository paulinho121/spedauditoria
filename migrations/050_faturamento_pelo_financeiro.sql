-- 050 — Faturamento e o que movimenta o financeiro.
--
-- Regra do auditor, confirmada nota a nota pelo grupo de pagamento do XML
-- (tPag 90 = "sem pagamento"):
--
--   entrega futura  o FATURAMENTO (5922/6922) tem pagamento e conta;
--                   a REMESSA (5117/6117) so movimenta estoque — tPag 90.
--                   A 040 fazia o contrario.
--   locacao         tem pagamento (boleto, duplicatas, "operacao de locacao
--                   conforme contrato") e conta.
--   comodato        tPag 90, sem duplicata: nao conta.
--
-- Locacao e comodato usam o MESMO CFOP (5908/6908). O que os separa e a
-- natureza da operacao; a regra vale so para esses dois CFOPs.
--
-- Locacao de bem movel e receita: entra na base de PIS/COFINS e na presumida
-- de IRPJ/CSLL com 32%, como servico. ICMS nao incide (as notas registram).
--
-- Em julho/2026 as saidas com pagamento somam R$ 1.444.181,29; o painel do
-- ERP, R$ 1.450.828,62. A sobra de R$ 6.647,33 nao corresponde a nenhuma nota
-- nem combinacao de ajustes conhecidos no sistema.

alter table cfop_faturamento drop constraint if exists cfop_faturamento_grupo_check;
alter table cfop_faturamento add constraint cfop_faturamento_grupo_check check (grupo in
  ('venda', 'devolucao_venda', 'entrega_futura_faturamento', 'entrega_futura_remessa',
   'remessa_locacao_comodato', 'locacao', 'comodato'));

update cfop_faturamento set sinal = 1,
       descricao = case cfop when '5922' then 'Venda para entrega futura — faturamento'
                             else 'Venda para entrega futura — faturamento, outro estado' end,
       observacao = 'Conta: e a nota que movimenta o financeiro. A remessa (5117/6117) so movimenta estoque'
 where cfop in ('5922', '6922') and lado = 'emitente';

update cfop_faturamento set grupo = 'entrega_futura_remessa', sinal = 0,
       observacao = 'Nao conta: so movimenta estoque. O financeiro e a nota de faturamento (5922/6922)'
 where cfop in ('5117', '6117') and lado = 'emitente';


-- Regra de faturamento de uma linha: a do CFOP, com a excecao de 5908/6908,
-- que se decide pela natureza da operacao.
create or replace function regra_faturamento(p_cfop text, p_lado text, p_nat text)
returns table (grupo text, sinal int, descricao text)
language sql stable as $$
  select case when f.cfop in ('5908', '6908') and upper(coalesce(p_nat,'')) like '%LOCA%'
                   and upper(coalesce(p_nat,'')) not like '%COMODATO%' then 'locacao'
              when f.cfop in ('5908', '6908') then 'comodato'
              else f.grupo end,
         case when f.cfop in ('5908', '6908') and upper(coalesce(p_nat,'')) like '%LOCA%'
                   and upper(coalesce(p_nat,'')) not like '%COMODATO%' then 1
              when f.cfop in ('5908', '6908') then 0
              else f.sinal end,
         case when f.cfop in ('5908', '6908') and upper(coalesce(p_nat,'')) like '%LOCA%'
                   and upper(coalesce(p_nat,'')) not like '%COMODATO%' then 'Locacao de bem movel'
              when f.cfop in ('5908', '6908') then 'Remessa em comodato'
              else f.descricao end
    from cfop_faturamento f
   where f.cfop = p_cfop and f.lado = p_lado;
$$;
comment on function regra_faturamento(text, text, text) is
  'Grupo e sinal de faturamento de uma linha. 5908/6908: locacao conta, comodato nao.';


create or replace function faturamento_linhas(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  nfe_id bigint, num_nf text, dt_emi date, cnpj text, contraparte text,
  cfop text, grupo text, sinal int, descricao text,
  valor numeric, valor_total numeric, ipi numeric, st numeric, vl_nf numeric
)
language sql stable as $$
  select n.id, n.num_nf, n.dt_emi,
         case l.lado when 'emitente' then n.emit_cnpj else n.dest_doc end,
         case l.lado when 'emitente' then n.dest_nome else n.emit_nome end,
         i.cfop, r.grupo, r.sinal, r.descricao,
         case when nfe_complemento_de_imposto(n.id) then 0
              else coalesce(i.v_prod,0) - coalesce(i.v_desc,0)
                   + coalesce(i.v_frete,0) + coalesce(i.v_seg,0) + coalesce(i.v_outro,0)
         end,
         coalesce(i.v_prod,0) - coalesce(i.v_desc,0)
           + coalesce(i.v_frete,0) + coalesce(i.v_seg,0) + coalesce(i.v_outro,0)
           + coalesce(t.ipi_v,0) + coalesce(t.st_v,0) + coalesce(t.fcpst_v,0),
         coalesce(t.ipi_v,0), coalesce(t.st_v,0) + coalesce(t.fcpst_v,0),
         n.vl_nf
    from nfe n
    join nfe_item i on i.nfe_id = n.id
    cross join (values ('emitente'), ('destino')) as l(lado)
    join lateral regra_faturamento(i.cfop, l.lado, n.nat_op) r on true
    left join nfe_item_imposto t on t.nfe_item_id = i.id
   where n.situacao = 'autorizada'
     and n.dt_emi between p_ini and p_fim
     and ( (l.lado = 'emitente'
            and n.emit_cnpj in (select e.cnpj from estabelecimento e)
            and (p_cnpj is null or n.emit_cnpj = p_cnpj))
        or (l.lado = 'destino'
            and n.dest_doc in (select e.cnpj from estabelecimento e)
            and (p_cnpj is null or n.dest_doc = p_cnpj)) )
     and not (p_cnpj is null
              and n.emit_cnpj in (select e.cnpj from estabelecimento e)
              and n.dest_doc  in (select e.cnpj from estabelecimento e))
  union all
  select -s.id, 'NFS-e ' || s.numero, s.d_compet, s.prest_cnpj, s.toma_nome,
         'SERV', 'servico', 1, coalesce(s.x_trib_nac, 'Servico'),
         s.v_serv, s.v_serv, 0, 0, s.v_serv
    from nfse s
   where s.situacao = 'autorizada'
     and s.d_compet between p_ini and p_fim
     and s.prest_cnpj in (select e.cnpj from estabelecimento e)
     and (p_cnpj is null or s.prest_cnpj = p_cnpj)
     and not (p_cnpj is null and coalesce(s.toma_doc,'') in (select e.cnpj from estabelecimento e));
$$;

create or replace function faturamento_periodo(p_ini date, p_fim date, p_cnpj text default null)
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
   order by case grupo when 'venda' then 1 when 'entrega_futura_faturamento' then 2
                       when 'locacao' then 3 when 'servico' then 4
                       when 'devolucao_venda' then 5 else 6 end,
            8 desc;
$$;


-- Federais: locacao e servico a 32%; revenda (inclui o faturamento de entrega
-- futura) a 8% e 12%.
create or replace function apuracao_federal_calculada(p_ini date, p_fim date)
returns table (rubrica text, valor numeric, detalhe text)
language sql stable as $$
  with est as (select cnpj from estabelecimento),
  linhas as (
    select r.sinal, r.grupo,
           case when nfe_complemento_de_imposto(n.id) then 0 else
             coalesce(i.v_prod,0) - coalesce(i.v_desc,0) + coalesce(i.v_frete,0)
             + coalesce(i.v_seg,0) + coalesce(i.v_outro,0) end as valor,
           t.icms_v, t.pis_v, t.cofins_v, t.ibs_v, t.cbs_v
      from nfe n
      join nfe_item i on i.nfe_id = n.id
      cross join (values ('emitente'), ('destino')) as l(lado)
      join lateral regra_faturamento(i.cfop, l.lado, n.nat_op) r on true
      left join nfe_item_imposto t on t.nfe_item_id = i.id
     where n.situacao = 'autorizada' and n.dt_emi between p_ini and p_fim
       and r.sinal <> 0
       and ((l.lado = 'emitente' and n.emit_cnpj in (select cnpj from est))
         or (l.lado = 'destino'  and n.dest_doc  in (select cnpj from est)))
       and not (n.emit_cnpj in (select cnpj from est) and n.dest_doc in (select cnpj from est))
  ), serv as (
    select coalesce(sum(v_serv), 0) v, coalesce(sum(v_iss), 0) iss,
           coalesce(sum(v_iss) filter (where ret_iss in ('2','3')), 0) iss_ret, count(*) n
      from nfse
     where situacao = 'autorizada' and d_compet between p_ini and p_fim
       and prest_cnpj in (select cnpj from est)
       and coalesce(toma_doc,'') not in (select cnpj from est)
  ), b as (
    select coalesce(sum(valor) filter (where sinal = 1 and grupo <> 'locacao'), 0) vendas,
           coalesce(sum(valor) filter (where grupo = 'locacao'), 0) locacao,
           coalesce(sum(valor) filter (where sinal = -1), 0) devol,
           coalesce(sum(icms_v * sinal), 0) icms,
           coalesce(sum(pis_v * sinal), 0) pis_dest,
           coalesce(sum(cofins_v * sinal), 0) cofins_dest,
           coalesce(sum(ibs_v * sinal), 0) ibs, coalesce(sum(cbs_v * sinal), 0) cbs,
           count(*) filter (where pis_v is null) sem_imposto,
           (select v from serv) servicos, (select iss from serv) iss,
           (select iss_ret from serv) iss_ret, (select n from serv) n_serv
      from linhas
  ), c as (
    select *, vendas - devol + locacao + servicos as base,
           (vendas - devol) * 0.08 + (locacao + servicos) * 0.32 as base_ir,
           (vendas - devol) * 0.12 + (locacao + servicos) * 0.32 as base_cs
      from b
  ), m as (
    select greatest(1, (extract(year from age(p_fim + 1, p_ini)) * 12
                        + extract(month from age(p_fim + 1, p_ini))))::int meses
  )
  select 'receita_bruta', vendas + locacao + servicos, 'venda + locacao + servicos; sem IPI e ICMS-ST; sem as notas entre filiais' from c
  union all select 'receita_vendas', vendas, 'mercadoria (inclui o faturamento de entrega futura), frete, seguro e outras despesas' from c
  union all select 'receita_locacao', locacao, 'locacao de bem movel (5908/6908 com natureza de locacao)' from c
  union all select 'receita_servicos', servicos, n_serv || ' NFS-e' from c
  union all select 'devolucoes', devol, 'devolucao de venda' from c
  union all select 'base_pis_cofins', base, 'receita bruta menos devolucoes' from c
  union all select 'pis', round(base * 0.0065, 2), '0,65% cumulativo' from c
  union all select 'cofins', round(base * 0.03, 2), '3% cumulativo' from c
  union all select 'icms_na_base', icms, 'ICMS destacado nas vendas (Tema 69 do STF)' from c
  union all select 'pis_sem_icms', round((base - icms) * 0.0065, 2), 'PIS com o ICMS excluido da base' from c
  union all select 'cofins_sem_icms', round((base - icms) * 0.03, 2), 'COFINS com o ICMS excluido da base' from c
  union all select 'pis_destacado', pis_dest, 'PIS destacado nas notas de venda' from c
  union all select 'cofins_destacado', cofins_dest, 'COFINS destacado nas notas de venda' from c
  union all select 'base_irpj', round(base_ir, 2), '8% da revenda + 32% de locacao e servicos' from c
  union all select 'irpj', round(base_ir * 0.15 + greatest(0, base_ir - 20000 * (select meses from m)) * 0.10, 2),
                   '15% + adicional de 10% acima de R$ 20.000/mes de base' from c
  union all select 'base_csll', round(base_cs, 2), '12% da revenda + 32% de locacao e servicos' from c
  union all select 'csll', round(base_cs * 0.09, 2), '9%' from c
  union all select 'iss_destacado', iss, 'ISS das NFS-e (municipal) · retido pelo tomador: ' || iss_ret from c
  union all select 'ibs_destacado', ibs, 'IBS destacado (2026: fase de teste)' from c
  union all select 'cbs_destacado', cbs, 'CBS destacada (2026: fase de teste)' from c
  union all select 'linhas_sem_imposto', sem_imposto, 'linhas de venda sem impostos gravados — reimportar o XML' from c;
$$;
