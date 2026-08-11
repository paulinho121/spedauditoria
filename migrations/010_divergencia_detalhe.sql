-- 010 — Divergencia de valoracao com motivo e documento de prova.
--
-- A view v_custo_inventario_vs_entrada dizia QUANTO divergia, mas nao POR QUE
-- nem COM BASE EM QUE. Numa ferramenta de auditoria o numero sozinho nao
-- sustenta o achado: e preciso apontar a nota, a data e a linha do arquivo.

create or replace view v_divergencia_detalhe as
with ent as (
  select di.cnpj, di.cod_item,
         sum(di.qtd)                          as qtd_entrada,
         sum(di.vl_item)                      as vl_entrada,
         sum(di.vl_item) / nullif(sum(di.qtd),0) as custo_entrada,
         min(di.dt_doc)                       as primeira_entrada,
         max(di.dt_doc)                       as ultima_entrada,
         count(distinct di.doc_id)            as documentos,
         string_agg(distinct di.cfop, ', ')   as cfops
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
  -- Motivo em texto: e o que vai para o papel de trabalho.
  'Inventariado a R$ ' || to_char(v.vl_unit, 'FM999G999G990D00')
    || ' por unidade. O mesmo item entrou no estabelecimento em '
    || to_char(e.ultima_entrada, 'DD/MM/YYYY') || ' por R$ '
    || to_char(e.custo_entrada, 'FM999G999G990D00') || ' — '
    || to_char(round(e.custo_entrada / nullif(v.vl_unit,0), 0), 'FM999G990')
    || ' vezes o valor inventariado. Como o custo de entrada e documentado por '
    || 'nota fiscal, o inventario esta subavaliado nesse item.'      as motivo
from v_inventario v
join ent e on e.cnpj = v.cnpj and e.cod_item = v.cod_item
join inventario i on i.cnpj = v.cnpj
join inventario_item ii on ii.inventario_id = i.id and ii.cod_item = v.cod_item
join sped_arquivo a on a.id = i.arquivo_id and a.vigente
where v.vl_unit > 0 and e.custo_entrada / v.vl_unit >= 2;

comment on view v_divergencia_detalhe is
  'Divergencia de valoracao com motivo em texto e a trilha ate a linha do '
  'arquivo. Alimenta o painel de detalhe do dashboard.';


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
