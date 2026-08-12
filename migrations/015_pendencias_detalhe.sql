-- 015 — Detalhe acionavel das pendencias que travam o Kardex.
--
-- Ver a lista nao basta: para resolver um item pendente e preciso saber a que
-- produto do cadastro ele corresponde. A busca por similaridade de descricao
-- transforma a lista num trabalho possivel em vez de uma caca manual.

create extension if not exists pg_trgm;

create or replace function item_pendente_sugestoes(p_cnpj text, p_c_prod text)
returns table (
  cod_item     text,
  descr_item   text,
  ncm          text,
  unid_inv     text,
  semelhanca   real,
  ja_no_estoque boolean,
  origem       text
)
language sql stable as $$
  with alvo as (
    select x_prod, ncm from item_pendente
    where cnpj = p_cnpj and c_prod_externo = p_c_prod limit 1
  )
  -- Candidatos do cadastro 0200 do proprio estabelecimento.
  select si.cod_item, si.descr_item, si.ncm, si.unid_inv,
         similarity(upper(si.descr_item), upper((select x_prod from alvo))),
         exists (select 1 from saldo_abertura sa
                 where sa.cnpj = p_cnpj and sa.cod_item = si.cod_item),
         case when si.ncm = (select ncm from alvo) then 'descricao + NCM'
              else 'descricao' end
  from sped_item si
  join sped_arquivo a on a.id = si.arquivo_id and a.vigente
  where si.cnpj_estab = p_cnpj
    and (select x_prod from alvo) is not null
    and similarity(upper(si.descr_item), upper((select x_prod from alvo))) > 0.15
  order by 5 desc, 7
  limit 8;
$$;

comment on function item_pendente_sugestoes(text, text) is
  'Candidatos do cadastro para resolver um item pendente, por semelhanca de '
  'descricao. Coincidencia de NCM sobe a confianca.';


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
