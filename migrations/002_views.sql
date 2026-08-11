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
