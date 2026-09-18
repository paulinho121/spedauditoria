-- 035 — Item novo ganha cadastro a partir do XML, automaticamente.
--
-- O unico cadastro que existia era o registro 0200 do EFD de fev/2023. Item
-- criado depois disso aparecia como "sem cadastro": so o codigo, sem descricao,
-- NCM nem unidade. A 008 remendava buscando a descricao em nota que a propria
-- filial EMITIU — e so nessas, porque em nota recebida o cProd e do fornecedor
-- e casaria o produto errado. Resultado: item que SP recebeu por transferencia
-- e ainda nao vendeu ficava sem nada, embora o XML trouxesse tudo.
--
-- O elo seguro e o MOVIMENTO. Ele ja ligou aquela linha de nota ao codigo do
-- item naquela filial: direto, se a filial emitiu; pelo de-para, se recebeu.
-- Ler o cadastro por ele nao corre o risco que a 008 evitava.
--
-- Por que uma tabela a parte, e nao linhas no sped_item: sped_item e o que a
-- empresa DECLAROU, com arquivo, hash e linha. Misturar o que o sistema deduziu
-- do XML apagaria essa diferenca — e ela importa se alguem perguntar de onde
-- veio a descricao. Na tela, o 0200 continua vencendo quando existe.
--
-- Qual nota vira o cadastro, quando o item aparece em varias: a emitida pela
-- propria filial primeiro (e a descricao dela), depois a mais antiga. A escolha
-- e recalculada dos dados, nao da ordem de importacao — importar as mesmas
-- notas em outra ordem da o mesmo cadastro.

create table if not exists item_cadastro_nfe_todos (
  id           bigserial primary key,
  trabalho_id  bigint not null default trabalho_atual()
               references trabalho(id) on delete cascade,
  cnpj         text not null,
  cod_item     text not null,
  descr_item   text,
  ncm          text,
  cest         text,
  cod_barra    text,
  unid         text,
  nfe_id       bigint,
  chave        text,
  num_nf       text,
  n_item       int,
  dt_emi       date,
  fonte        text,    -- 'nota emitida pela filial' | 'nota recebida'
  notas        int,     -- em quantas notas o item aparece nesta filial
  atualizado_em timestamptz not null default now()
);
create unique index if not exists ux_item_cadastro_nfe
  on item_cadastro_nfe_todos (trabalho_id, cnpj, cod_item);
comment on table item_cadastro_nfe_todos is
  'Cadastro deduzido do XML para item que o 0200 nao tem. Nao substitui o '
  '0200: complementa, e diz de qual nota veio.';

create or replace view item_cadastro_nfe as
  select * from item_cadastro_nfe_todos where trabalho_id = trabalho_atual();


-- ============================================================== cadastrar
-- Sem argumentos refaz tudo; com filial e codigo, so aquele item.
create or replace function cadastrar_itens_nfe(
  p_cnpj text default null, p_cod text default null)
returns int language plpgsql as $$
declare v int;
begin
  insert into item_cadastro_nfe_todos (cnpj, cod_item, descr_item, ncm, cest,
         cod_barra, unid, nfe_id, chave, num_nf, n_item, dt_emi, fonte, notas,
         atualizado_em)
  select distinct on (m.cnpj, m.cod_item)
         m.cnpj, m.cod_item, i.x_prod, i.ncm, i.cest,
         case when i.c_ean ~ '^[0-9]{8,14}$' then i.c_ean end,   -- "SEM GTIN" nao e codigo
         i.u_com, n.id, n.chave, n.num_nf, i.n_item, n.dt_emi,
         case when n.emit_cnpj = m.cnpj then 'nota emitida pela filial'
              else 'nota recebida' end,
         (select count(distinct m2.nfe_id) from movimento m2
           where m2.cnpj = m.cnpj and m2.cod_item = m.cod_item
             and m2.origem = 'nfe')::int,
         now()
    from movimento m
    join nfe n       on n.id = m.nfe_id
    join nfe_item i  on i.id = m.nfe_item_id
   where m.origem = 'nfe'
     and (p_cnpj is null or m.cnpj = p_cnpj)
     and (p_cod  is null or m.cod_item = p_cod)
     and not exists (select 1 from sped_item s
                      where s.cnpj_estab = m.cnpj and s.cod_item = m.cod_item)
     and not exists (select 1 from saldo_abertura a
                      where a.cnpj = m.cnpj and a.cod_item = m.cod_item)
   order by m.cnpj, m.cod_item,
            (n.emit_cnpj = m.cnpj) desc,   -- a descricao da propria filial primeiro
            n.dt_emi, n.id, i.n_item
  on conflict (trabalho_id, cnpj, cod_item) do update set
    descr_item = excluded.descr_item, ncm = excluded.ncm, cest = excluded.cest,
    cod_barra = excluded.cod_barra, unid = excluded.unid,
    nfe_id = excluded.nfe_id, chave = excluded.chave, num_nf = excluded.num_nf,
    n_item = excluded.n_item, dt_emi = excluded.dt_emi, fonte = excluded.fonte,
    notas = excluded.notas, atualizado_em = now();
  get diagnostics v = row_count;
  return v;
end $$;
comment on function cadastrar_itens_nfe(text, text) is
  'Cadastra, a partir do XML, o item com movimento de NF-e que nao esta no 0200 '
  'nem no saldo de abertura. Deterministico: nao depende da ordem de importacao.';


-- ================================================================ gatilho
-- No gatilho, e nao nos importadores: sao dois importadores (Python no
-- servidor local, SQL no Vercel) e o reprocessamento. Pelo gatilho, qualquer
-- caminho que gere movimento de NF-e cadastra o item — inclusive um que ainda
-- nao existe.
create or replace function tg_cadastrar_itens_nfe()
returns trigger language plpgsql as $$
declare r record;
begin
  for r in select distinct cnpj, cod_item from novos where origem = 'nfe' loop
    perform cadastrar_itens_nfe(r.cnpj, r.cod_item);
  end loop;
  return null;
end $$;

drop trigger if exists cadastrar_itens_nfe on movimento_todos;
create trigger cadastrar_itens_nfe
  after insert on movimento_todos
  referencing new table as novos
  for each statement execute function tg_cadastrar_itens_nfe();


-- ======================================================== cascata na tela
-- 0200 -> saldo de abertura -> cadastro pelo XML -> sem cadastro.
-- O rotulo continua 'NF-e': a tela de Reconstrucao ja o reconhece.
create or replace function estoque_em_detalhe(p_data date)
returns table (
  uf text, cnpj text, cod_item text, descr_item text, ncm text, unid text,
  qtd numeric, qtd_proprio numeric, qtd_terceiros numeric,
  custo_medio numeric, valor numeric, ultima_mov date, movimentos bigint,
  origem_cadastro text, busca text
)
language sql stable as $$
  select
    e.uf, s.cnpj, s.cod_item,
    coalesce(i.descr_item, sa.descr_item, c.descr_item)       as descr_item,
    coalesce(i.ncm, c.ncm)                                    as ncm,
    coalesce(sa.unid, i.unid_inv, c.unid)                     as unid,
    s.qtd, s.qtd_proprio, s.qtd_terceiros,
    round(s.custo_medio, 6)                                   as custo_medio,
    round(s.valor, 2)                                         as valor,
    s.ultima_mov, s.movimentos,
    case
      when i.descr_item  is not null then 'cadastro 0200'
      when sa.descr_item is not null then 'saldo de abertura'
      when c.descr_item  is not null then 'NF-e'
      else 'sem cadastro'
    end                                                       as origem_cadastro,
    upper(coalesce(i.descr_item, sa.descr_item, c.descr_item, '') || ' ' ||
          s.cod_item || ' ' || coalesce(i.ncm, c.ncm, ''))    as busca
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
  left join item_cadastro_nfe c on c.cnpj = s.cnpj and c.cod_item = s.cod_item;
$$;

create or replace function estoque_periodo_detalhe(
  p_ini date, p_fim date, p_origem text default 'nfe')
returns table (
  uf text, cnpj text, cod_item text, descr_item text, ncm text, unid text,
  qtd_entrada numeric, vl_entrada numeric,
  qtd_saida numeric, vl_saida numeric, vl_saida_custo numeric,
  saldo_qtd numeric, saldo_proprio numeric, saldo_terceiros numeric,
  custo_medio numeric, valor numeric, sem_custo boolean,
  movimentos bigint, primeira_mov date, ultima_mov date,
  origem_cadastro text, busca text
)
language sql stable as $$
  select
    e.uf, s.cnpj, s.cod_item,
    coalesce(i.descr_item, sa.descr_item, c.descr_item)       as descr_item,
    coalesce(i.ncm, c.ncm)                                    as ncm,
    coalesce(sa.unid, i.unid_inv, c.unid)                     as unid,
    s.qtd_entrada, s.vl_entrada,
    s.qtd_saida, s.vl_saida, s.vl_saida_custo,
    s.saldo_qtd, s.saldo_proprio, s.saldo_terceiros,
    s.custo_medio, s.valor, s.sem_custo,
    s.movimentos, s.primeira_mov, s.ultima_mov,
    case
      when i.descr_item  is not null then 'cadastro 0200'
      when sa.descr_item is not null then 'saldo de abertura'
      when c.descr_item  is not null then 'NF-e'
      else 'sem cadastro'
    end                                                       as origem_cadastro,
    upper(coalesce(i.descr_item, sa.descr_item, c.descr_item, '') || ' ' ||
          s.cod_item || ' ' || coalesce(i.ncm, c.ncm, ''))    as busca
  from estoque_periodo(p_ini, p_fim, p_origem) s
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
  left join item_cadastro_nfe c on c.cnpj = s.cnpj and c.cod_item = s.cod_item;
$$;


-- ============================================ cadastra o que ja esta no banco
select cadastrar_itens_nfe();
