-- 049 — NFS-e: servico entra no faturamento e na base dos federais.
--
-- O auditor levantou a hipotese de que a diferenca entre o painel do ERP e a
-- auditoria vem das notas de servico, que o faturamento da empresa soma e o
-- sistema nao lia. As NFS-e de SP de julho/2026 (20 notas, R$ 17.628,95,
-- assistencia tecnica) estavam em disco; as de SC e CE, nao.
--
-- Servico nao movimenta estoque. Entra:
--   · no faturamento, como grupo proprio ("servico");
--   · na base de PIS e COFINS (cumulativo), junto com a venda;
--   · na base presumida de IRPJ e CSLL com 32% — e nao os 8% e 12% da revenda.
-- O ISS e municipal: aparece destacado, informativo.
--
-- So o padrao nacional de NFS-e. Data de referencia: a competencia.

create table if not exists nfse_todos (
  id            bigserial primary key,
  trabalho_id   bigint not null default trabalho_atual()
                references trabalho(id) on delete cascade,
  chave text not null, numero text, c_stat text,
  situacao text not null default 'autorizada',
  dh_proc timestamptz, dh_emi timestamptz, d_compet date,
  prest_cnpj text, prest_nome text, toma_doc text, toma_nome text,
  c_trib_nac text, x_trib_nac text, descricao text, municipio text,
  v_serv numeric(18,2), v_bc numeric(18,2), p_aliq numeric(9,4),
  v_iss numeric(18,2), v_liq numeric(18,2), ret_iss text,
  nome_arquivo text, sha256 text, importado_por text,
  importado_em timestamptz not null default now()
);
create unique index if not exists ux_nfse_chave on nfse_todos (trabalho_id, chave);
comment on table nfse_todos is 'NFS-e (padrao nacional). Servico: faturamento, nao estoque.';
create or replace view nfse as
  select * from nfse_todos where trabalho_id = trabalho_atual();


create or replace function importar_nfse(p jsonb)
returns jsonb language plpgsql as $$
declare v_ja record; v_id bigint;
begin
  select id, sha256, numero, v_serv, prest_cnpj into v_ja from nfse where chave = p->>'chave';
  if v_ja.id is not null then
    if v_ja.sha256 = p->>'sha256'
       or (v_ja.numero = p->>'numero' and v_ja.prest_cnpj = p->>'prest_cnpj'
           and v_ja.v_serv = (p->>'v_serv')::numeric) then
      return jsonb_build_object('situacao', 'ja_importada', 'nfse_id', v_ja.id);
    end if;
    return jsonb_build_object('situacao', 'conflito', 'nfse_id', v_ja.id);
  end if;
  if not exists (select 1 from estabelecimento where cnpj = p->>'prest_cnpj') then
    return jsonb_build_object('situacao', 'fora_do_grupo');
  end if;
  insert into nfse (chave, numero, c_stat, situacao, dh_proc, dh_emi, d_compet,
         prest_cnpj, prest_nome, toma_doc, toma_nome, c_trib_nac, x_trib_nac,
         descricao, municipio, v_serv, v_bc, p_aliq, v_iss, v_liq, ret_iss,
         nome_arquivo, sha256, importado_por)
  values (p->>'chave', p->>'numero', p->>'c_stat',
          case when p->>'c_stat' = '100' then 'autorizada' else 'cstat_' || coalesce(p->>'c_stat','?') end,
          nullif(p->>'dh_proc','')::timestamptz, nullif(p->>'dh_emi','')::timestamptz,
          nullif(p->>'d_compet','')::date, p->>'prest_cnpj', p->>'prest_nome',
          p->>'toma_doc', p->>'toma_nome', p->>'c_trib_nac', p->>'x_trib_nac',
          p->>'descricao', p->>'municipio', _n(p,'v_serv'), _n(p,'v_bc'), _n(p,'p_aliq'),
          _n(p,'v_iss'), _n(p,'v_liq'), p->>'ret_iss',
          p->>'nome_arquivo', p->>'sha256', p->>'importado_por')
  returning id into v_id;
  return jsonb_build_object('situacao', 'importada', 'nfse_id', v_id);
end $$;


-- =========================================== faturamento: NF-e + NFS-e
-- As linhas de NFS-e usam nfe_id NEGATIVO (-id da NFS-e): as duas tabelas tem
-- sequencias proprias, e quem agrupa por nota (faturamento_notas) nao pode
-- misturar a NF-e 12 com a NFS-e 12.
create or replace function faturamento_linhas(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  nfe_id bigint, num_nf text, dt_emi date, cnpj text, contraparte text,
  cfop text, grupo text, sinal int, descricao text,
  valor numeric, valor_total numeric, ipi numeric, st numeric, vl_nf numeric
)
language sql stable as $$
  select n.id, n.num_nf, n.dt_emi,
         case f.lado when 'emitente' then n.emit_cnpj else n.dest_doc end,
         case f.lado when 'emitente' then n.dest_nome else n.emit_nome end,
         i.cfop, f.grupo, f.sinal, f.descricao,
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
   order by case grupo when 'venda' then 1 when 'servico' then 2 when 'devolucao_venda' then 3
                       when 'entrega_futura_faturamento' then 4 else 5 end,
            8 desc;
$$;

-- A receita contabil de VENDA se compara com a venda das notas, sem servico.
create or replace function confronto_receita(p_ini date, p_fim date)
returns table (mes date, receita_contabil numeric, faturamento_notas numeric, diferenca numeric)
language sql stable as $$
  with rc as (
    select m.mes, sum(m.valor) v
      from ecd_movimento_resultado(p_ini, p_fim) m
     where m.cod_cta in (select cod_cta from ecd_contas_receita_venda())
     group by 1
  ), fn as (
    select rc.mes,
           (select coalesce(sum(r.valor), 0)
              from faturamento_periodo(rc.mes, (rc.mes + interval '1 month - 1 day')::date, null) r
             where r.sinal = 1 and r.grupo = 'venda') v
      from rc
  )
  select rc.mes, round(rc.v, 2), round(fn.v, 2), round(rc.v - fn.v, 2)
    from rc join fn using (mes) order by rc.mes;
$$;


-- =============================================== federais com servico
create or replace function apuracao_federal_calculada(p_ini date, p_fim date)
returns table (rubrica text, valor numeric, detalhe text)
language sql stable as $$
  with est as (select cnpj from estabelecimento),
  linhas as (
    select f.sinal,
           case when nfe_complemento_de_imposto(n.id) then 0 else
             coalesce(i.v_prod,0) - coalesce(i.v_desc,0) + coalesce(i.v_frete,0)
             + coalesce(i.v_seg,0) + coalesce(i.v_outro,0) end as valor,
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
  ), serv as (
    select coalesce(sum(v_serv), 0) v, coalesce(sum(v_iss), 0) iss,
           coalesce(sum(v_iss) filter (where ret_iss in ('2','3')), 0) iss_ret, count(*) n
      from nfse
     where situacao = 'autorizada' and d_compet between p_ini and p_fim
       and prest_cnpj in (select cnpj from est)
       and coalesce(toma_doc,'') not in (select cnpj from est)
  ), b as (
    select coalesce(sum(valor) filter (where sinal = 1), 0) vendas,
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
    select *, vendas - devol + servicos as base,
           (vendas - devol) * 0.08 + servicos * 0.32 as base_ir,
           (vendas - devol) * 0.12 + servicos * 0.32 as base_cs
      from b
  ), m as (
    select greatest(1, (extract(year from age(p_fim + 1, p_ini)) * 12
                        + extract(month from age(p_fim + 1, p_ini))))::int meses
  )
  select 'receita_bruta', vendas + servicos, 'venda de mercadoria (sem IPI e ICMS-ST) + servicos (NFS-e); sem as notas entre filiais' from c
  union all select 'receita_vendas', vendas, 'mercadoria, frete, seguro e outras despesas cobradas' from c
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
  union all select 'base_irpj', round(base_ir, 2), '8% da revenda + 32% dos servicos' from c
  union all select 'irpj', round(base_ir * 0.15 + greatest(0, base_ir - 20000 * (select meses from m)) * 0.10, 2),
                   '15% + adicional de 10% acima de R$ 20.000/mes de base' from c
  union all select 'base_csll', round(base_cs, 2), '12% da revenda + 32% dos servicos' from c
  union all select 'csll', round(base_cs * 0.09, 2), '9%' from c
  union all select 'iss_destacado', iss, 'ISS das NFS-e (municipal) · retido pelo tomador: ' || iss_ret from c
  union all select 'ibs_destacado', ibs, 'IBS destacado (2026: fase de teste)' from c
  union all select 'cbs_destacado', cbs, 'CBS destacada (2026: fase de teste)' from c
  union all select 'linhas_sem_imposto', sem_imposto, 'linhas de venda sem impostos gravados — reimportar o XML' from c;
$$;
