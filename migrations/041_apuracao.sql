-- 041 — Apuracao fiscal: o recalculo pelos XML e o declarado na EFD.
--
-- Objetivo definido pelo auditor: auditar o declarado. Duas pontas:
--
--   RECALCULADO  pelos impostos destacados nas NF-e, linha a linha.
--   DECLARADO    no bloco E da EFD ICMS/IPI (E110, E210, E310, E520).
--
-- E um terceiro confronto, que so precisa da EFD: a apuracao declarada bate
-- com a soma dos documentos escriturados na mesma EFD (C190)?
--
-- Regime das filiais, lido das proprias notas: ICMS normal (CRT 3); PIS e
-- COFINS a 0,65% e 3% sem credito — cumulativo, portanto Lucro Presumido.
-- ICMS, ST, DIFAL e IPI apuram por ESTABELECIMENTO. PIS, COFINS, IRPJ e CSLL
-- apuram pela EMPRESA (CNPJ raiz), consolidando as filiais.

-- =============================================================== tabelas
create table if not exists nfe_item_imposto_todos (
  nfe_item_id   bigint primary key references nfe_item_todos(id) on delete cascade,
  trabalho_id   bigint not null default trabalho_atual()
                references trabalho(id) on delete cascade,
  icms_grupo text, icms_orig text, icms_cst text,
  icms_vbc numeric(18,2), icms_p numeric(9,4), icms_v numeric(18,2), icms_deson numeric(18,2),
  st_vbc numeric(18,2), st_p numeric(9,4), st_v numeric(18,2), fcpst_v numeric(18,2),
  st_ret_v numeric(18,2),
  difal_vbc numeric(18,2), difal_p_dest numeric(9,4), difal_p_inter numeric(9,4),
  difal_v numeric(18,2), difal_fcp_v numeric(18,2), difal_remet_v numeric(18,2),
  ipi_cst text, ipi_vbc numeric(18,2), ipi_p numeric(9,4), ipi_v numeric(18,2),
  ii_v numeric(18,2),
  pis_cst text, pis_vbc numeric(18,2), pis_p numeric(9,4), pis_v numeric(18,2),
  cofins_cst text, cofins_vbc numeric(18,2), cofins_p numeric(9,4), cofins_v numeric(18,2),
  ibscbs_cst text, ibs_v numeric(18,2), cbs_v numeric(18,2)
);
comment on table nfe_item_imposto_todos is
  'Impostos DESTACADOS em cada linha da NF-e, como a nota os trouxe. Nada aqui '
  'e recalculado.';
create or replace view nfe_item_imposto as
  select * from nfe_item_imposto_todos where trabalho_id = trabalho_atual();

create table if not exists doc_imposto_todos (
  doc_id      bigint primary key references doc_fiscal_todos(id) on delete cascade,
  trabalho_id bigint not null default trabalho_atual()
              references trabalho(id) on delete cascade,
  vl_merc numeric(18,2), vl_desc numeric(18,2),
  vl_bc_icms numeric(18,2), vl_icms numeric(18,2),
  vl_bc_st numeric(18,2), vl_st numeric(18,2),
  vl_ipi numeric(18,2), vl_pis numeric(18,2), vl_cofins numeric(18,2)
);
comment on table doc_imposto_todos is 'Impostos do C100: o que a empresa escriturou por documento.';
create or replace view doc_imposto as
  select * from doc_imposto_todos where trabalho_id = trabalho_atual();

create table if not exists doc_analitico_todos (
  id          bigserial primary key,
  trabalho_id bigint not null default trabalho_atual()
              references trabalho(id) on delete cascade,
  arquivo_id  bigint not null,
  doc_id      bigint references doc_fiscal_todos(id) on delete cascade,
  cst_icms text, cfop text, aliq numeric(9,4),
  vl_opr numeric(18,2), vl_bc_icms numeric(18,2), vl_icms numeric(18,2),
  vl_bc_st numeric(18,2), vl_st numeric(18,2), vl_red_bc numeric(18,2),
  vl_ipi numeric(18,2), linha_arquivo int
);
create index if not exists ix_doc_analitico_arq on doc_analitico_todos (arquivo_id);
comment on table doc_analitico_todos is
  'C190: resumo por CST, CFOP e aliquota de cada documento. E o que alimenta a '
  'apuracao — existe mesmo no perfil B, que dispensa o C170.';
create or replace view doc_analitico as
  select * from doc_analitico_todos where trabalho_id = trabalho_atual();

create table if not exists efd_apuracao_todos (
  id          bigserial primary key,
  trabalho_id bigint not null default trabalho_atual()
              references trabalho(id) on delete cascade,
  arquivo_id  bigint not null,
  cnpj text, dt_ini date, dt_fin date,
  tributo text not null check (tributo in ('icms','st','difal','fcp','ipi')),
  uf text,
  debitos numeric(18,2), ajustes_debito_doc numeric(18,2), ajustes_debito numeric(18,2),
  estornos_credito numeric(18,2),
  creditos numeric(18,2), ajustes_credito_doc numeric(18,2), ajustes_credito numeric(18,2),
  estornos_debito numeric(18,2),
  saldo_credor_anterior numeric(18,2), saldo_apurado numeric(18,2),
  deducoes numeric(18,2), a_recolher numeric(18,2),
  saldo_credor_transportar numeric(18,2), debitos_especiais numeric(18,2),
  linha_arquivo int
);
create index if not exists ix_efd_apuracao_arq on efd_apuracao_todos (arquivo_id);
comment on table efd_apuracao_todos is 'Bloco E da EFD: a apuracao que a empresa DECLAROU.';
create or replace view efd_apuracao as
  select * from efd_apuracao_todos where trabalho_id = trabalho_atual();


-- ========================================================== gravacao: NF-e
create or replace function _n(p jsonb, k text)
returns numeric language sql immutable as $$
  select nullif(p->>k, '')::numeric;
$$;

create or replace function gravar_impostos_nfe(p jsonb)
returns int language plpgsql as $$
declare v int;
begin
  insert into nfe_item_imposto_todos (nfe_item_id,
    icms_grupo, icms_orig, icms_cst, icms_vbc, icms_p, icms_v, icms_deson,
    st_vbc, st_p, st_v, fcpst_v, st_ret_v,
    difal_vbc, difal_p_dest, difal_p_inter, difal_v, difal_fcp_v, difal_remet_v,
    ipi_cst, ipi_vbc, ipi_p, ipi_v, ii_v,
    pis_cst, pis_vbc, pis_p, pis_v, cofins_cst, cofins_vbc, cofins_p, cofins_v,
    ibscbs_cst, ibs_v, cbs_v)
  select i.id,
    t->>'icms_grupo', t->>'icms_orig', t->>'icms_cst', _n(t,'icms_vbc'), _n(t,'icms_p'),
    _n(t,'icms_v'), _n(t,'icms_deson'),
    _n(t,'st_vbc'), _n(t,'st_p'), _n(t,'st_v'), _n(t,'fcpst_v'), _n(t,'st_ret_v'),
    _n(t,'difal_vbc'), _n(t,'difal_p_dest'), _n(t,'difal_p_inter'), _n(t,'difal_v'),
    _n(t,'difal_fcp_v'), _n(t,'difal_remet_v'),
    t->>'ipi_cst', _n(t,'ipi_vbc'), _n(t,'ipi_p'), _n(t,'ipi_v'), _n(t,'ii_v'),
    t->>'pis_cst', _n(t,'pis_vbc'), _n(t,'pis_p'), _n(t,'pis_v'),
    t->>'cofins_cst', _n(t,'cofins_vbc'), _n(t,'cofins_p'), _n(t,'cofins_v'),
    t->>'ibscbs_cst', _n(t,'ibs_v'), _n(t,'cbs_v')
  from jsonb_array_elements(coalesce(p->'itens','[]')) it
  cross join lateral (select coalesce(it->'impostos', '{}'::jsonb) as t) x
  join nfe n on n.chave = p->>'chave'
  join nfe_item i on i.nfe_id = n.id and i.n_item = (it->>'n_item')::int
  where t <> '{}'::jsonb
  on conflict (nfe_item_id) do nothing;
  get diagnostics v = row_count;
  return v;
end $$;

-- O importador vira base; o nome original chama a base e grava os impostos.
-- Reimportar um arquivo que ja estava no banco preenche os impostos que ainda
-- nao tinha: e assim que as notas anteriores a esta migracao ganham impostos.
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'importar_nfe_base') then
    alter function importar_nfe(jsonb) rename to importar_nfe_base;
  end if;
end $$;

create or replace function importar_nfe(p jsonb)
returns jsonb language plpgsql as $$
declare r jsonb; k int := 0;
begin
  r := importar_nfe_base(p);
  if r->>'situacao' in ('importada', 'ja_importada') then
    k := gravar_impostos_nfe(p);
  end if;
  return r || jsonb_build_object('impostos_gravados', k);
end $$;


-- =========================================================== gravacao: EFD
create or replace function gravar_apuracao_efd(p_arquivo_id bigint, p jsonb)
returns int language plpgsql as $$
declare v_arq record; v int := 0; k int;
begin
  select id, cnpj, dt_ini, dt_fin into v_arq from sped_arquivo where id = p_arquivo_id;
  if v_arq.id is null then return 0; end if;

  -- Derivado do arquivo, que continua guardado: refazer e seguro.
  delete from efd_apuracao where arquivo_id = v_arq.id;
  delete from doc_analitico where arquivo_id = v_arq.id;
  delete from doc_imposto d using doc_fiscal f
   where f.id = d.doc_id and f.arquivo_id = v_arq.id;

  insert into efd_apuracao_todos (arquivo_id, cnpj, dt_ini, dt_fin, tributo, uf,
    debitos, ajustes_debito_doc, ajustes_debito, estornos_credito,
    creditos, ajustes_credito_doc, ajustes_credito, estornos_debito,
    saldo_credor_anterior, saldo_apurado, deducoes, a_recolher,
    saldo_credor_transportar, debitos_especiais, linha_arquivo)
  select v_arq.id, v_arq.cnpj, v_arq.dt_ini, v_arq.dt_fin, a->>'tributo', a->>'uf',
    coalesce(_n(a,'debitos'),0), coalesce(_n(a,'ajustes_debito_doc'),0),
    coalesce(_n(a,'ajustes_debito'),0), coalesce(_n(a,'estornos_credito'),0),
    coalesce(_n(a,'creditos'),0), coalesce(_n(a,'ajustes_credito_doc'),0),
    coalesce(_n(a,'ajustes_credito'),0), coalesce(_n(a,'estornos_debito'),0),
    coalesce(_n(a,'saldo_credor_anterior'),0), coalesce(_n(a,'saldo_apurado'),0),
    coalesce(_n(a,'deducoes'),0), coalesce(_n(a,'a_recolher'),0),
    coalesce(_n(a,'saldo_credor_transportar'),0), coalesce(_n(a,'debitos_especiais'),0),
    (a->>'linha')::int
  from jsonb_array_elements(coalesce(p->'apuracao','[]')) a;
  get diagnostics k = row_count; v := v + k;

  insert into doc_imposto_todos (doc_id, vl_merc, vl_desc, vl_bc_icms, vl_icms,
    vl_bc_st, vl_st, vl_ipi, vl_pis, vl_cofins)
  select f.id, _n(d->'impostos','vl_merc'), _n(d->'impostos','vl_desc'),
    _n(d->'impostos','vl_bc_icms'), _n(d->'impostos','vl_icms'),
    _n(d->'impostos','vl_bc_st'), _n(d->'impostos','vl_st'),
    _n(d->'impostos','vl_ipi'), _n(d->'impostos','vl_pis'), _n(d->'impostos','vl_cofins')
  from jsonb_array_elements(coalesce(p->'documentos','[]')) d
  join doc_fiscal f on f.arquivo_id = v_arq.id and f.linha_arquivo = (d->>'linha')::int
  where d ? 'impostos'
  on conflict (doc_id) do nothing;
  get diagnostics k = row_count; v := v + k;

  insert into doc_analitico_todos (arquivo_id, doc_id, cst_icms, cfop, aliq, vl_opr,
    vl_bc_icms, vl_icms, vl_bc_st, vl_st, vl_red_bc, vl_ipi, linha_arquivo)
  select v_arq.id, f.id, c->>'cst_icms', c->>'cfop', _n(c,'aliq'), _n(c,'vl_opr'),
    _n(c,'vl_bc_icms'), _n(c,'vl_icms'), _n(c,'vl_bc_st'), _n(c,'vl_st'),
    _n(c,'vl_red_bc'), _n(c,'vl_ipi'), (c->>'linha')::int
  from jsonb_array_elements(coalesce(p->'documentos','[]')) d
  join doc_fiscal f on f.arquivo_id = v_arq.id and f.linha_arquivo = (d->>'linha')::int
  cross join lateral jsonb_array_elements(coalesce(d->'analitico','[]')) c;
  get diagnostics k = row_count; v := v + k;
  return v;
end $$;

do $$ begin
  if not exists (select 1 from pg_proc where proname = 'importar_efd_base') then
    alter function importar_efd(jsonb) rename to importar_efd_base;
  end if;
end $$;

create or replace function importar_efd(p jsonb)
returns jsonb language plpgsql as $$
declare r jsonb; k int := 0;
begin
  r := importar_efd_base(p);
  if r ? 'arquivo_id' then
    k := gravar_apuracao_efd((r->>'arquivo_id')::bigint, p);
  end if;
  return r || jsonb_build_object('apuracao_gravada', k);
end $$;


-- ======================================================= recalculo pelo XML
-- ICMS, ST, DIFAL e IPI de UM estabelecimento.
--
--   DEBITO  imposto destacado nas notas de SAIDA que a filial emitiu (tpNF 1).
--   CREDITO imposto destacado nas linhas que ENTRARAM NO ESTOQUE da filial —
--           compra, transferencia recebida, importacao, devolucao de venda.
--           O criterio e o movimento de estoque: e ele que separa mercadoria
--           (da credito) de uso e consumo (nao da). Por isso credito depende
--           do de-para: entrada sem de-para nao gerou movimento.
--   CREDITO PENDENTE informativo: ICMS destacado em entrada de mercadoria
--           parada no de-para. Vira credito quando o de-para for confirmado.
--
-- ST e DIFAL apuram por UF de DESTINO da mercadoria.
create or replace function apuracao_calculada(p_ini date, p_fim date, p_cnpj text)
returns table (tributo text, uf text, rubrica text, valor numeric, linhas bigint, notas bigint)
language sql stable as $$
  with saida as (
    select n.id nfe_id, n.dest_uf, t.*
      from nfe n
      join nfe_item i on i.nfe_id = n.id
      join nfe_item_imposto t on t.nfe_item_id = i.id
     where n.emit_cnpj = p_cnpj and n.tp_nf = '1' and n.situacao = 'autorizada'
       and n.dt_emi between p_ini and p_fim
  ), entrada as (
    select distinct on (i.id) n.id nfe_id, t.*
      from movimento m
      join nfe n on n.id = m.nfe_id
      join nfe_item i on i.id = m.nfe_item_id
      join nfe_item_imposto t on t.nfe_item_id = i.id
     where m.cnpj = p_cnpj and m.efeito = 'soma' and m.origem = 'nfe'
       and n.dt_emi between p_ini and p_fim
  ), pendente as (
    select n.id nfe_id, t.*
      from nfe n
      join nfe_item i on i.nfe_id = n.id
      join nfe_item_imposto t on t.nfe_item_id = i.id
     where n.dest_doc = p_cnpj and n.situacao = 'autorizada'
       and n.dt_emi between p_ini and p_fim
       and not exists (select 1 from movimento m where m.nfe_item_id = i.id and m.cnpj = p_cnpj)
       and exists (select 1 from item_pendente ip
                    where ip.cnpj = p_cnpj and ip.c_prod_externo = i.c_prod
                      and coalesce(ip.parceiro_doc,'') = coalesce(n.emit_cnpj,'')
                      and ip.status = 'aberto')
  ), uf as (select coalesce((select e.uf from estabelecimento e where e.cnpj = p_cnpj), '') u)
  select 'icms', (select u from uf), 'debito', coalesce(sum(icms_v),0), count(*) filter (where icms_v > 0), count(distinct nfe_id) filter (where icms_v > 0) from saida
  union all
  select 'icms', (select u from uf), 'credito', coalesce(sum(icms_v),0), count(*) filter (where icms_v > 0), count(distinct nfe_id) filter (where icms_v > 0) from entrada
  union all
  select 'icms', (select u from uf), 'credito_pendente', coalesce(sum(icms_v),0), count(*) filter (where icms_v > 0), count(distinct nfe_id) filter (where icms_v > 0) from pendente
  union all
  select 'st', dest_uf, 'debito', sum(st_v), count(*), count(distinct nfe_id)
    from saida where coalesce(st_v,0) > 0 group by dest_uf
  union all
  select 'st', dest_uf, 'debito_fcp', sum(fcpst_v), count(*), count(distinct nfe_id)
    from saida where coalesce(fcpst_v,0) > 0 group by dest_uf
  union all
  select 'difal', dest_uf, 'debito', sum(difal_v), count(*), count(distinct nfe_id)
    from saida where coalesce(difal_v,0) > 0 group by dest_uf
  union all
  select 'fcp', dest_uf, 'debito', sum(difal_fcp_v), count(*), count(distinct nfe_id)
    from saida where coalesce(difal_fcp_v,0) > 0 group by dest_uf
  union all
  select 'ipi', (select u from uf), 'debito', coalesce(sum(ipi_v),0), count(*) filter (where ipi_v > 0), count(distinct nfe_id) filter (where ipi_v > 0) from saida
  union all
  select 'ipi', (select u from uf), 'credito', coalesce(sum(ipi_v),0), count(*) filter (where ipi_v > 0), count(distinct nfe_id) filter (where ipi_v > 0) from entrada;
$$;


-- Tributos federais: pela EMPRESA, somando as filiais e deixando fora o que
-- circula entre elas. Lucro Presumido, regime cumulativo.
--
-- Base de PIS/COFINS: receita de venda menos devolucoes. A exclusao do ICMS
-- destacado (Tema 69 do STF) vem calculada ao lado, nao aplicada: e uma
-- escolha da empresa, e o que se audita e se ela fez o que declarou.
--
-- IRPJ e CSLL presumidos apuram por TRIMESTRE. O mes aqui e uma previa — a
-- base e 8% (IRPJ) e 12% (CSLL) da receita de revenda; o adicional de 10% do
-- IRPJ incide sobre o que passar de R$ 20.000 por mes de base.
create or replace function apuracao_federal_calculada(p_ini date, p_fim date)
returns table (rubrica text, valor numeric, detalhe text)
language sql stable as $$
  -- Mesma regra de faturamento_linhas (consolidado, sem as notas entre
  -- filiais), mas lida direto do item: religar a linha de faturamento ao item
  -- por CFOP e valor multiplicaria dois itens iguais da mesma nota.
  with est as (select cnpj from estabelecimento),
  v as (
    select f.sinal, coalesce(i.v_prod,0) - coalesce(i.v_desc,0) as valor,
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
      from v
  ), m as (
    select greatest(1, (extract(year from age(p_fim + 1, p_ini)) * 12
                        + extract(month from age(p_fim + 1, p_ini))))::int meses
  )
  select 'receita_bruta', receita, 'venda de mercadoria, sem as notas entre filiais' from b
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


-- ============================================================= declarado
create or replace function apuracao_declarada(p_ini date, p_fim date, p_cnpj text)
returns table (tributo text, uf text, arquivo_id bigint, debitos numeric,
               creditos numeric, ajustes_debito numeric, ajustes_credito numeric,
               saldo_credor_anterior numeric, a_recolher numeric,
               saldo_credor_transportar numeric)
language sql stable as $$
  select a.tributo, a.uf, a.arquivo_id, a.debitos, a.creditos,
         a.ajustes_debito_doc + a.ajustes_debito + a.estornos_credito,
         a.ajustes_credito_doc + a.ajustes_credito + a.estornos_debito,
         a.saldo_credor_anterior, a.a_recolher, a.saldo_credor_transportar
    from efd_apuracao a
    join sped_arquivo s on s.id = a.arquivo_id and s.vigente
   where a.cnpj = p_cnpj and a.dt_ini <= p_fim and a.dt_fin >= p_ini
     and (a.debitos <> 0 or a.creditos <> 0 or a.a_recolher <> 0
          or a.saldo_credor_transportar <> 0 or a.saldo_credor_anterior <> 0);
$$;


-- ===================================== consistencia interna da EFD declarada
-- Tres verificacoes que so precisam da propria EFD:
--   1. debitos e creditos do E110 = soma do ICMS no C190 de saida e de entrada;
--   2. a conta do E110 fecha: saldo = debitos + ajustes - creditos - ajustes -
--      saldo anterior, e o resultado e o que foi declarado a recolher ou a
--      transportar;
--   3. IPI: E520 = soma do IPI no C190.
create or replace function consistencia_efd(p_arquivo_id bigint)
returns table (verificacao text, declarado numeric, calculado numeric, diferenca numeric, ok boolean)
language sql stable as $$
  with a as (select * from efd_apuracao where arquivo_id = p_arquivo_id),
  c as (select coalesce(sum(vl_icms) filter (where left(cfop,1) in ('5','6','7')),0) icms_sai,
               coalesce(sum(vl_icms) filter (where left(cfop,1) in ('1','2','3')),0) icms_ent,
               coalesce(sum(vl_ipi)  filter (where left(cfop,1) in ('5','6','7')),0) ipi_sai,
               coalesce(sum(vl_ipi)  filter (where left(cfop,1) in ('1','2','3')),0) ipi_ent,
               coalesce(sum(vl_st)   filter (where left(cfop,1) in ('5','6','7')),0) st_sai
          from doc_analitico where arquivo_id = p_arquivo_id),
  i as (select * from a where tributo = 'icms'),
  conta as (
    select (debitos + ajustes_debito_doc + ajustes_debito + estornos_credito)
         - (creditos + ajustes_credito_doc + ajustes_credito + estornos_debito
            + saldo_credor_anterior) as s, *
      from i)
  select x.v, x.d, x.c, x.d - x.c, abs(x.d - x.c) < 0.01 from (
    select 1 o, 'ICMS: debitos do E110 = ICMS das saidas no C190' v, i.debitos d, c.icms_sai c from i, c
    union all
    select 2, 'ICMS: creditos do E110 = ICMS das entradas no C190', i.creditos, c.icms_ent from i, c
    union all
    select 3, 'ICMS: a recolher declarado = conta do E110',
           conta.a_recolher, greatest(conta.s, 0) - conta.deducoes from conta
    union all
    select 4, 'ICMS: saldo credor declarado = conta do E110',
           conta.saldo_credor_transportar, greatest(-conta.s, 0) from conta
    union all
    select 5, 'IPI: debitos do E520 = IPI das saidas no C190',
           (select debitos from a where tributo = 'ipi'), c.ipi_sai from c
    union all
    select 6, 'IPI: creditos do E520 = IPI das entradas no C190',
           (select creditos from a where tributo = 'ipi'), c.ipi_ent from c
  ) x
  where x.d is not null
  order by x.o;
$$;
