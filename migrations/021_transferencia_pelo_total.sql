-- 021 — Transferencia entre filiais se concilia pelo total, nao pelo item.
--
-- A versao anterior somava doc_item dos dois lados e acusou divergencia nas 25
-- notas — todas com "saida = 0". Investigando: NENHUMA saida tem C170, nem em
-- SP que e perfil A. Sao 110 saidas, todas sem detalhe por item. Na escrituracao
-- de saida o estabelecimento lanca o analitico C190 por CST e CFOP, nao o item.
--
-- Comparar soma de itens contra zero produzia 25 achados falsos com aparencia
-- de certeza. O que ambos os lados tem e o total do documento, no C100.

-- Colunas mudam de ordem: create or replace nao renomeia coluna de view.
drop view if exists v_transferencia_divergente;
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

create view v_transferencia_divergente as
select * from v_transferencia_interna
where vl_saida is not null and vl_entrada is not null
  and abs(dif_valor) > 0.01;

comment on view v_transferencia_divergente is
  'Mesma nota com total diferente nas duas escrituracoes. Compara o valor do '
  'documento (C100), presente nos dois lados — nao a soma dos itens, que so '
  'existe na entrada.';

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
