-- 003 — Trilha de evidência.
--
-- Motivo: uma ferramenta de auditoria precisa provar de onde cada número veio.
-- Antes disso a carga era destrutiva (truncate cascade) e anônima: não havia
-- hash do arquivo, nem versão, nem a linha física de origem fora do H010.

-- ---------------------------------------------------------------- arquivo
alter table sped_arquivo add column if not exists sha256          text;
alter table sped_arquivo add column if not exists vigente         boolean not null default true;
alter table sped_arquivo add column if not exists substituido_por bigint references sped_arquivo(id);
alter table sped_arquivo add column if not exists importado_por   text;
alter table sped_arquivo add column if not exists linhas_lidas    int;
alter table sped_arquivo add column if not exists contagem_reg    jsonb;
alter table sped_arquivo add column if not exists problemas       jsonb;
alter table sped_arquivo add column if not exists versao_motor    text;

comment on column sped_arquivo.sha256 is
  'SHA-256 do arquivo original. Reimportar o mesmo conteudo e no-op.';
comment on column sped_arquivo.vigente is
  'false quando um arquivo posterior (retificador) substituiu este.';
comment on column sped_arquivo.substituido_por is
  'Aponta para a versao que substituiu. Permite diff original x retificadora.';
comment on column sped_arquivo.versao_motor is
  'Versao do parser que produziu estes dados. Sustenta reprodutibilidade.';

-- A chave antiga impedia guardar duas versoes do mesmo periodo.
alter table sped_arquivo
  drop constraint if exists sped_arquivo_cnpj_dt_ini_dt_fin_cod_fin_nome_arquivo_key;

create unique index if not exists ux_arquivo_sha on sped_arquivo (sha256)
  where sha256 is not null;
create index if not exists ix_arquivo_vigente on sped_arquivo (cnpj, dt_ini, vigente);

-- ------------------------------------------------------- linha física de origem
alter table sped_unidade       add column if not exists linha_arquivo int;
alter table sped_participante  add column if not exists linha_arquivo int;
alter table sped_item          add column if not exists linha_arquivo int;
alter table inventario         add column if not exists linha_arquivo int;
alter table doc_fiscal         add column if not exists linha_arquivo int;
alter table doc_item           add column if not exists linha_arquivo int;
alter table doc_item           add column if not exists arquivo_id bigint references sped_arquivo(id) on delete cascade;

comment on column inventario_item.linha_arquivo is
  'Numero da linha no arquivo .txt original. E o fim da trilha de evidencia.';

-- ------------------------------------------------------------- problemas achados
create table if not exists importacao_problema (
  id          bigserial primary key,
  arquivo_id  bigint not null references sped_arquivo(id) on delete cascade,
  tipo        text not null,
  detalhe     text not null,
  criado_em   timestamptz not null default now()
);
create index if not exists ix_problema_arquivo on importacao_problema (arquivo_id, tipo);
comment on table importacao_problema is
  'Inconsistencias detectadas na importacao, presas ao arquivo que as originou.';

-- ---------------------------------------------------------------- so o vigente
create or replace view v_arquivo_vigente as
select * from sped_arquivo where vigente;

comment on view v_arquivo_vigente is
  'Arquivos ainda validos. Retificados ficam de fora sem serem apagados.';
