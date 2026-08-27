-- 029 - Revincula as views e funcoes as tabelas ja filtradas por trabalho.
--
-- A 028 renomeou as tabelas e pos views filtradas no lugar. Objetos criados
-- antes continuam apontando para as tabelas fisicas: no Postgres a dependencia
-- e por OID, nao por nome, e o rename levou o vinculo junto.
--
-- Aqui cada objeto e reexecutado com o mesmo texto que ja estava aplicado, para
-- que passe a resolver contra as views novas. Entra so a ULTIMA definicao de
-- cada um: reproduzir todas as versoes em ordem fazia a definicao antiga de
-- estoque_em_detalhe colidir com a atual, que mudou de assinatura depois.
--
-- Gerado a partir das proprias migracoes anteriores, para nao haver divergencia
-- entre o que foi testado e o que e revinculado.

-- ====================================================== derrubar antes de criar
-- CREATE OR REPLACE VIEW nao muda a lista de colunas, e varias views comecam com
-- `select a.*`. A tabela ganhou trabalho_id na 027, entao o * agora abre uma
-- coluna a mais no meio e o replace e recusado. Recriar do zero resolve.
--
-- v_trabalho fica de fora de proposito: ela conta linhas de CADA trabalho, e
-- portanto precisa ler as tabelas fisicas, que e onde o vinculo por OID ja a
-- deixou. Recria-la sobre as views filtradas zeraria a contagem dos trabalhos
-- inativos.
do $$
declare
  v text;
  views text[] := array[
    'v_inventario','v_inventario_conferencia','v_divergencia_valoracao',
    'v_custo_inventario_vs_entrada','v_arquivo_vigente','v_cfop_nao_classificado',
    'v_kpis','v_filiais','v_terceiros','v_import_status','v_notas',
    'v_inventario_busca','v_datas_movimento','v_divergencia_detalhe',
    'v_relatorio_fontes','v_achado_painel','v_achado_resumo','v_cobertura_fontes',
    'v_efd_sem_xml','v_xml_sem_efd','v_concilia_divergente',
    'v_transferencia_interna','v_transferencia_divergente','v_cobertura_item'];
begin
  foreach v in array views loop
    execute format('drop view if exists %I cascade', v);
  end loop;
end $$;

-- v_inventario  (de 002_views.sql)
-- estoque reconstituido, com cadastro resolvido
create or replace view v_inventario as
select
  e.uf,
  i.cnpj,
  i.dt_inv,
  ii.cod_item,
  it.descr_item,
  it.descr_norm,
  it.ncm,
  ii.unid,
  ii.qtd,
  ii.vl_unit,
  ii.vl_item,
  ii.ind_prop,
  case ii.ind_prop
    when '0' then 'proprio, em seu poder'
    when '1' then 'proprio, em poder de terceiros'
    when '2' then 'de terceiros, em seu poder'
  end as ind_prop_desc,
  ii.cod_part,
  p.nome as depositario,
  ii.cod_cta
from inventario_item ii
join inventario i    on i.id = ii.inventario_id
left join estabelecimento e on e.cnpj = ii.cnpj
left join sped_item it on it.cnpj_estab = ii.cnpj and it.cod_item = ii.cod_item
left join sped_participante p on p.cnpj_estab = ii.cnpj and p.cod_part = ii.cod_part;

-- v_inventario_conferencia  (de 002_views.sql)
-- totais por estabelecimento x total declarado no H005
create or replace view v_inventario_conferencia as
select
  i.cnpj,
  e.uf,
  i.dt_inv,
  i.vl_inv                      as vl_declarado_h005,
  sum(ii.vl_item)               as vl_somado_h010,
  i.vl_inv - sum(ii.vl_item)    as diferenca,
  count(*)                      as qtd_itens,
  sum(ii.qtd)                   as qtd_total
from inventario i
join inventario_item ii on ii.inventario_id = i.id
left join estabelecimento e on e.cnpj = i.cnpj
group by i.cnpj, e.uf, i.dt_inv, i.vl_inv;

-- v_divergencia_valoracao  (de 002_views.sql)
-- mesmo produto valorado de forma diferente entre filiais
create or replace view v_divergencia_valoracao as
with base as (
  select v.descr_norm, v.uf, v.cnpj, v.cod_item, v.descr_item, v.qtd, v.vl_unit
  from v_inventario v
  where v.descr_norm is not null and v.descr_norm <> '' and v.vl_unit > 0
),
g as (
  select descr_norm,
         count(distinct cnpj)                                   as n_filiais,
         (percentile_cont(0.5) within group (order by vl_unit))::numeric as mediana,
         min(vl_unit) as menor, max(vl_unit) as maior
  from base group by descr_norm having count(distinct cnpj) > 1
)
select b.descr_norm, b.uf, b.cnpj, b.cod_item, b.descr_item, b.qtd, b.vl_unit,
       g.mediana, g.n_filiais,
       round(greatest(b.vl_unit / g.mediana, g.mediana / b.vl_unit), 2) as desvio,
       round((g.mediana - b.vl_unit) * b.qtd, 2)                        as impacto_vs_mediana
from base b
join g on g.descr_norm = b.descr_norm
where greatest(g.maior / nullif(g.menor,0), 1) >= 1.5;

-- v_custo_inventario_vs_entrada  (de 002_views.sql)
-- custo do inventario x custo real de entrada nos documentos fiscais
create or replace view v_custo_inventario_vs_entrada as
with ent as (
  select cnpj, cod_item,
         sum(qtd)                          as qtd_entrada,
         sum(vl_item)                      as vl_entrada,
         sum(vl_item) / nullif(sum(qtd),0) as custo_entrada
  from doc_item
  where left(cfop,1) in ('1','2','3') and qtd > 0
  group by cnpj, cod_item
)
select v.uf, v.cnpj, v.cod_item, v.descr_item, v.qtd, v.vl_unit as custo_inventario,
       e.custo_entrada, e.qtd_entrada,
       round(e.custo_entrada / nullif(v.vl_unit,0), 1)              as multiplo,
       round((e.custo_entrada - v.vl_unit) * v.qtd, 2)              as exposicao
from v_inventario v
join ent e on e.cnpj = v.cnpj and e.cod_item = v.cod_item
where v.vl_unit > 0 and e.custo_entrada / v.vl_unit >= 2
order by exposicao desc;

-- v_arquivo_vigente  (de 003_evidencia.sql)
-- ---------------------------------------------------------------- so o vigente
create or replace view v_arquivo_vigente as
select * from sped_arquivo where vigente;

comment on view v_arquivo_vigente is
  'Arquivos ainda validos. Retificados ficam de fora sem serem apagados.';

-- v_cfop_nao_classificado  (de 004_momento_zero.sql)
-- ===================================================================== visoes
create or replace view v_cfop_nao_classificado as
select ni.cfop, count(*) as ocorrencias, count(distinct n.id) as notas,
       min(n.dt_emi) as primeira, max(n.dt_emi) as ultima,
       sum(ni.v_prod) as valor
from nfe_item ni
join nfe n on n.id = ni.nfe_id
left join cfop_efeito c on c.cfop = ni.cfop
where c.cfop is null
group by ni.cfop order by 5 desc;

comment on view v_cfop_nao_classificado is
  'CFOP presente nas notas e ausente da tabela de efeitos. Enquanto houver '
  'linha aqui, o Kardex esta incompleto.';

-- v_kpis  (de 005_views_api.sql)
-- 005 — Views para consumo pela API serverless.
--
-- No Vercel nao existe binario curl e a Management API do Supabase nao serve
-- como camada de dados. A funcao serverless le por PostgREST, que consulta
-- views diretamente mas nao aceita SQL arbitrario. Cada consulta do painel
-- vira uma view aqui.

create or replace view v_kpis as
select
  (select count(*) from inventario_item)                        as itens,
  (select coalesce(sum(qtd),0) from inventario_item)            as unidades,
  (select coalesce(sum(vl_item),0) from inventario_item)        as valor,
  (select count(*) from estabelecimento)                        as filiais,
  (select count(*) from sped_arquivo)                           as arquivos,
  (select count(*) from doc_fiscal)                             as documentos,
  (select count(*) from inventario_item where qtd < 0)          as negativos,
  (select count(*) from v_custo_inventario_vs_entrada)          as div_itens,
  (select coalesce(sum(exposicao),0)
     from v_custo_inventario_vs_entrada)                        as div_exposicao,
  (select coalesce(sum(vl_item),0) from inventario_item
     where ind_prop = '1')                                      as em_terceiros,
  (select count(*) from v_inventario_conferencia
     where abs(diferenca) < 0.005)                              as conf_ok,
  (select count(*) from v_inventario_conferencia)               as conf_total,
  (select max(dt_inv)::text from inventario)                    as data_base;

comment on view v_kpis is
  'Indicadores do dashboard numa linha so. Existe para o PostgREST poder servir '
  'o painel sem SQL arbitrario.';

-- v_filiais  (de 005_views_api.sql)
create or replace view v_filiais as
select c.uf, c.cnpj, e.nome, c.qtd_itens, c.qtd_total,
       c.vl_somado_h010 as valor, c.vl_declarado_h005 as declarado, c.diferenca
from v_inventario_conferencia c
join estabelecimento e on e.cnpj = c.cnpj;

-- v_terceiros  (de 005_views_api.sql)
create or replace view v_terceiros as
select uf, cnpj, depositario, count(*) as itens, sum(vl_item) as valor
from v_inventario where ind_prop = '1'
group by uf, cnpj, depositario;

-- v_import_status  (de 005_views_api.sql)
create or replace view v_import_status as
select
  (select count(*) from nfe)                                    as notas,
  (select count(*) from nfe where situacao <> 'autorizada')      as nao_autorizadas,
  (select count(*) from nfe_item)                                as itens_nota,
  (select count(*) from movimento where origem = 'nfe')          as movimentos,
  (select count(*) from item_pendente where status = 'aberto')   as pendentes,
  (select count(*) from v_cfop_nao_classificado)                 as cfops_abertos,
  (select min(dt_emi)::text from nfe)                            as primeira,
  (select max(dt_emi)::text from nfe)                            as ultima,
  (select coalesce(sum(vl_item),0) from saldo_abertura)          as abertura;

-- v_notas  (de 005_views_api.sql)
create or replace view v_notas as
select n.chave, n.num_nf, n.serie, n.dt_emi, n.nat_op, n.emit_cnpj, n.emit_nome,
       n.dest_doc, n.dest_nome, n.vl_nf, n.situacao, n.nome_arquivo,
       (select count(*) from nfe_item i where i.nfe_id = n.id)  as itens,
       (select count(*) from movimento m where m.nfe_id = n.id) as movs
from nfe n;

-- v_inventario_busca  (de 005_views_api.sql)
-- A busca do inventario precisa de filtro por texto. O PostgREST faz isso com
-- ilike sobre a view, entao basta expor uma coluna concatenada para pesquisa.
create or replace view v_inventario_busca as
select v.*,
       upper(coalesce(v.descr_item,'') || ' ' || v.cod_item || ' ' ||
             coalesce(v.ncm,'')) as busca
from v_inventario v;

comment on view v_inventario_busca is
  'v_inventario com uma coluna concatenada para o PostgREST filtrar por ilike.';

-- estoque_em  (de 007_valor_exato.sql)
-- 007 — O valor do movimento manda, nao a recomputacao.
--
-- estoque_em recalculava o valor como qtd * vl_unit. No inventario declarado
-- ha 33 itens em que QTD x VL_UNIT difere do VL_ITEM por arredondamento do
-- custo unitario na origem. Recomputar devolvia R$ 4.854.519,22 contra os
-- R$ 4.854.519,21 congelados no momento zero.
--
-- Saldo de abertura e imutavel: tem que sair exatamente como entrou. Agora usa
-- vl_total, que e o valor declarado, e so cai para qtd * vl_unit se faltar.

create or replace function estoque_em(p_data date)
returns table (
  cnpj text, cod_item text, qtd numeric, qtd_proprio numeric,
  qtd_terceiros numeric, custo_medio numeric, valor numeric,
  ultima_mov date, movimentos bigint
)
language plpgsql stable as $$
declare
  m record;
  k_cnpj text := null; k_item text := null;
  s_qtd numeric := 0; s_val numeric := 0;
  s_p0 numeric := 0; s_p1 numeric := 0;
  n_mov bigint := 0; ult date; custo numeric; entrada numeric;
begin
  for m in
    select mv.cnpj, mv.cod_item, mv.ind_prop, mv.dt, mv.qtd, mv.vl_unit,
           mv.vl_total, mv.efeito
    from movimento mv where mv.dt <= p_data
    order by mv.cnpj, mv.cod_item, mv.dt, mv.id
  loop
    if k_cnpj is distinct from m.cnpj or k_item is distinct from m.cod_item then
      if k_cnpj is not null and (s_qtd <> 0 or s_val <> 0) then
        cnpj := k_cnpj; cod_item := k_item;
        qtd := s_qtd; qtd_proprio := s_p0; qtd_terceiros := s_p1; valor := s_val;
        custo_medio := case when s_qtd > 0 then s_val / s_qtd else 0 end;
        ultima_mov := ult; movimentos := n_mov;
        return next;
      end if;
      k_cnpj := m.cnpj; k_item := m.cod_item;
      s_qtd := 0; s_val := 0; s_p0 := 0; s_p1 := 0; n_mov := 0;
    end if;

    n_mov := n_mov + 1;
    ult := m.dt;

    if m.ind_prop = '1' then s_p1 := s_p1 + m.qtd; else s_p0 := s_p0 + m.qtd; end if;

    if m.efeito = 'soma' then
      entrada := coalesce(m.vl_total, m.qtd * coalesce(m.vl_unit, 0));
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + abs(entrada) * sign(m.qtd);
    elsif m.efeito = 'baixa' then
      custo := case when s_qtd > 0 then s_val / s_qtd else 0 end;
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + m.qtd * custo;
    end if;
  end loop;

  if k_cnpj is not null and (s_qtd <> 0 or s_val <> 0) then
    cnpj := k_cnpj; cod_item := k_item;
    qtd := s_qtd; qtd_proprio := s_p0; qtd_terceiros := s_p1; valor := s_val;
    custo_medio := case when s_qtd > 0 then s_val / s_qtd else 0 end;
    ultima_mov := ult; movimentos := n_mov;
    return next;
  end if;
end $$;

comment on function estoque_em(date) is
  'Posicao do estoque em uma data, por custo medio ponderado movel. Baixa pelo '
  'custo vigente, nunca pelo valor da nota de saida.';

-- estoque_em_detalhe  (de 008_descricao_da_nfe.sql)
-- 008 — Descricao vinda da NF-e quando o item nao esta no cadastro.
--
-- Itens criados depois de 31/12/2022 nao existem no registro 0200 do EFD de
-- fev/2023, que e o unico cadastro que temos. Na tela eles apareciam como
-- linhas em branco: so o codigo, sem descricao, NCM nem unidade — e o usuario
-- lia isso como "nao mostrou nada".
--
-- A descricao existe: esta no proprio XML (xProd), junto com NCM e unidade.
-- A ordem de preferencia e cadastro 0200 -> saldo de abertura -> ultima NF-e.

-- create or replace nao muda tipo de retorno: a assinatura ganhou a coluna
-- origem_cadastro, entao a funcao precisa cair antes.
drop function if exists estoque_em_detalhe(date);

create function estoque_em_detalhe(p_data date)
returns table (
  uf text, cnpj text, cod_item text, descr_item text, ncm text, unid text,
  qtd numeric, qtd_proprio numeric, qtd_terceiros numeric,
  custo_medio numeric, valor numeric, ultima_mov date, movimentos bigint,
  origem_cadastro text, busca text
)
language sql stable as $$
  select
    e.uf,
    s.cnpj,
    s.cod_item,
    coalesce(i.descr_item, sa.descr_item, nf.x_prod)          as descr_item,
    coalesce(i.ncm, nf.ncm)                                   as ncm,
    coalesce(sa.unid, i.unid_inv, nf.u_com)                   as unid,
    s.qtd, s.qtd_proprio, s.qtd_terceiros,
    round(s.custo_medio, 6)                                   as custo_medio,
    round(s.valor, 2)                                         as valor,
    s.ultima_mov, s.movimentos,
    case
      when i.descr_item  is not null then 'cadastro 0200'
      when sa.descr_item is not null then 'saldo de abertura'
      when nf.x_prod     is not null then 'NF-e'
      else 'sem cadastro'
    end                                                       as origem_cadastro,
    upper(coalesce(i.descr_item, sa.descr_item, nf.x_prod, '') || ' ' ||
          s.cod_item || ' ' || coalesce(i.ncm, nf.ncm, ''))   as busca
  from estoque_em(p_data) s
  left join estabelecimento e on e.cnpj = s.cnpj
  left join lateral (
    select si.descr_item, si.ncm, si.unid_inv
    from sped_item si
    join sped_arquivo a on a.id = si.arquivo_id and a.vigente
    where si.cnpj_estab = s.cnpj and si.cod_item = s.cod_item
    limit 1
  ) i on true
  left join lateral (
    select descr_item, unid from saldo_abertura
    where cnpj = s.cnpj and cod_item = s.cod_item limit 1
  ) sa on true
  -- Ultima aparicao do codigo numa nota do proprio estabelecimento. Só serve
  -- para nota que NOS emitimos: ali o cProd e o nosso codigo. Em nota recebida
  -- o cProd e do fornecedor e casaria produto errado.
  left join lateral (
    select ni.x_prod, ni.ncm, ni.u_com
    from nfe_item ni
    join nfe n on n.id = ni.nfe_id
    where ni.c_prod = s.cod_item
      and n.emit_cnpj = s.cnpj
    order by n.dt_emi desc, ni.id desc
    limit 1
  ) nf on true;
$$;

comment on function estoque_em_detalhe(date) is
  'Posicao com cadastro resolvido em cascata: 0200, saldo de abertura, NF-e. '
  'A coluna origem_cadastro diz de onde veio a descricao.';

-- estoque_resumo  (de 006_estoque_em_data.sql)
-- Totais da data, para os indicadores do topo.
create or replace function estoque_resumo(p_data date)
returns table (
  itens          bigint,
  unidades       numeric,
  valor          numeric,
  em_terceiros   numeric,
  negativos      bigint,
  filiais        bigint,
  ultima_mov     date
)
language sql
stable
as $$
  select count(*)::bigint,
         coalesce(sum(qtd), 0),
         coalesce(sum(valor), 0),
         coalesce(sum(qtd_terceiros), 0),
         count(*) filter (where qtd < 0)::bigint,
         count(distinct cnpj)::bigint,
         max(ultima_mov)
  from estoque_em(p_data)
  where qtd <> 0 or valor <> 0;
$$;

-- v_datas_movimento  (de 006_estoque_em_data.sql)
-- Datas em que houve movimento, para a tela sugerir onde ha o que ver.
create or replace view v_datas_movimento as
select dt, count(*) as movimentos, count(distinct cnpj) as filiais
from movimento group by dt order by dt;

-- kardex_item  (de 026_kardex_transferencia.sql)
-- 025 — A ficha identifica transferencia entre filiais.
--
-- Na ficha do item, a contraparte de uma transferencia aparecia como
-- "MULTI COMERCIAL & IMPORTADORA LTDA" — o mesmo texto para o Ceara e para Sao
-- Paulo, sem dizer qual. O auditor nao consegue distinguir movimento interno de
-- venda a terceiro, que e a primeira pergunta ao ler um Kardex.
--
-- Agora a funcao devolve se a contraparte e estabelecimento do grupo e qual e a
-- UF dela, alem da natureza do movimento em uma palavra.

drop function if exists kardex_item(text, text, date);

create function kardex_item(p_cnpj text, p_cod_item text, p_ate date default null)
returns table (
  seq             bigint,
  dt              date,
  origem          text,
  chave           char(44),
  num_nf          text,
  serie           text,
  natureza        text,
  cfop            text,
  cfop_descr      text,
  efeito          text,
  contraparte     text,
  contraparte_doc text,
  contraparte_uf  text,
  interna         boolean,
  natureza_mov    text,
  entrada         numeric,
  saida           numeric,
  vl_unit_mov     numeric,
  vl_total_mov    numeric,
  saldo_qtd       numeric,
  saldo_proprio   numeric,
  saldo_terceiros numeric,
  custo_medio     numeric,
  saldo_valor     numeric,
  observacao      text
)
language plpgsql stable as $$
declare
  m       record;
  s_qtd   numeric := 0;
  s_val   numeric := 0;
  s_p0    numeric := 0;
  s_p1    numeric := 0;
  i       bigint  := 0;
  custo   numeric;
  entrou  numeric;
  v_doc   text;
begin
  for m in
    select mv.id, mv.dt, mv.origem, mv.chave, mv.cfop, mv.efeito, mv.qtd,
           mv.vl_unit, mv.vl_total, mv.ind_prop, mv.observacao,
           n.num_nf, n.serie, n.nat_op, n.emit_cnpj, n.emit_nome,
           n.dest_doc, n.dest_nome,
           ce.descricao as cfop_descr
    from movimento mv
    left join nfe n on n.id = mv.nfe_id
    left join cfop_efeito ce on ce.cfop = mv.cfop
    where mv.cnpj = p_cnpj and mv.cod_item = p_cod_item
      and (p_ate is null or mv.dt <= p_ate)
    order by mv.dt, mv.id
  loop
    i := i + 1;

    if m.ind_prop = '1' then s_p1 := s_p1 + m.qtd; else s_p0 := s_p0 + m.qtd; end if;

    if m.efeito = 'soma' then
      entrou := coalesce(m.vl_total, m.qtd * coalesce(m.vl_unit, 0));
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + abs(entrou) * sign(m.qtd);
    elsif m.efeito = 'baixa' then
      custo := case when s_qtd > 0 then s_val / s_qtd else 0 end;
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + m.qtd * custo;
    end if;

    seq := i; dt := m.dt; origem := m.origem; chave := m.chave;
    num_nf := m.num_nf; serie := m.serie;
    natureza := coalesce(m.nat_op, m.observacao);
    cfop := m.cfop; cfop_descr := m.cfop_descr; efeito := m.efeito;

    -- A contraparte e sempre o outro lado da operacao.
    contraparte := case
      when m.emit_cnpj is null then null
      when m.emit_cnpj = p_cnpj then m.dest_nome
      else m.emit_nome end;
    v_doc := case
      when m.emit_cnpj is null then null
      when m.emit_cnpj = p_cnpj then m.dest_doc
      else m.emit_cnpj end;
    contraparte_doc := v_doc;

    select e.uf into contraparte_uf from estabelecimento e where e.cnpj = v_doc;
    interna := contraparte_uf is not null;

    natureza_mov := case
      when m.origem = 'abertura'                      then 'abertura'
      when interna                                    then 'transferencia'
      when m.efeito in ('para_terceiros','de_terceiros') then 'posse'
      when m.efeito = 'simbolico'                     then 'simbolico'
      when m.qtd > 0                                  then 'entrada'
      else 'saida' end;

    entrada := case when m.qtd > 0 then m.qtd else null end;
    saida   := case when m.qtd < 0 then -m.qtd else null end;
    vl_unit_mov := m.vl_unit; vl_total_mov := m.vl_total;
    saldo_qtd := s_qtd; saldo_proprio := s_p0; saldo_terceiros := s_p1;
    custo_medio := case when s_qtd > 0 then round(s_val / s_qtd, 6) else 0 end;
    saldo_valor := round(s_val, 2);
    observacao := m.observacao;
    return next;
  end loop;
end $$;

comment on function kardex_item(text, text, date) is
  'Ficha do item com saldo corrido. Identifica se a contraparte e outro '
  'estabelecimento do grupo, e classifica a natureza do movimento.';

-- v_divergencia_detalhe  (de 012_motivo_inteiros.sql)
create or replace view v_divergencia_detalhe as
with ent as (
  select di.cnpj, di.cod_item,
         sum(di.qtd)                             as qtd_entrada,
         sum(di.vl_item)                         as vl_entrada,
         sum(di.vl_item) / nullif(sum(di.qtd),0) as custo_entrada,
         min(di.dt_doc)                          as primeira_entrada,
         max(di.dt_doc)                          as ultima_entrada,
         count(distinct di.doc_id)               as documentos,
         string_agg(distinct di.cfop, ', ')      as cfops
  from doc_item di
  where left(di.cfop,1) in ('1','2','3') and di.qtd > 0
  group by di.cnpj, di.cod_item
)
select
  v.uf, v.cnpj, v.cod_item, v.descr_item, v.ncm,
  v.qtd, v.vl_unit                                   as custo_inventario,
  e.custo_entrada, e.qtd_entrada, e.documentos, e.cfops,
  e.primeira_entrada, e.ultima_entrada,
  round(e.custo_entrada / nullif(v.vl_unit,0), 1)    as multiplo,
  round((e.custo_entrada - v.vl_unit) * v.qtd, 2)    as exposicao,
  round(v.qtd * e.custo_entrada, 2)                  as valor_revalorado,
  ii.linha_arquivo, a.nome_arquivo, left(a.sha256, 16) as sha_arquivo,
  'O inventario declara ' || fmt_br_int(v.qtd) || ' ' || coalesce(ii.unid,'un')
    || ' a R$ ' || fmt_br(v.vl_unit) || ' cada (registro H010, linha '
    || ii.linha_arquivo || ' do arquivo). No mesmo arquivo, o registro C170 da '
    || 'nota de entrada de ' || to_char(e.ultima_entrada, 'DD/MM/YYYY')
    || ' traz o mesmo item por R$ ' || fmt_br(e.custo_entrada)
    || ' a unidade, CFOP ' || e.cfops || ' — '
    || fmt_br_int(e.custo_entrada / nullif(v.vl_unit,0))
    || ' vezes mais. Os dois valores vem do proprio EFD; nao ha erro de '
    || 'importacao. O custo de entrada e documentado por nota fiscal, entao o '
    || 'inventario esta subavaliado nesse item.'                       as motivo
from v_inventario v
join ent e on e.cnpj = v.cnpj and e.cod_item = v.cod_item
join inventario i on i.cnpj = v.cnpj
join inventario_item ii on ii.inventario_id = i.id and ii.cod_item = v.cod_item
join sped_arquivo a on a.id = i.arquivo_id and a.vigente
where v.vl_unit > 0 and e.custo_entrada / v.vl_unit >= 2;

comment on view v_divergencia_detalhe is
  'Divergencia de valoracao com motivo em texto e a trilha ate a linha do '
  'arquivo. Alimenta o painel de detalhe do dashboard.';

-- divergencia_documentos  (de 010_divergencia_detalhe.sql)
-- Documentos que sustentam cada divergencia.
create or replace function divergencia_documentos(p_cnpj text, p_cod_item text)
returns table (
  num_doc text, serie text, chv_nfe text, dt_doc date, cfop text,
  cfop_descr text, qtd numeric, vl_item numeric, custo_unit numeric,
  parceiro text, parceiro_doc text, ind_oper text
)
language sql stable as $$
  select df.num_doc, df.ser, df.chv_nfe, df.dt_doc, di.cfop,
         ce.descricao,
         di.qtd, di.vl_item,
         round(di.vl_item / nullif(di.qtd,0), 2),
         coalesce(p.nome, df.cod_part), coalesce(p.cnpj, p.cpf),
         df.ind_oper
  from doc_item di
  join doc_fiscal df on df.id = di.doc_id
  left join cfop_efeito ce on ce.cfop = di.cfop
  left join sped_participante p
         on p.cnpj_estab = df.cnpj and p.cod_part = df.cod_part
  where di.cnpj = p_cnpj and di.cod_item = p_cod_item
  order by df.dt_doc, df.num_doc;
$$;

comment on function divergencia_documentos(text, text) is
  'Notas fiscais que movimentaram o item, com o custo unitario de cada uma. '
  'E a prova do achado.';

-- fmt_br  (de 011_motivo_formato_br.sql)
-- 011 — Numeros do motivo em formato brasileiro.
--
-- to_char usa os separadores do locale do banco, que aqui e americano: o motivo
-- saia "R$ 310.50" e "R$ 8,740.93" enquanto a tabela ao lado mostrava
-- "R$ 310,50" e "R$ 8.740,93". Dois formatos para o mesmo numero na mesma tela
-- levaram o auditor a achar que o sistema tinha carregado outro valor.

create or replace function fmt_br(v numeric)
returns text language sql immutable as $$
  -- Troca os separadores via marcador temporario: '.' e ',' precisam trocar de
  -- lugar ao mesmo tempo, e um replace direto sobrescreveria o outro.
  select replace(replace(replace(
           to_char(v, 'FM999G999G999G990D00'), '.', '#'), ',', '.'), '#', ',');
$$;

comment on function fmt_br(numeric) is
  'Numero no formato brasileiro: ponto para milhar, virgula para decimal.';

-- fmt_br_int  (de 012_motivo_inteiros.sql)
-- 012 — Quantidade e multiplo sem casas decimais no motivo.
--
-- "102,00 UN" e "28,00 vezes mais" leem mal. Valor monetario pede duas casas;
-- contagem e multiplicador, nenhuma.

create or replace function fmt_br_int(v numeric)
returns text language sql immutable as $$
  select replace(to_char(round(v, 0), 'FM999G999G999G990'), ',', '.');
$$;

comment on function fmt_br_int(numeric) is
  'Inteiro no formato brasileiro, com ponto separando milhar. Para quantidade '
  'e multiplicador, onde casa decimal so atrapalha a leitura.';

comment on function relatorio_achados(date) is
  'Todos os achados de uma data em formato unico. Inclui as conciliacoes entre '
  'EFD e XML e entre filiais, agregadas por estabelecimento.';

-- relatorio_resumo  (de 013_relatorio.sql)
create or replace function relatorio_resumo(p_data date)
returns table (
  data_base       date,
  itens_saldo     bigint,
  unidades        numeric,
  valor_estoque   numeric,
  filiais         bigint,
  achados         bigint,
  criticos        bigint,
  altos           bigint,
  exposicao       numeric,
  arquivos        bigint,
  notas           bigint,
  movimentos      bigint,
  gerado_em       timestamptz
)
language sql stable as $$
  select p_data,
         (select count(*) from estoque_em_detalhe(p_data) where qtd <> 0),
         (select coalesce(sum(qtd),0) from estoque_em_detalhe(p_data) where qtd <> 0),
         (select coalesce(sum(valor),0) from estoque_em_detalhe(p_data) where qtd <> 0),
         (select count(*) from estabelecimento),
         (select count(*) from relatorio_achados(p_data)),
         (select count(*) from relatorio_achados(p_data) where severidade = 'critico'),
         (select count(*) from relatorio_achados(p_data) where severidade = 'alto'),
         (select coalesce(sum(valor),0) from relatorio_achados(p_data)
            where tipo = 'valoracao'),
         (select count(*) from sped_arquivo where vigente),
         (select count(*) from nfe),
         (select count(*) from movimento),
         now();
$$;

-- v_relatorio_fontes  (de 013_relatorio.sql)
-- Arquivos que sustentam o relatorio: e a procedencia da prova.
create or replace view v_relatorio_fontes as
select a.cnpj, e.uf, e.nome, a.nome_arquivo, left(a.sha256, 24) as sha256,
       a.dt_ini, a.dt_fin, a.cod_fin, a.ind_perfil, a.linhas_lidas,
       a.importado_por, a.importado_em, a.versao_motor
from sped_arquivo a
left join estabelecimento e on e.cnpj = a.cnpj
where a.vigente
order by e.uf;

-- unid_legivel  (de 014_unidade_legivel.sql)
-- 014 — Unidade ilegivel nao vai para o texto do relatorio.
--
-- O motivo saia "Saldo de -2 1 em 11/01/2023": a unidade e o codigo '1' do
-- registro 0190, cadastrado com a descricao-modelo 'DESC. UNIDADE'. Codigo de
-- unidade puramente numerico nao significa nada para quem le o relatorio.

create or replace function unid_legivel(v text)
returns text language sql immutable as $$
  select case
    when v is null or btrim(v) = '' then 'un'
    when btrim(v) ~ '^[0-9]+$'      then 'un'   -- codigo numerico: sem sentido no texto
    else lower(btrim(v))
  end;
$$;

comment on function unid_legivel(text) is
  'Unidade para exibicao em texto corrido. Codigo numerico do 0190 vira "un".';

-- item_pendente_sugestoes  (de 016_sugestao_codigo_primeiro.sql)
-- 016 — Candidato com o mesmo codigo vem primeiro.
--
-- Ordenar so por similaridade de texto colocava o item errado no topo: para o
-- pendente 4035 ("LS 1200D PRO - LUMINARIA DE LED, FOTOMETRIA DE 83.100LUX"),
-- o candidato 4089 aparecia acima do proprio 4035, porque a descricao do
-- cadastro e mais curta e o trigrama penaliza diferenca de tamanho.
--
-- Codigo identico e sinal forte: nas transferencias entre filiais o cProd e o
-- codigo do grupo. Nao basta sozinho (o codigo 4061 e refletor em SP e pinca
-- em SC), mas combinado com semelhanca de descricao resolve com seguranca.

-- A assinatura ganhou a coluna confianca: create or replace nao muda tipo de
-- retorno, entao a funcao precisa cair antes.
drop function if exists item_pendente_sugestoes(text, text);

create function item_pendente_sugestoes(p_cnpj text, p_c_prod text)
returns table (
  cod_item      text,
  descr_item    text,
  ncm           text,
  unid_inv      text,
  semelhanca    real,
  ja_no_estoque boolean,
  origem        text,
  confianca     text
)
language sql stable as $$
  with alvo as (
    select x_prod, ncm from item_pendente
    where cnpj = p_cnpj and c_prod_externo = p_c_prod limit 1
  ),
  cand as (
    select si.cod_item, si.descr_item, si.ncm, si.unid_inv,
           similarity(upper(si.descr_item), upper((select x_prod from alvo))) as sim,
           si.cod_item = p_c_prod                            as mesmo_codigo,
           si.ncm = (select ncm from alvo)                   as mesmo_ncm
    from sped_item si
    join sped_arquivo a on a.id = si.arquivo_id and a.vigente
    where si.cnpj_estab = p_cnpj
      and (select x_prod from alvo) is not null
  )
  select c.cod_item, c.descr_item, c.ncm, c.unid_inv, c.sim,
         exists (select 1 from saldo_abertura sa
                 where sa.cnpj = p_cnpj and sa.cod_item = c.cod_item),
         concat_ws(' + ',
           case when c.mesmo_codigo then 'mesmo codigo' end,
           case when c.mesmo_ncm then 'mesmo NCM' end,
           case when c.sim >= 0.5 then 'descricao' end),
         case
           when c.mesmo_codigo and c.sim >= 0.5 then 'alta'
           when c.mesmo_codigo and c.mesmo_ncm  then 'alta'
           when c.mesmo_codigo                  then 'media'
           when c.sim >= 0.9                    then 'media'
           else 'baixa'
         end
  from cand c
  where c.mesmo_codigo or c.sim > 0.15
  -- codigo identico primeiro; depois NCM igual; so entao a semelhanca do texto
  order by c.mesmo_codigo desc, c.mesmo_ncm desc, c.sim desc
  limit 8;
$$;

comment on function item_pendente_sugestoes(text, text) is
  'Candidatos para resolver um item pendente. Ordena por codigo identico, NCM '
  'igual e semelhanca de descricao, nessa ordem. A coluna confianca resume.';

-- cfop_aberto_detalhe  (de 015_pendencias_detalhe.sql)
create or replace function cfop_aberto_detalhe(p_cfop text)
returns table (
  chave      char(44),
  num_nf     text,
  serie      text,
  dt_emi     date,
  nat_op     text,
  sentido    text,
  contraparte text,
  cod_item   text,
  x_prod     text,
  qtd        numeric,
  vl_prod    numeric
)
language sql stable as $$
  select n.chave, n.num_nf, n.serie, n.dt_emi, n.nat_op,
         case when exists (select 1 from estabelecimento e where e.cnpj = n.emit_cnpj)
              then 'saida' else 'entrada' end,
         case when exists (select 1 from estabelecimento e where e.cnpj = n.emit_cnpj)
              then n.dest_nome else n.emit_nome end,
         ni.c_prod, ni.x_prod, ni.q_com, ni.v_prod
  from nfe_item ni
  join nfe n on n.id = ni.nfe_id
  where ni.cfop = p_cfop
  order by n.dt_emi, n.num_nf, ni.n_item;
$$;

comment on function cfop_aberto_detalhe(text) is
  'Notas e itens que usam um CFOP ainda sem classificacao. E o que o auditor '
  'precisa ver para decidir o efeito no estoque.';

-- materialidade_vigente  (de 017_achado_persistido.sql)
-- Declarada como `returns materialidade`. Antes da 028 isso era o tipo da
-- tabela; agora e o tipo da view. Sao tipos diferentes para o Postgres, que
-- recusa trocar o retorno num replace — dai o drop. As colunas sao as mesmas.
drop function if exists materialidade_vigente(text);

create or replace function materialidade_vigente(p_escopo text default 'padrao')
returns materialidade language sql stable as $$
  select * from materialidade
  where escopo = p_escopo and vigente_de <= current_date
  order by vigente_de desc, id desc limit 1;
$$;

-- chave_achado  (de 017_achado_persistido.sql)
-- ==================================================== motor de varredura
create or replace function chave_achado(p_tipo text, p_cnpj text, p_cod_item text)
returns text language sql immutable as $$
  select p_tipo || '|' || coalesce(p_cnpj,'-') || '|' || coalesce(p_cod_item,'-');
$$;

-- varrer  (de 018_trivial_so_monetario.sql)
create or replace function varrer(p_data date, p_quem text default null)
returns TABLE (novos int, mantidos int, resolvidos int, total_aberto int)
language plpgsql as $$
declare
  v_mat   materialidade;
  v_quem  text := coalesce(p_quem, 'sistema');
  v_motor text := '0.4.1';
  v_novos int := 0; v_mant int := 0; v_resol int := 0; v_total int := 0;
  v_hash  text;
  r       record;
begin
  select * into v_mat from materialidade_vigente();

  create temp table _atual on commit drop as
  select chave_achado(a.tipo, a.cnpj, a.cod_item) as chave, a.*
  from relatorio_achados(p_data) a
  where not achado_sujeito_a_materialidade(a.tipo)
     or coalesce(abs(a.valor), 0) >= coalesce(v_mat.trivial, 0);

  create temp table _antes on commit drop as
  select chave from achado;

  for r in select * from _atual loop
    insert into achado (chave, tipo, severidade, data_base, cnpj, uf, cod_item,
                        descr_item, quantidade, valor, motivo, prova, versao_motor)
    values (r.chave, r.tipo, r.severidade, p_data, r.cnpj, r.uf, r.cod_item,
            r.descr_item, r.quantidade, r.valor, r.motivo, r.prova, v_motor)
    on conflict (chave) do update set
      severidade      = excluded.severidade,
      data_base       = greatest(achado.data_base, excluded.data_base),
      quantidade      = excluded.quantidade,
      valor           = excluded.valor,
      motivo          = excluded.motivo,
      prova           = excluded.prova,
      ultima_deteccao = now(),
      execucoes       = achado.execucoes + 1,
      status          = case when achado.status = 'resolvido' then 'aberto'
                             else achado.status end,
      resolvido_em    = case when achado.status = 'resolvido' then null
                             else achado.resolvido_em end;
  end loop;

  -- Novo e o que nao existia antes desta varredura. Comparar por chave e
  -- exato; a versao anterior usava janela de tempo e errava em reexecucao.
  select count(*) into v_novos
    from _atual t where not exists (select 1 from _antes b where b.chave = t.chave);
  select count(*) into v_mant
    from _atual t where exists (select 1 from _antes b where b.chave = t.chave);

  update achado a
     set status = 'resolvido', resolvido_em = now()
   where a.status in ('aberto','em_analise','respondido')
     and a.data_base <= p_data
     and not exists (select 1 from _atual t where t.chave = a.chave);
  get diagnostics v_resol = row_count;

  insert into achado_evento (achado_id, de_status, para_status, quem, nota)
  select a.id, 'aberto', 'resolvido', v_quem,
         'Deixou de ser detectado na varredura de ' || to_char(p_data,'DD/MM/YYYY')
  from achado a where a.resolvido_em > now() - interval '5 seconds';

  select count(*) into v_total from achado where status <> 'resolvido';
  select md5(string_agg(chave || coalesce(valor::text,''), '|' order by chave))
    into v_hash from _atual;

  insert into varredura (data_base, executada_por, versao_motor, materialidade,
                         novos, mantidos, resolvidos, total_aberto, hash_dados)
  values (p_data, v_quem, v_motor, v_mat.id, v_novos, v_mant, v_resol, v_total, v_hash);

  novos := v_novos; mantidos := v_mant; resolvidos := v_resol; total_aberto := v_total;
  return next;
end $$;

comment on function varrer(date, text) is
  'Executa as regras e concilia com os achados ja registrados: cria os novos, '
  'atualiza os que persistem e marca como resolvidos os que sumiram. Nunca '
  'apaga. Achado abaixo do trivial nao entra na lista.';

-- achado_mudar_status  (de 017_achado_persistido.sql)
-- ============================================== mudar o status de um achado
-- Mesmo caso de materialidade_vigente: `returns achado` mudou de tipo-tabela
-- para tipo-view na 028, e o replace nao troca retorno.
drop function if exists achado_mudar_status(bigint, text, text, text);

create or replace function achado_mudar_status(
  p_id bigint, p_status text, p_quem text, p_nota text default null)
returns achado language plpgsql as $$
declare
  v_antes text;
  v_out achado;
begin
  select status into v_antes from achado where id = p_id;
  if v_antes is null then
    raise exception 'achado % nao existe', p_id;
  end if;
  if p_status not in ('aberto','em_analise','respondido','aceito','refutado','resolvido') then
    raise exception 'status invalido: %', p_status;
  end if;

  update achado set
    status = p_status,
    resposta_cliente = case when p_status = 'respondido'
                            then coalesce(p_nota, resposta_cliente)
                            else resposta_cliente end,
    desfecho = case when p_status in ('aceito','refutado')
                    then coalesce(p_nota, desfecho) else desfecho end,
    resolvido_em = case when p_status = 'resolvido' then now() else resolvido_em end
  where id = p_id
  returning * into v_out;

  insert into achado_evento (achado_id, de_status, para_status, quem, nota)
  values (p_id, v_antes, p_status, p_quem, p_nota);
  return v_out;
end $$;

-- v_achado_painel  (de 017_achado_persistido.sql)
-- ===================================================================== visoes
create or replace view v_achado_painel as
select a.*,
       (select count(*) from achado_evento e where e.achado_id = a.id) as eventos,
       case a.status
         when 'aberto'     then 1 when 'em_analise' then 2
         when 'respondido' then 3 when 'refutado'   then 4
         when 'aceito'     then 5 else 6 end as ordem_status,
       case a.severidade
         when 'critico' then 1 when 'alto' then 2
         when 'medio' then 3 else 4 end as ordem_sev
from achado a;

-- v_achado_resumo  (de 019_exposicao_sem_duplicidade.sql)
-- Coluna nova no meio da lista: create or replace nao renomeia coluna de view.
drop view if exists v_achado_resumo;

create view v_achado_resumo as
select
  count(*) filter (where status = 'aberto')      as aberto,
  count(*) filter (where status = 'em_analise')  as em_analise,
  count(*) filter (where status = 'respondido')  as respondido,
  count(*) filter (where status = 'aceito')      as aceito,
  count(*) filter (where status = 'refutado')    as refutado,
  count(*) filter (where status = 'resolvido')   as resolvido,
  count(*)                                       as total,
  count(*) filter (where status <> 'resolvido'
                     and severidade = 'critico') as criticos_abertos,
  coalesce(sum(valor) filter (
      where status not in ('resolvido','refutado')
        and achado_e_exposicao(tipo) and valor > 0), 0) as exposicao_aberta,
  coalesce(sum(valor) filter (
      where tipo = 'terceiros' and status not in ('resolvido','refutado')), 0)
                                                 as valor_em_terceiros,
  count(*) filter (where prazo is not null and prazo < current_date
                     and status in ('aberto','em_analise'))  as atrasados
from achado;

-- achado_sujeito_a_materialidade  (de 018_trivial_so_monetario.sql)
-- 018 — O corte de trivialidade so vale para achado de natureza monetaria.
--
-- A primeira varredura descartou 46 dos 87 achados por ficarem abaixo do
-- trivial. Entre eles, os saldos negativos com valor zero — que sao os mais
-- graves de todos: valor zero ali significa que o item NUNCA teve entrada
-- registrada, so saidas. Materialidade mede distorcao de valor; nao serve para
-- decidir se uma falha estrutural merece atencao.
--
-- Sujeito a materialidade: valoracao e item pendente (o achado E um valor).
-- Sempre listado: saldo negativo, CFOP sem classificacao, mercadoria em
-- terceiros e ressalva (o achado e a existencia do fato).

create or replace function achado_sujeito_a_materialidade(p_tipo text)
returns boolean language sql immutable as $$
  select p_tipo in ('valoracao', 'item_pendente');
$$;

comment on function achado_sujeito_a_materialidade(text) is
  'Diz se o tipo de achado pode ser descartado por ficar abaixo do trivial. '
  'Falha estrutural nunca e trivial, por menor que seja o valor envolvido.';

-- achado_e_exposicao  (de 019_exposicao_sem_duplicidade.sql)
-- 019 — Exposicao soma so o que e distorcao de valor.
--
-- v_achado_resumo somava o valor de todos os tipos. Isso contava duas vezes a
-- mesma coisa (a ressalva registrada E a divergencia de valoracao) e incluia a
-- mercadoria em poder de terceiros, que nao e distorcao: e valor a confirmar
-- junto ao depositario. O numero saia R$ 6,1 milhoes num estoque de R$ 4,8.
--
-- Exposicao = potencial distorcao do valor do estoque. Sao dois tipos:
--   valoracao      item inventariado por custo diferente do documentado
--   item_pendente  entrada que ainda nao chegou ao Kardex

create or replace function achado_e_exposicao(p_tipo text)
returns boolean language sql immutable as $$
  select p_tipo in ('valoracao', 'item_pendente');
$$;

comment on function achado_e_exposicao(text) is
  'Diz se o valor do achado representa potencial distorcao do estoque. '
  'Ressalva duplica a valoracao; terceiros e valor a confirmar, nao distorcao.';

-- v_cobertura_fontes  (de 020_conciliacao.sql)
-- 020 — Conciliar declaracao com documento.
--
-- O EFD e o que a empresa declarou ao Fisco; o XML e o documento que ela
-- emitiu ou recebeu. Ate aqui as duas fontes conviviam sem se olhar. Sem esse
-- confronto, a auditoria acredita na palavra do arquivo que a propria empresa
-- transmitiu — que e exatamente o objeto sob exame.
--
-- Tres conciliacoes, de naturezas diferentes:
--   nota no EFD sem XML ... falta o documento que sustenta a escrituracao
--   XML sem nota no EFD ... documento emitido e possivelmente nao escriturado
--   item a item ........... mesma nota nas duas fontes, valores divergentes

-- ============================================== cobertura das duas fontes
create or replace view v_cobertura_fontes as
select
  (select count(*) from doc_fiscal where coalesce(chv_nfe,'') <> '')  as notas_efd,
  (select count(*) from nfe)                                          as notas_xml,
  (select count(distinct d.chv_nfe) from doc_fiscal d
     join nfe n on n.chave = d.chv_nfe)                               as nas_duas,
  (select count(*) from doc_fiscal d where coalesce(d.chv_nfe,'') <> ''
     and not exists (select 1 from nfe n where n.chave = d.chv_nfe))  as so_no_efd,
  (select count(*) from nfe n
     where not exists (select 1 from doc_fiscal d
                       where d.chv_nfe = n.chave))                    as so_no_xml;

comment on view v_cobertura_fontes is
  'Sobreposicao entre EFD e XML. Sem sobreposicao nao ha conciliacao possivel: '
  'o numero aqui diz o quanto do trabalho esta ao alcance.';

-- v_efd_sem_xml  (de 020_conciliacao.sql)
-- =============================================== nota escriturada sem XML
create or replace view v_efd_sem_xml as
select d.cnpj, e.uf, d.chv_nfe as chave, d.num_doc, d.ser as serie, d.cod_mod,
       d.dt_doc, d.vl_doc, d.ind_oper,
       case d.ind_oper when '0' then 'entrada' else 'saida' end as sentido,
       coalesce(p.nome, d.cod_part) as parceiro,
       (select count(*) from doc_item i where i.doc_id = d.id) as itens
from doc_fiscal d
left join estabelecimento e on e.cnpj = d.cnpj
left join sped_participante p on p.cnpj_estab = d.cnpj and p.cod_part = d.cod_part
where coalesce(d.chv_nfe,'') <> ''
  and not exists (select 1 from nfe n where n.chave = d.chv_nfe);

comment on view v_efd_sem_xml is
  'Escriturado no EFD sem o XML correspondente importado. Nao e irregularidade '
  'da empresa: e limite do trabalho — falta o documento para confrontar.';

-- v_xml_sem_efd  (de 020_conciliacao.sql)
-- =============================================== XML sem escrituracao
create or replace view v_xml_sem_efd as
select n.chave, n.num_nf, n.serie, n.modelo, n.dt_emi, n.vl_nf, n.situacao,
       n.emit_cnpj, n.emit_nome, n.dest_doc, n.dest_nome,
       case when exists (select 1 from estabelecimento e where e.cnpj = n.emit_cnpj)
            then 'saida' else 'entrada' end as sentido,
       coalesce(
         (select e.cnpj from estabelecimento e where e.cnpj = n.emit_cnpj),
         (select e.cnpj from estabelecimento e where e.cnpj = n.dest_doc)) as cnpj,
       -- Um EFD do periodo existe? Sem ele, ausencia no EFD nao prova nada.
       exists (select 1 from sped_arquivo a
               where a.vigente and n.dt_emi between a.dt_ini and a.dt_fin
                 and (a.cnpj = n.emit_cnpj or a.cnpj = n.dest_doc)) as periodo_coberto
from nfe n
where not exists (select 1 from doc_fiscal d where d.chv_nfe = n.chave);

comment on view v_xml_sem_efd is
  'XML sem escrituracao correspondente. So e achado quando periodo_coberto e '
  'verdadeiro: sem o EFD daquele mes, a ausencia nao significa nada.';

-- concilia_itens  (de 020_conciliacao.sql)
-- ============================================ conciliacao item a item
create or replace function concilia_itens(p_chave text)
returns table (
  n_item     int,
  cod_efd    text,
  cod_xml    text,
  descr      text,
  qtd_efd    numeric,
  qtd_xml    numeric,
  vl_efd     numeric,
  vl_xml     numeric,
  cfop_efd   text,
  cfop_xml   text,
  situacao   text,
  diferenca  numeric
)
language sql stable as $$
  -- O casamento e por numero do item. O codigo nao serve: no EFD e sempre o
  -- codigo do estabelecimento; no XML de nota recebida e o do fornecedor.
  select
    coalesce(di.num_item::int, ni.n_item)      as n_item,
    di.cod_item, ni.c_prod, coalesce(ni.x_prod, di.cod_item),
    di.qtd, ni.q_com, di.vl_item, ni.v_prod, di.cfop, ni.cfop,
    case
      when di.id is null                       then 'so no XML'
      when ni.id is null                       then 'so no EFD'
      when di.cfop is distinct from ni.cfop    then 'CFOP diferente'
      when abs(coalesce(di.qtd,0) - coalesce(ni.q_com,0)) > 0.001
                                               then 'quantidade diferente'
      when abs(coalesce(di.vl_item,0) - coalesce(ni.v_prod,0)) > 0.01
                                               then 'valor diferente'
      else 'confere'
    end,
    coalesce(di.vl_item,0) - coalesce(ni.v_prod,0)
  from (select * from doc_item x
        where x.doc_id in (select id from doc_fiscal where chv_nfe = p_chave)) di
  full outer join (select * from nfe_item y
        where y.nfe_id in (select id from nfe where chave = p_chave)) ni
    on ni.n_item = di.num_item::int
  order by 1;
$$;

comment on function concilia_itens(text) is
  'Confronta os itens de uma nota entre EFD e XML. Casa por numero do item: o '
  'codigo do produto difere entre as fontes em nota recebida.';

-- v_concilia_divergente  (de 020_conciliacao.sql)
create or replace view v_concilia_divergente as
select d.chv_nfe as chave, d.cnpj, e.uf, d.num_doc, d.dt_doc, c.*
from doc_fiscal d
join estabelecimento e on e.cnpj = d.cnpj
join nfe n on n.chave = d.chv_nfe
cross join lateral concilia_itens(d.chv_nfe) c
where c.situacao <> 'confere';

-- v_transferencia_interna  (de 021_transferencia_pelo_total.sql)
drop view if exists v_transferencia_interna;

create view v_transferencia_interna as
with lados as (
  select d.chv_nfe as chave,
         max(d.num_doc)  as num_doc,
         max(d.dt_doc)   as dt_doc,
         max(d.cnpj)    filter (where d.ind_oper = '1') as cnpj_saida,
         max(d.cnpj)    filter (where d.ind_oper = '0') as cnpj_entrada,
         max(d.vl_doc)  filter (where d.ind_oper = '1') as vl_saida,
         max(d.vl_doc)  filter (where d.ind_oper = '0') as vl_entrada,
         max(d.id)      filter (where d.ind_oper = '1') as doc_saida,
         max(d.id)      filter (where d.ind_oper = '0') as doc_entrada
  from doc_fiscal d
  where coalesce(d.chv_nfe,'') <> ''
    and d.cnpj in (select cnpj from estabelecimento)
  group by d.chv_nfe
  having count(distinct d.cnpj) > 1
)
select l.*,
       (select count(*) from doc_item i where i.doc_id = l.doc_saida)   as itens_saida,
       (select count(*) from doc_item i where i.doc_id = l.doc_entrada) as itens_entrada,
       round(coalesce(l.vl_saida,0) - coalesce(l.vl_entrada,0), 2)      as dif_valor
from lados l;

comment on view v_transferencia_interna is
  'Nota escriturada por duas filiais do grupo: uma como saida, outra como '
  'entrada. Divergencia entre as duas versoes e erro de escrituracao interno.';

-- v_transferencia_divergente  (de 021_transferencia_pelo_total.sql)
create view v_transferencia_divergente as
select * from v_transferencia_interna
where vl_saida is not null and vl_entrada is not null
  and abs(dif_valor) > 0.01;

comment on view v_transferencia_divergente is
  'Mesma nota com total diferente nas duas escrituracoes. Compara o valor do '
  'documento (C100), presente nos dois lados — nao a soma dos itens, que so '
  'existe na entrada.';

-- v_cobertura_item  (de 021_transferencia_pelo_total.sql)
-- A ausencia de detalhe e limite do trabalho, nao erro da empresa. Vira um
-- achado proprio, com natureza informativa, para constar do papel de trabalho.
create or replace view v_cobertura_item as
select d.cnpj, e.uf, a.ind_perfil,
       count(*) filter (where d.ind_oper = '1') as saidas,
       count(*) filter (where d.ind_oper = '1'
         and (select count(*) from doc_item i where i.doc_id = d.id) = 0) as saidas_sem_item,
       count(*) filter (where d.ind_oper = '0') as entradas,
       count(*) filter (where d.ind_oper = '0'
         and (select count(*) from doc_item i where i.doc_id = d.id) = 0) as entradas_sem_item
from doc_fiscal d
join sped_arquivo a on a.id = d.arquivo_id
left join estabelecimento e on e.cnpj = d.cnpj
group by d.cnpj, e.uf, a.ind_perfil;

comment on view v_cobertura_item is
  'Quanto do movimento tem detalhe por item. Saida raramente tem: a escrituracao '
  'usa o analitico C190. Sem C170, o Kardex depende do XML.';

-- importar_efd  (de 025_cast_num_item.sql)
-- 025 — Cast do numero do item na importacao por JSON.
--
-- doc_item.num_item e inteiro; o parser entrega texto, porque no SPED o campo
-- NUM_ITEM vem como string. jsonb_to_recordset nao converte sozinho e a
-- importacao falhava com "column num_item is of type integer but expression is
-- of type text" — mas so no caminho de gravacao, nunca no de idempotencia, que
-- retorna antes de chegar aqui. Por isso o primeiro teste passou.

create or replace function importar_efd(p jsonb)
returns jsonb
language plpgsql as $$
declare
  a        jsonb := p->'arquivo';
  v_sha    text  := a->>'sha256';
  v_cnpj   text  := a->>'cnpj';
  v_dt_ini date  := (a->>'dt_ini')::date;
  v_dt_fin date  := (a->>'dt_fin')::date;
  v_id     bigint; v_inv bigint; v_ja bigint; v_ant int := 0;
  d        jsonb;  v_doc bigint; v_cont jsonb := '{}'::jsonb;
begin
  select id into v_ja from sped_arquivo where sha256 = v_sha;
  if v_ja is not null then
    return jsonb_build_object('situacao','ja_importado','arquivo_id',v_ja);
  end if;

  insert into estabelecimento (cnpj, nome, uf, ie)
  values (v_cnpj, a->>'nome_empresa', a->>'uf', a->>'ie')
  on conflict (cnpj) do update set nome = excluded.nome, uf = excluded.uf,
                                   ie = excluded.ie;

  select count(*) into v_ant from sped_arquivo
   where cnpj = v_cnpj and dt_ini = v_dt_ini and dt_fin = v_dt_fin and vigente;

  insert into sped_arquivo (nome_arquivo, cnpj, nome_empresa, uf, ie, dt_ini,
    dt_fin, cod_fin, cod_ver, ind_perfil, ind_ativ, sha256, importado_por,
    linhas_lidas, contagem_reg, problemas, versao_motor)
  values (a->>'nome_arquivo', v_cnpj, a->>'nome_empresa', a->>'uf', a->>'ie',
          v_dt_ini, v_dt_fin, a->>'cod_fin', a->>'cod_ver', a->>'ind_perfil',
          a->>'ind_ativ', v_sha, a->>'importado_por',
          (a->>'linhas_lidas')::int, a->'contagem', a->'problemas',
          a->>'versao_motor')
  returning id into v_id;

  update sped_arquivo set vigente = false, substituido_por = v_id
   where cnpj = v_cnpj and dt_ini = v_dt_ini and dt_fin = v_dt_fin
     and vigente and id <> v_id;

  insert into sped_unidade (arquivo_id, cnpj, unid, descr, linha_arquivo)
  select v_id, v_cnpj, x.unid, x.descr, x.linha
  from jsonb_to_recordset(coalesce(p->'unidades','[]'))
       as x(unid text, descr text, linha int)
  on conflict do nothing;

  insert into sped_participante (arquivo_id, cnpj_estab, cod_part, nome,
         cod_pais, cnpj, cpf, ie, cod_mun, linha_arquivo)
  select v_id, v_cnpj, x.cod_part, x.nome, x.cod_pais, x.cnpj, x.cpf, x.ie,
         x.cod_mun, x.linha
  from jsonb_to_recordset(coalesce(p->'participantes','[]'))
       as x(cod_part text, nome text, cod_pais text, cnpj text, cpf text,
            ie text, cod_mun text, linha int)
  on conflict do nothing;

  insert into sped_item (arquivo_id, cnpj_estab, cod_item, descr_item,
         descr_norm, cod_barra, unid_inv, tipo_item, ncm, ex_ipi, cod_gen,
         cod_lst, aliq_icms, cest, linha_arquivo)
  select v_id, v_cnpj, x.cod_item, x.descr_item, x.descr_norm, x.cod_barra,
         x.unid_inv, x.tipo_item, x.ncm, x.ex_ipi, x.cod_gen, x.cod_lst,
         x.aliq_icms, x.cest, x.linha
  from jsonb_to_recordset(coalesce(p->'itens','[]'))
       as x(cod_item text, descr_item text, descr_norm text, cod_barra text,
            unid_inv text, tipo_item text, ncm text, ex_ipi text, cod_gen text,
            cod_lst text, aliq_icms numeric, cest text, linha int)
  on conflict do nothing;

  if p->'inventario' is not null and p->'inventario' <> 'null'::jsonb then
    insert into inventario (arquivo_id, cnpj, dt_inv, vl_inv, mot_inv, linha_arquivo)
    values (v_id, v_cnpj, (p->'inventario'->>'dt_inv')::date,
            (p->'inventario'->>'vl_inv')::numeric, p->'inventario'->>'mot_inv',
            (p->'inventario'->>'linha')::int)
    returning id into v_inv;

    insert into inventario_item (inventario_id, cnpj, dt_inv, cod_item, unid,
           qtd, vl_unit, vl_item, ind_prop, cod_part, txt_compl, cod_cta,
           vl_item_ir, linha_arquivo)
    select v_inv, v_cnpj, (p->'inventario'->>'dt_inv')::date, x.cod_item,
           x.unid, x.qtd, x.vl_unit, x.vl_item, x.ind_prop, x.cod_part,
           x.txt_compl, x.cod_cta, x.vl_item_ir, x.linha
    from jsonb_to_recordset(coalesce(p->'inventario_itens','[]'))
         as x(cod_item text, unid text, qtd numeric, vl_unit numeric,
              vl_item numeric, ind_prop text, cod_part text, txt_compl text,
              cod_cta text, vl_item_ir numeric, linha int);
  end if;

  for d in select * from jsonb_array_elements(coalesce(p->'documentos','[]'))
  loop
    insert into doc_fiscal (arquivo_id, cnpj, ind_oper, ind_emit, cod_part,
           cod_mod, cod_sit, ser, num_doc, chv_nfe, dt_doc, dt_e_s, vl_doc,
           linha_arquivo)
    values (v_id, v_cnpj, d->>'ind_oper', d->>'ind_emit', d->>'cod_part',
            d->>'cod_mod', d->>'cod_sit', d->>'ser', d->>'num_doc',
            d->>'chv_nfe', (d->>'dt_doc')::date, (d->>'dt_e_s')::date,
            (d->>'vl_doc')::numeric, (d->>'linha')::int)
    returning id into v_doc;

    insert into doc_item (doc_id, arquivo_id, cnpj, num_item, cod_item, qtd,
           unid, vl_item, vl_desc, cfop, cst_icms, dt_doc, ind_oper,
           linha_arquivo)
    select v_doc, v_id, v_cnpj, nullif(x.num_item,'')::int, x.cod_item, x.qtd,
           x.unid, x.vl_item, x.vl_desc, x.cfop, x.cst_icms,
           (d->>'dt_doc')::date, d->>'ind_oper', x.linha
    from jsonb_to_recordset(coalesce(d->'itens','[]'))
         as x(num_item text, cod_item text, qtd numeric, unid text,
              vl_item numeric, vl_desc numeric, cfop text, cst_icms text,
              linha int);
  end loop;

  insert into importacao_problema (arquivo_id, tipo, detalhe)
  select v_id, x.tipo, x.detalhe
  from jsonb_to_recordset(coalesce(a->'problemas','[]'))
       as x(tipo text, detalhe text);

  select jsonb_build_object(
    '0190', (select count(*) from sped_unidade where arquivo_id = v_id),
    '0150', (select count(*) from sped_participante where arquivo_id = v_id),
    '0200', (select count(*) from sped_item where arquivo_id = v_id),
    'H010', coalesce((select count(*) from inventario_item where inventario_id = v_inv),0),
    'C100', (select count(*) from doc_fiscal where arquivo_id = v_id),
    'C170', (select count(*) from doc_item where arquivo_id = v_id))
  into v_cont;

  return jsonb_build_object(
    'situacao', case when v_ant > 0 then 'substituiu' else 'importado' end,
    'arquivo_id', v_id, 'contagens', v_cont);
end $$;

comment on function importar_efd(jsonb) is
  'Importa um EFD ja parseado, em uma chamada e uma transacao. O parser fica em '
  'Python, onde tem teste golden; aqui entra so a gravacao.';

-- importar_nfe  (de 024_importar_nfe_json.sql)
-- 024 — Importacao de NF-e em uma chamada.
--
-- Mesmo desenho do EFD: o parser continua em Python e o banco recebe o
-- resultado inteiro. Uma nota fiscal fazia de 5 a 15 chamadas; agora faz uma.

create or replace function importar_nfe(p jsonb)
returns jsonb
language plpgsql as $$
declare
  v_chave  text := p->>'chave';
  v_sha    text := p->>'sha256';
  v_ja     record;
  v_id     bigint;
  v_movs   int := 0;
  v_pend   int := 0;
  it       jsonb;
  v_item   bigint;
  v_cnpj   text;
  v_sent   text;
  v_ef     record;
  v_cod    text;
  v_fator  numeric;
  v_parc   text;
  v_qtd    numeric;
  v_vu     numeric;
begin
  select id, sha256 into v_ja from nfe where chave = v_chave;
  if v_ja.id is not null then
    return jsonb_build_object('situacao',
      case when v_ja.sha256 = v_sha then 'ja_importada' else 'conflito' end,
      'nfe_id', v_ja.id);
  end if;

  -- So interessa nota em que um estabelecimento auditado e parte.
  if not exists (select 1 from estabelecimento e
                 where e.cnpj = p->>'emit_cnpj' or e.cnpj = p->>'dest_doc') then
    return jsonb_build_object('situacao','fora_do_grupo');
  end if;

  insert into nfe (chave, sha256, nome_arquivo, modelo, serie, num_nf, dh_emi,
         dt_emi, tp_nf, fin_nfe, nat_op, emit_cnpj, emit_nome, emit_uf,
         dest_doc, dest_nome, dest_uf, vl_nf, vl_prod, situacao, importado_por,
         versao_motor)
  values (v_chave, v_sha, p->>'nome_arquivo', p->>'modelo', p->>'serie',
          p->>'num_nf', (p->>'dh_emi')::timestamptz, (p->>'dt_emi')::date,
          p->>'tp_nf', p->>'fin_nfe', p->>'nat_op', p->>'emit_cnpj',
          p->>'emit_nome', p->>'emit_uf', p->>'dest_doc', p->>'dest_nome',
          p->>'dest_uf', (p->>'vl_nf')::numeric, (p->>'vl_prod')::numeric,
          p->>'situacao', p->>'importado_por', p->>'versao_motor')
  returning id into v_id;

  for it in select * from jsonb_array_elements(coalesce(p->'itens','[]'))
  loop
    insert into nfe_item (nfe_id, n_item, c_prod, c_ean, x_prod, x_prod_norm,
           ncm, cest, cfop, u_com, q_com, v_un_com, v_prod, u_trib, q_trib,
           v_desc, v_frete, v_seg, v_outro, ind_tot, cst_icms)
    values (v_id, (it->>'n_item')::int, it->>'c_prod', it->>'c_ean',
            it->>'x_prod', it->>'x_prod_norm', it->>'ncm', it->>'cest',
            it->>'cfop', it->>'u_com', (it->>'q_com')::numeric,
            (it->>'v_un_com')::numeric, (it->>'v_prod')::numeric,
            it->>'u_trib', (it->>'q_trib')::numeric, (it->>'v_desc')::numeric,
            (it->>'v_frete')::numeric, (it->>'v_seg')::numeric,
            (it->>'v_outro')::numeric, it->>'ind_tot', it->>'cst_icms')
    returning id into v_item;

    if p->>'situacao' <> 'autorizada' then continue; end if;

    select * into v_ef from cfop_efeito where cfop = it->>'cfop';
    if v_ef.cfop is null then continue; end if;

    -- Cada estabelecimento auditado envolvido gera o seu proprio movimento.
    for v_cnpj, v_sent in
      select e.cnpj, case when e.cnpj = p->>'emit_cnpj' then 'saida' else 'entrada' end
      from estabelecimento e
      where e.cnpj = p->>'emit_cnpj' or e.cnpj = p->>'dest_doc'
    loop
      v_parc := case when v_sent = 'saida' then p->>'dest_doc' else p->>'emit_cnpj' end;
      v_cod := null; v_fator := 1;

      if v_sent = 'saida' then
        -- Nota nossa: o cProd E o nosso codigo, por definicao.
        v_cod := it->>'c_prod';
      else
        select cod_item, fator_unidade into v_cod, v_fator from item_depara
         where cnpj = v_cnpj and c_prod_externo = it->>'c_prod'
           and (parceiro_doc = v_parc or parceiro_doc is null)
         limit 1;
      end if;

      if v_cod is null then
        insert into item_pendente (cnpj, parceiro_doc, parceiro_nome,
               c_prod_externo, x_prod, ncm, u_com, ocorrencias, qtd_total,
               vl_total, primeira_chave)
        values (v_cnpj, v_parc,
                case when v_sent = 'entrada' then p->>'emit_nome' else p->>'dest_nome' end,
                it->>'c_prod', it->>'x_prod', it->>'ncm', it->>'u_com', 1,
                (it->>'q_com')::numeric, (it->>'v_prod')::numeric, v_chave)
        on conflict (cnpj, parceiro_doc, c_prod_externo) do update set
          ocorrencias = item_pendente.ocorrencias + 1,
          qtd_total = coalesce(item_pendente.qtd_total,0) + excluded.qtd_total,
          vl_total  = coalesce(item_pendente.vl_total,0) + excluded.vl_total;
        v_pend := v_pend + 1;
        continue;
      end if;

      v_qtd := (it->>'q_com')::numeric * coalesce(v_fator,1);
      if v_qtd is null or v_qtd <= 0 then continue; end if;
      v_vu := (it->>'v_prod')::numeric / v_qtd;

      insert into movimento (cnpj, dt, cod_item, origem, nfe_id, nfe_item_id,
             chave, n_item, cfop, efeito, qtd, vl_unit, vl_total, ind_prop,
             observacao)
      select v_cnpj, (p->>'dt_emi')::date, v_cod, 'nfe', v_id, v_item, v_chave,
             (it->>'n_item')::int, it->>'cfop', v_ef.efeito, m.q, v_vu,
             abs(m.q) * v_vu, m.prop, v_sent || ' · ' || v_ef.descricao
      from (values
        (case v_ef.efeito when 'soma' then v_qtd when 'baixa' then -v_qtd
              when 'para_terceiros' then -v_qtd when 'de_terceiros' then v_qtd end,
         case v_ef.efeito when 'de_terceiros' then '0' else '0' end),
        (case v_ef.efeito when 'para_terceiros' then v_qtd
              when 'de_terceiros' then -v_qtd end, '1')
      ) as m(q, prop)
      where m.q is not null;
      get diagnostics v_movs = row_count;
    end loop;
  end loop;

  select count(*) into v_movs from movimento where nfe_id = v_id;
  return jsonb_build_object('situacao','importada','nfe_id',v_id,
                            'movimentos',v_movs,'pendencias',v_pend);
end $$;

comment on function importar_nfe(jsonb) is
  'Importa uma NF-e ja parseada, em uma chamada e uma transacao, gerando os '
  'movimentos conforme a tabela de efeitos do CFOP.';

-- relatorio_achados  (de 022_achados_conciliacao.sql)
-- 022 — As conciliacoes viram achado.
--
-- Agregadas por estabelecimento, nao uma por nota: 191 achados dizendo "falta
-- o XML desta nota" seria ruido. Um achado por filial dizendo quantas faltam e
-- acionavel — o auditor pede o lote, nao a nota avulsa.
--
-- A NF-e autorizada e nao escriturada e a excecao: essa vai uma a uma, porque
-- cada caso e um documento especifico a explicar.

create or replace function relatorio_achados(p_data date)
returns table (
  tipo text, severidade text, ordem int, uf text, cnpj text, cod_item text,
  descr_item text, quantidade numeric, valor numeric, motivo text, prova text
)
language sql stable as $$
  select 'valoracao', 'critico', 1,
         d.uf, d.cnpj, d.cod_item, d.descr_item, d.qtd, d.exposicao, d.motivo,
         'Registro H010, linha ' || d.linha_arquivo || ' de ' || d.nome_arquivo
           || ' (sha ' || d.sha_arquivo || '). Documento de entrada: CFOP '
           || d.cfops || ', ' || d.documentos || ' nota(s).'
  from v_divergencia_detalhe d

  union all
  select 'saldo_negativo',
         case when e.valor < 0 then 'alto' else 'medio' end, 2,
         e.uf, e.cnpj, e.cod_item, e.descr_item, e.qtd, e.valor,
         'Saldo de ' || fmt_br_int(e.qtd) || ' ' || unid_legivel(e.unid)
           || ' em ' || to_char(p_data,'DD/MM/YYYY') || ' apos '
           || e.movimentos || ' movimento(s). '
           || case when e.valor = 0
                then 'O item nunca teve entrada registrada: so ha saidas. '
                     || 'Indica nota de compra ou transferencia nao importada.'
                else 'O item tinha saldo e ficou negativo, o que significa '
                     || 'saida maior que a disponibilidade. Exige conferencia '
                     || 'das quantidades das notas.' end,
         'Origem do cadastro: ' || e.origem_cadastro
           || '. Ultimo movimento em ' || to_char(e.ultima_mov,'DD/MM/YYYY') || '.'
  from estoque_em_detalhe(p_data) e
  where e.qtd < 0

  union all
  select 'terceiros', 'alto', 3,
         v.uf, v.cnpj, null, v.depositario, null, sum(v.vl_item),
         'Sao ' || count(*) || ' itens, no valor de R$ ' || fmt_br(sum(v.vl_item))
           || ', declarados como de propriedade da empresa mas em poder de '
           || coalesce(v.depositario, 'terceiro nao identificado')
           || ' (IND_PROP = 1). O inventario declara a posse; nao a comprova.',
         'Registros H010 com IND_PROP = 1 e COD_PART preenchido.'
  from v_inventario v
  where v.ind_prop = '1'
  group by v.uf, v.cnpj, v.depositario

  union all
  select 'cfop_aberto', 'alto', 4,
         null, null, c.cfop, 'CFOP ' || c.cfop, c.ocorrencias, c.valor,
         'O CFOP ' || c.cfop || ' aparece em ' || c.notas || ' nota(s), '
           || c.ocorrencias || ' item(ns), mas nao esta na tabela de efeitos. '
           || 'Enquanto isso, esses itens NAO geram movimento e o saldo '
           || 'apurado esta incompleto.',
         'Primeira ocorrencia em ' || to_char(c.primeira,'DD/MM/YYYY')
           || ', ultima em ' || to_char(c.ultima,'DD/MM/YYYY') || '.'
  from v_cfop_nao_classificado c

  union all
  select 'item_pendente', 'medio', 5,
         null, p.cnpj, p.c_prod_externo, p.x_prod, p.qtd_total, p.vl_total,
         'O codigo ' || p.c_prod_externo || ' de '
           || coalesce(p.parceiro_nome, p.parceiro_doc, 'fornecedor')
           || ' aparece em ' || p.ocorrencias || ' lancamento(s) e ainda nao foi '
           || 'ligado a um item do cadastro. Sem esse de-para a entrada nao '
           || 'chega ao Kardex.',
         'Primeira nota: chave ' || coalesce(p.primeira_chave,'-') || '.'
  from item_pendente p
  where p.status = 'aberto'

  -- ---------------------------------------------- conciliacao EFD x XML
  union all
  select 'sem_documento', 'alto', 6,
         x.uf, x.cnpj, null,
         'Notas escrituradas sem o XML correspondente',
         count(*)::numeric, sum(x.vl_doc),
         'Sao ' || count(*) || ' notas escrituradas no EFD, somando R$ '
           || fmt_br(sum(x.vl_doc)) || ', para as quais o XML nao foi importado. '
           || 'Sem o documento nao ha como confrontar o que foi declarado com o '
           || 'que foi emitido — que e o teste mais forte de uma auditoria '
           || 'fiscal. Nao e irregularidade da empresa: e limite do trabalho.',
         'Periodo de ' || to_char(min(x.dt_doc),'DD/MM/YYYY') || ' a '
           || to_char(max(x.dt_doc),'DD/MM/YYYY') || '. Solicitar o lote de XML.'
  from v_efd_sem_xml x
  group by x.uf, x.cnpj

  union all
  select 'nao_escriturada', 'critico', 7,
         null, x.cnpj, x.chave, x.emit_nome, 1::numeric, x.vl_nf,
         'A NF-e ' || x.num_nf || '/' || x.serie || ' de '
           || to_char(x.dt_emi,'DD/MM/YYYY') || ', no valor de R$ '
           || fmt_br(x.vl_nf) || ', existe como documento autorizado mas NAO '
           || 'foi encontrada na escrituracao — e o EFD daquele periodo esta '
           || 'carregado. Documento emitido e nao escriturado.',
         'Chave ' || x.chave || '. Situacao no protocolo: ' || x.situacao || '.'
  from v_xml_sem_efd x
  where x.periodo_coberto

  union all
  select 'transferencia_divergente', 'critico', 8,
         null, t.cnpj_saida, t.num_doc,
         'Transferencia com total diferente nas duas escrituracoes',
         1::numeric, abs(t.dif_valor),
         'A NF ' || t.num_doc || ' de ' || to_char(t.dt_doc,'DD/MM/YYYY')
           || ' foi escriturada por R$ ' || fmt_br(t.vl_saida) || ' na saida e '
           || 'por R$ ' || fmt_br(t.vl_entrada) || ' na entrada. A mesma '
           || 'operacao nao pode ter dois valores.',
         'Saida em ' || t.cnpj_saida || ', entrada em ' || t.cnpj_entrada || '.'
  from v_transferencia_divergente t

  union all
  select 'cobertura_item', 'informativo', 9,
         c.uf, c.cnpj, null,
         'Movimento sem detalhe por item na escrituracao',
         (c.saidas_sem_item + c.entradas_sem_item)::numeric, null,
         'Das ' || c.saidas || ' saidas escrituradas, ' || c.saidas_sem_item
           || ' nao trazem o registro C170. Na saida a escrituracao usa o '
           || 'analitico C190, por CST e CFOP, sem detalhe por item. O Kardex '
           || 'dessas operacoes depende do XML da nota.',
         'Estabelecimento de perfil ' || c.ind_perfil || '.'
  from v_cobertura_item c
  where c.saidas_sem_item > 0 or c.entradas_sem_item > 0

  union all
  select 'ressalva', 'informativo', 10,
         null, null, r.tipo, r.tipo, r.qtd_itens, r.valor, r.descricao,
         'Decidido por ' || coalesce(r.decidido_por,'-') || ' em '
           || to_char(r.decidido_em,'DD/MM/YYYY') || '.'
  from auditoria_ressalva r

  order by 3, 9 desc nulls last;
$$;
