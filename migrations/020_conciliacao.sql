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

create or replace view v_concilia_divergente as
select d.chv_nfe as chave, d.cnpj, e.uf, d.num_doc, d.dt_doc, c.*
from doc_fiscal d
join estabelecimento e on e.cnpj = d.cnpj
join nfe n on n.chave = d.chv_nfe
cross join lateral concilia_itens(d.chv_nfe) c
where c.situacao <> 'confere';

-- ====================================== transferencia entre filiais
-- A mesma nota escriturada dos dois lados: saida numa filial, entrada na outra.
-- Confrontar as duas versoes e conciliacao interna, sem depender de XML.
create or replace view v_transferencia_interna as
with pares as (
  select d.chv_nfe as chave,
         max(d.cnpj) filter (where d.ind_oper = '1') as cnpj_saida,
         max(d.cnpj) filter (where d.ind_oper = '0') as cnpj_entrada,
         max(d.id)   filter (where d.ind_oper = '1') as doc_saida,
         max(d.id)   filter (where d.ind_oper = '0') as doc_entrada,
         max(d.num_doc) as num_doc, max(d.dt_doc) as dt_doc
  from doc_fiscal d
  where coalesce(d.chv_nfe,'') <> ''
    and d.cnpj in (select cnpj from estabelecimento)
  group by d.chv_nfe
  having count(distinct d.cnpj) > 1
)
select p.*,
       (select coalesce(sum(qtd),0) from doc_item where doc_id = p.doc_saida)   as qtd_saida,
       (select coalesce(sum(qtd),0) from doc_item where doc_id = p.doc_entrada) as qtd_entrada,
       (select coalesce(sum(vl_item),0) from doc_item where doc_id = p.doc_saida)   as vl_saida,
       (select coalesce(sum(vl_item),0) from doc_item where doc_id = p.doc_entrada) as vl_entrada
from pares p;

comment on view v_transferencia_interna is
  'Nota escriturada por duas filiais do grupo: uma como saida, outra como '
  'entrada. Divergencia entre as duas versoes e erro de escrituracao interno.';

create or replace view v_transferencia_divergente as
select *,
       round(qtd_saida - qtd_entrada, 3) as dif_qtd,
       round(vl_saida - vl_entrada, 2)   as dif_valor
from v_transferencia_interna
where abs(qtd_saida - qtd_entrada) > 0.001
   or abs(vl_saida - vl_entrada) > 0.01;
