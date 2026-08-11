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
