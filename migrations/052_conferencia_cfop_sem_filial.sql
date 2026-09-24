-- 052 — Conferencia por CFOP com a filial opcional.
--
-- Na 051 o CNPJ era obrigatorio no detalhe, e a tela consolidada (sem filial
-- escolhida) nao conseguia abrir o CFOP. Aqui o CNPJ passa a ter padrao nulo,
-- que ja significa "o grupo inteiro". Como argumento com padrao vem depois,
-- a ordem muda e a assinatura antiga sai.

drop function if exists conferencia_cfop_itens(date, date, text, text, text);
drop function if exists conferencia_cfop_notas(date, date, text, text, text);

create or replace function conferencia_cfop_itens(
  p_ini date, p_fim date, p_cfop text,
  p_cnpj text default null, p_lado text default null)
returns table (
  cnpj text, uf text, cod_item text, descr_item text, unid text,
  notas bigint, linhas bigint, qtd_entrada numeric, qtd_saida numeric,
  qtd_de_terceiro numeric, qtd_sem_movimento numeric, valor numeric
)
language sql stable as $$
  with linha as (
    select v.id nfe_id, i.id item_id, i.q_com, coalesce(i.v_prod,0) v_prod,
           e.cnpj, e.uf, i.c_prod, i.u_com
      from nfe v
      join nfe_item i on i.nfe_id = v.id
      join estabelecimento e on e.cnpj in (v.emit_cnpj, v.dest_doc)
     where v.situacao = 'autorizada' and v.dt_emi between p_ini and p_fim
       and i.cfop = p_cfop
       and (p_cnpj is null or e.cnpj = p_cnpj)
       and (p_lado is null
            or (case when e.cnpj = v.emit_cnpj then 'emitente' else 'destino' end) = p_lado)
  ), mov as (
    select m.nfe_item_id, m.cnpj, min(m.cod_item) cod_item,
           coalesce(sum(m.qtd) filter (where m.ind_prop = '0' and m.qtd > 0), 0) ent,
           coalesce(-sum(m.qtd) filter (where m.ind_prop = '0' and m.qtd < 0), 0) sai,
           coalesce(sum(m.qtd) filter (where m.ind_prop = '2'), 0) terc
      from movimento m
     where m.dt between p_ini and p_fim and m.nfe_item_id is not null
     group by 1, 2
  ), somado as (
    select l.cnpj, l.uf, coalesce(m.cod_item, l.c_prod) cod_item, min(l.u_com) unid,
           count(distinct l.nfe_id)::bigint notas, count(*)::bigint linhas,
           coalesce(sum(m.ent), 0) ent, coalesce(sum(m.sai), 0) sai,
           coalesce(sum(m.terc), 0) terc,
           coalesce(sum(l.q_com) filter (where m.nfe_item_id is null), 0) parado,
           round(sum(l.v_prod), 2) valor
      from linha l
      left join mov m on m.nfe_item_id = l.item_id and m.cnpj = l.cnpj
     group by l.cnpj, l.uf, coalesce(m.cod_item, l.c_prod)
  )
  select s.cnpj, s.uf, s.cod_item,
         coalesce((select x.descr_item from sped_item x
                    where x.cnpj_estab = s.cnpj and x.cod_item = s.cod_item limit 1),
                  (select k.descr_item from item_cadastro_nfe k
                    where k.cnpj = s.cnpj and k.cod_item = s.cod_item limit 1)),
         s.unid, s.notas, s.linhas, s.ent, s.sai, s.terc, s.parado, s.valor
    from somado s
   order by s.valor desc;
$$;
comment on function conferencia_cfop_itens(date, date, text, text, text) is
  'Itens movimentados por um CFOP no periodo. qtd_sem_movimento e o que a nota '
  'mandou e o estoque nao registrou.';


create or replace function conferencia_cfop_notas(
  p_ini date, p_fim date, p_cfop text,
  p_cnpj text default null, p_lado text default null)
returns table (
  nfe_id bigint, num_nf text, dt_emi date, cnpj text, lado text,
  contraparte text, nat_op text, linhas bigint, qtd numeric,
  valor numeric, linhas_com_movimento bigint
)
language sql stable as $$
  select v.id, v.num_nf, v.dt_emi, e.cnpj,
         case when e.cnpj = v.emit_cnpj then 'emitente' else 'destino' end,
         case when e.cnpj = v.emit_cnpj then v.dest_nome else v.emit_nome end,
         v.nat_op, count(*)::bigint, coalesce(sum(i.q_com), 0),
         round(coalesce(sum(i.v_prod), 0), 2),
         count(*) filter (where exists (select 1 from movimento m
                                         where m.nfe_item_id = i.id and m.cnpj = e.cnpj))::bigint
    from nfe v
    join nfe_item i on i.nfe_id = v.id
    join estabelecimento e on e.cnpj in (v.emit_cnpj, v.dest_doc)
   where v.situacao = 'autorizada' and v.dt_emi between p_ini and p_fim
     and i.cfop = p_cfop
     and (p_cnpj is null or e.cnpj = p_cnpj)
     and (p_lado is null
          or (case when e.cnpj = v.emit_cnpj then 'emitente' else 'destino' end) = p_lado)
   group by v.id, v.num_nf, v.dt_emi, e.cnpj, 5, 6, v.nat_op
   order by v.dt_emi, v.num_nf;
$$;
comment on function conferencia_cfop_notas(date, date, text, text, text) is
  'Notas de um CFOP no periodo, pelo lado da filial, com quantas linhas de cada '
  'uma chegaram a movimentar estoque.';
