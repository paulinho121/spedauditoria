-- 027 — Trabalho como entidade: cada auditoria vive isolada.
--
-- Ate aqui o banco guardava UMA auditoria. Comecar outra exigiria apagar a
-- anterior, e numa ferramenta de auditoria prova descartada e prova que nunca
-- existiu: se o cliente contestar um achado seis meses depois, nao ha como
-- voltar. Alem disso, um escritorio atende varios clientes ao mesmo tempo.
--
-- Cada tabela de dados ganha trabalho_id com DEFAULT trabalho_atual(). Assim as
-- importacoes e o motor de achados continuam sem saber que trabalhos existem —
-- as linhas nascem no trabalho ativo sozinhas.

create table if not exists trabalho (
  id           bigserial primary key,
  nome         text not null,
  cliente      text,
  exercicio    text,
  descricao    text,
  status       text not null default 'ativo'
               check (status in ('ativo','encerrado','arquivado')),
  criado_em    timestamptz not null default now(),
  criado_por   text,
  encerrado_em timestamptz
);
comment on table trabalho is
  'Uma auditoria. Excluir um trabalho leva junto todos os seus dados, por '
  'cascata — e nao toca nos demais.';

-- Qual trabalho esta em uso. Linha unica: a ferramenta e de um auditor por vez,
-- e um estado global evita que a linha de comando e o painel discordem.
create table if not exists preferencia (
  id          int primary key default 1 check (id = 1),
  trabalho_id bigint references trabalho(id) on delete set null,
  alterado_em timestamptz not null default now(),
  alterado_por text
);

insert into trabalho (nome, cliente, exercicio, descricao, criado_por)
select 'MULTI COMERCIAL — reconstrução 2022/2023',
       'MULTI COMERCIAL & IMPORTADORA',
       '2022/2023',
       'Primeiro trabalho: reconstrução do estoque a partir do inventário de '
       '31/12/2022 declarado no Bloco H dos EFD de fevereiro de 2023.',
       'sistema'
where not exists (select 1 from trabalho);

insert into preferencia (id, trabalho_id, alterado_por)
select 1, (select min(id) from trabalho), 'sistema'
where not exists (select 1 from preferencia);

create or replace function trabalho_atual()
returns bigint language sql stable as $$
  select coalesce((select trabalho_id from preferencia where id = 1),
                  (select min(id) from trabalho));
$$;
comment on function trabalho_atual() is
  'Trabalho em uso. Serve de DEFAULT nas tabelas de dados, para que a carga e '
  'o motor de achados nao precisem conhecer o conceito.';

create or replace function trabalho_usar(p_id bigint, p_quem text default null)
returns trabalho language plpgsql as $$
declare v trabalho;
begin
  select * into v from trabalho where id = p_id;
  if v.id is null then raise exception 'trabalho % nao existe', p_id; end if;
  update preferencia set trabalho_id = p_id, alterado_em = now(),
                         alterado_por = coalesce(p_quem, 'sistema')
   where id = 1;
  return v;
end $$;

create or replace function trabalho_novo(
  p_nome text, p_cliente text default null, p_exercicio text default null,
  p_descricao text default null, p_quem text default null, p_usar boolean default true)
returns trabalho language plpgsql as $$
declare v trabalho;
begin
  insert into trabalho (nome, cliente, exercicio, descricao, criado_por)
  values (p_nome, p_cliente, p_exercicio, p_descricao, coalesce(p_quem,'sistema'))
  returning * into v;
  if p_usar then perform trabalho_usar(v.id, p_quem); end if;
  return v;
end $$;

-- ================================================ trabalho_id nas tabelas
do $$
declare
  t text;
  tabelas text[] := array[
    'sped_arquivo','estabelecimento','sped_unidade','sped_participante',
    'sped_item','inventario','inventario_item','doc_fiscal','doc_item',
    'nfe','nfe_item','movimento','saldo_abertura','item_depara',
    'item_pendente','achado','varredura','materialidade',
    'auditoria_ressalva','fechamento','importacao_problema'];
begin
  foreach t in array tabelas loop
    execute format(
      'alter table %I add column if not exists trabalho_id bigint '
      'not null default trabalho_atual() references trabalho(id) on delete cascade', t);
    execute format('create index if not exists ix_%s_trab on %I (trabalho_id)', t, t);
  end loop;
end $$;

-- ====================================== chaves unicas passam a incluir o trabalho
-- Sem isto, importar o mesmo arquivo — ou auditar o mesmo CNPJ — em dois
-- trabalhos seria recusado por duplicidade.

alter table estabelecimento drop constraint if exists estabelecimento_pkey;
alter table estabelecimento add primary key (trabalho_id, cnpj);

drop index if exists ux_arquivo_sha;
create unique index if not exists ux_arquivo_sha
  on sped_arquivo (trabalho_id, sha256) where sha256 is not null;

alter table nfe drop constraint if exists nfe_chave_key;
create unique index if not exists ux_nfe_chave on nfe (trabalho_id, chave);

alter table achado drop constraint if exists achado_chave_key;
create unique index if not exists ux_achado_chave on achado (trabalho_id, chave);

alter table item_pendente
  drop constraint if exists item_pendente_cnpj_parceiro_doc_c_prod_externo_key;
create unique index if not exists ux_pendente
  on item_pendente (trabalho_id, cnpj, coalesce(parceiro_doc,''), c_prod_externo);

alter table item_depara
  drop constraint if exists item_depara_cnpj_parceiro_doc_c_prod_externo_key;
create unique index if not exists ux_depara
  on item_depara (trabalho_id, cnpj, coalesce(parceiro_doc,''), c_prod_externo);

alter table saldo_abertura
  drop constraint if exists saldo_abertura_cnpj_data_base_cod_item_ind_prop_cod_part_key;
create unique index if not exists ux_abertura
  on saldo_abertura (trabalho_id, cnpj, data_base, cod_item,
                     coalesce(ind_prop,''), coalesce(cod_part,''));

alter table fechamento drop constraint if exists fechamento_cnpj_competencia_key;
create unique index if not exists ux_fechamento
  on fechamento (trabalho_id, cnpj, competencia);

alter table inventario drop constraint if exists inventario_cnpj_dt_inv_arquivo_id_key;
create unique index if not exists ux_inventario
  on inventario (trabalho_id, cnpj, dt_inv, arquivo_id);

-- =================================================================== visao
create or replace view v_trabalho as
select t.*,
       t.id = trabalho_atual() as ativo,
       (select count(*) from sped_arquivo a where a.trabalho_id = t.id) as arquivos,
       (select count(*) from nfe n where n.trabalho_id = t.id)          as notas,
       (select count(*) from movimento m where m.trabalho_id = t.id)    as movimentos,
       (select count(*) from achado x
         where x.trabalho_id = t.id and x.status <> 'resolvido')        as achados_abertos,
       (select coalesce(sum(vl_item),0) from saldo_abertura s
         where s.trabalho_id = t.id)                                    as abertura,
       (select string_agg(distinct e.uf, ', ' order by e.uf)
          from estabelecimento e where e.trabalho_id = t.id)            as ufs
from trabalho t;
