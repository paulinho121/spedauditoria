-- 051 — Conferencia do estoque por CFOP.
--
-- Para conferir o estoque de um mes, o auditor precisa ver a movimentacao
-- separada por operacao: quanto entrou e saiu em cada CFOP, e — o que importa
-- tanto quanto — quantas linhas daquele CFOP NAO geraram movimento.
--
-- A base e a linha de nota, e nao o movimento: assim o CFOP que nao movimenta
-- estoque (simbolico, fora de escopo, remessa vista pelo destino) aparece na
-- lista com zero, em vez de sumir. Quem confere precisa ver que ele foi
-- considerado, e nao esquecido.
--
-- Cada linha e vista pelo lado da filial: a nota entre filiais aparece uma vez
-- como saida em quem emitiu e outra como entrada em quem recebeu.
--
-- Os movimentos sao somados POR LINHA antes de juntar. Uma linha de remessa
-- gera duas (sai do proprio, entra em poder de terceiro); juntar direto
-- contaria o valor da nota duas vezes. E o bem de terceiro, que so tem linha
-- de ind_prop 2, apareceria como "sem movimento".

create or replace function conferencia_cfop(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  cfop text, descricao text, efeito text, lado text,
  notas bigint, linhas bigint, linhas_com_movimento bigint, itens bigint,
  qtd_entrada numeric, qtd_saida numeric,
  qtd_para_terceiros numeric, qtd_de_terceiro numeric,
  valor_notas numeric, valor_movimento numeric
)
language sql stable as $$
  with linha as (
    select v.id nfe_id, i.id item_id, i.cfop, i.c_prod, coalesce(i.v_prod,0) v_prod,
           e.cnpj,
           case when e.cnpj = v.emit_cnpj then 'emitente' else 'destino' end lado
      from nfe v
      join nfe_item i on i.nfe_id = v.id
      join estabelecimento e on e.cnpj in (v.emit_cnpj, v.dest_doc)
     where v.situacao = 'autorizada'
       and v.dt_emi between p_ini and p_fim
       and (p_cnpj is null or e.cnpj = p_cnpj)
  ), mov as (
    select m.nfe_item_id, m.cnpj,
           coalesce(sum(m.qtd) filter (where m.ind_prop = '0' and m.qtd > 0), 0) ent,
           coalesce(-sum(m.qtd) filter (where m.ind_prop = '0' and m.qtd < 0), 0) sai,
           coalesce(sum(m.qtd) filter (where m.ind_prop = '1'), 0) posse,
           coalesce(sum(m.qtd) filter (where m.ind_prop = '2'), 0) terc,
           coalesce(sum(m.vl_total) filter (where m.ind_prop = '0'), 0) val
      from movimento m
     where m.dt between p_ini and p_fim and m.nfe_item_id is not null
     group by 1, 2
  )
  select l.cfop,
         coalesce(c.descricao, '(CFOP sem classificação)'),
         coalesce(c.efeito, 'nao_classificado'),
         l.lado,
         count(distinct l.nfe_id)::bigint,
         count(*)::bigint,
         count(*) filter (where m.nfe_item_id is not null)::bigint,
         count(distinct l.c_prod)::bigint,
         coalesce(sum(m.ent), 0), coalesce(sum(m.sai), 0),
         coalesce(sum(m.posse), 0), coalesce(sum(m.terc), 0),
         round(sum(l.v_prod), 2), round(coalesce(sum(m.val), 0), 2)
    from linha l
    left join mov m on m.nfe_item_id = l.item_id and m.cnpj = l.cnpj
    left join cfop_efeito c on c.cfop = l.cfop
   group by l.cfop, c.descricao, c.efeito, l.lado
   order by 1, 4;
$$;
comment on function conferencia_cfop(date, date, text) is
  'Movimentacao do periodo por CFOP, pelo lado da filial. Base e a linha de '
  'nota: CFOP que nao movimenta aparece com zero, e nao some.';


create or replace function conferencia_cfop_itens(
  p_ini date, p_fim date, p_cnpj text, p_cfop text, p_lado text default null)
returns table (
  cnpj text, uf text, cod_item text, descr_item text, unid text,
  notas bigint, linhas bigint, qtd_entrada numeric, qtd_saida numeric,
  qtd_de_terceiro numeric, qtd_sem_movimento numeric, valor numeric
)
language sql stable as $$
  with linha as (
    select v.id nfe_id, i.id item_id, i.q_com, coalesce(i.v_prod,0) v_prod,
           e.cnpj, e.uf, i.c_prod, i.u_com,
           case when e.cnpj = v.emit_cnpj then 'emitente' else 'destino' end lado
      from nfe v
      join nfe_item i on i.nfe_id = v.id
      join estabelecimento e on e.cnpj in (v.emit_cnpj, v.dest_doc)
     where v.situacao = 'autorizada' and v.dt_emi between p_ini and p_fim
       and i.cfop = p_cfop
       and (p_cnpj is null or e.cnpj = p_cnpj)
       and (p_lado is null or (case when e.cnpj = v.emit_cnpj then 'emitente' else 'destino' end) = p_lado)
  ), mov as (
    select m.nfe_item_id, m.cnpj, min(m.cod_item) cod_item,
           coalesce(sum(m.qtd) filter (where m.ind_prop = '0' and m.qtd > 0), 0) ent,
           coalesce(-sum(m.qtd) filter (where m.ind_prop = '0' and m.qtd < 0), 0) sai,
           coalesce(sum(m.qtd) filter (where m.ind_prop = '2'), 0) terc
      from movimento m where m.dt between p_ini and p_fim and m.nfe_item_id is not null
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


create or replace function conferencia_cfop_notas(
  p_ini date, p_fim date, p_cnpj text, p_cfop text, p_lado text default null)
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
     and (p_lado is null or (case when e.cnpj = v.emit_cnpj then 'emitente' else 'destino' end) = p_lado)
   group by v.id, v.num_nf, v.dt_emi, e.cnpj, 5, 6, v.nat_op
   order by v.dt_emi, v.num_nf;
$$;
