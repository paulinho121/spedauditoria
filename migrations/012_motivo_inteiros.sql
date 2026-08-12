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
