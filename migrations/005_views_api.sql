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

create or replace view v_filiais as
select c.uf, c.cnpj, e.nome, c.qtd_itens, c.qtd_total,
       c.vl_somado_h010 as valor, c.vl_declarado_h005 as declarado, c.diferenca
from v_inventario_conferencia c
join estabelecimento e on e.cnpj = c.cnpj;

create or replace view v_terceiros as
select uf, cnpj, depositario, count(*) as itens, sum(vl_item) as valor
from v_inventario where ind_prop = '1'
group by uf, cnpj, depositario;

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

create or replace view v_notas as
select n.chave, n.num_nf, n.serie, n.dt_emi, n.nat_op, n.emit_cnpj, n.emit_nome,
       n.dest_doc, n.dest_nome, n.vl_nf, n.situacao, n.nome_arquivo,
       (select count(*) from nfe_item i where i.nfe_id = n.id)  as itens,
       (select count(*) from movimento m where m.nfe_id = n.id) as movs
from nfe n;

-- A busca do inventario precisa de filtro por texto. O PostgREST faz isso com
-- ilike sobre a view, entao basta expor uma coluna concatenada para pesquisa.
create or replace view v_inventario_busca as
select v.*,
       upper(coalesce(v.descr_item,'') || ' ' || v.cod_item || ' ' ||
             coalesce(v.ncm,'')) as busca
from v_inventario v;

comment on view v_inventario_busca is
  'v_inventario com uma coluna concatenada para o PostgREST filtrar por ilike.';
