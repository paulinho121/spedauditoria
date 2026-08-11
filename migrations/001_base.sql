-- ============ AUDITORIA FISCAL DE ESTOQUE - SPED EFD ICMS/IPI ============

create table if not exists sped_arquivo (
  id            bigserial primary key,
  nome_arquivo  text not null,
  cnpj          text not null,
  nome_empresa  text,
  uf            text,
  ie            text,
  dt_ini        date not null,
  dt_fin        date not null,
  cod_fin       text,
  cod_ver       text,
  ind_perfil    text,
  ind_ativ      text,
  importado_em  timestamptz not null default now(),
  unique (cnpj, dt_ini, dt_fin, cod_fin, nome_arquivo)
);
comment on table sped_arquivo is 'Um registro por arquivo EFD importado (registro 0000).';
comment on column sped_arquivo.cod_fin is '0 = original, 1 = substituto';

create table if not exists estabelecimento (
  cnpj  text primary key,
  nome  text,
  uf    text,
  ie    text
);

create table if not exists sped_unidade (
  id          bigserial primary key,
  arquivo_id  bigint not null references sped_arquivo(id) on delete cascade,
  cnpj        text not null,
  unid        text not null,
  descr       text,
  unique (arquivo_id, unid)
);
comment on table sped_unidade is 'Registro 0190 - unidades de medida.';

create table if not exists sped_participante (
  id          bigserial primary key,
  arquivo_id  bigint not null references sped_arquivo(id) on delete cascade,
  cnpj_estab  text not null,
  cod_part    text not null,
  nome        text,
  cod_pais    text,
  cnpj        text,
  cpf         text,
  ie          text,
  cod_mun     text,
  unique (arquivo_id, cod_part)
);
comment on table sped_participante is 'Registro 0150 - participantes (fornecedores, clientes, depositarios).';

create table if not exists sped_item (
  id          bigserial primary key,
  arquivo_id  bigint not null references sped_arquivo(id) on delete cascade,
  cnpj_estab  text not null,
  cod_item    text not null,
  descr_item  text,
  descr_norm  text,
  cod_barra   text,
  unid_inv    text,
  tipo_item   text,
  ncm         text,
  ex_ipi      text,
  cod_gen     text,
  cod_lst     text,
  aliq_icms   numeric(6,2),
  cest        text,
  unique (arquivo_id, cod_item)
);
comment on table sped_item is 'Registro 0200 - cadastro de itens.';
comment on column sped_item.descr_norm is 'Descricao normalizada (sem acento/pontuacao, maiusculas, 40 chars) para cruzar o mesmo produto entre filiais, ja que o cod_item colide.';

create table if not exists inventario (
  id          bigserial primary key,
  arquivo_id  bigint not null references sped_arquivo(id) on delete cascade,
  cnpj        text not null,
  dt_inv      date not null,
  vl_inv      numeric(18,2) not null,
  mot_inv     text,
  unique (cnpj, dt_inv, arquivo_id)
);
comment on table inventario is 'Registro H005 - cabecalho do inventario. Declarado no EFD de fevereiro do ano seguinte.';

create table if not exists inventario_item (
  id             bigserial primary key,
  inventario_id  bigint not null references inventario(id) on delete cascade,
  cnpj           text not null,
  dt_inv         date not null,
  cod_item       text not null,
  unid           text,
  qtd            numeric(18,3) not null,
  vl_unit        numeric(18,6) not null,
  vl_item        numeric(18,2) not null,
  ind_prop       text,
  cod_part       text,
  txt_compl      text,
  cod_cta        text,
  vl_item_ir     numeric(18,2),
  linha_arquivo  int
);
comment on table inventario_item is 'Registro H010 - itens do inventario.';
comment on column inventario_item.ind_prop is '0 = proprio em seu poder; 1 = proprio em poder de terceiros; 2 = de terceiros em seu poder';

create table if not exists doc_fiscal (
  id          bigserial primary key,
  arquivo_id  bigint not null references sped_arquivo(id) on delete cascade,
  cnpj        text not null,
  ind_oper    text,
  ind_emit    text,
  cod_part    text,
  cod_mod     text,
  cod_sit     text,
  ser         text,
  num_doc     text,
  chv_nfe     text,
  dt_doc      date,
  dt_e_s      date,
  vl_doc      numeric(18,2)
);
comment on table doc_fiscal is 'Registro C100 - documentos fiscais. Base do Kardex quando os EFDs de 2022 forem carregados.';
comment on column doc_fiscal.ind_oper is '0 = entrada/aquisicao, 1 = saida/prestacao';

create table if not exists doc_item (
  id        bigserial primary key,
  doc_id    bigint not null references doc_fiscal(id) on delete cascade,
  cnpj      text not null,
  num_item  int,
  cod_item  text not null,
  qtd       numeric(18,3),
  unid      text,
  vl_item   numeric(18,2),
  vl_desc   numeric(18,2),
  cfop      text,
  cst_icms  text,
  dt_doc    date,
  ind_oper  text
);
comment on table doc_item is 'Registro C170 - itens dos documentos fiscais.';

-- indices
create index if not exists ix_item_cod       on sped_item (cnpj_estab, cod_item);
create index if not exists ix_item_norm      on sped_item (descr_norm);
create index if not exists ix_invit_cod      on inventario_item (cnpj, cod_item);
create index if not exists ix_invit_dt       on inventario_item (dt_inv);
create index if not exists ix_docitem_cod    on doc_item (cnpj, cod_item);
create index if not exists ix_docitem_dt     on doc_item (dt_doc);
create index if not exists ix_docitem_cfop   on doc_item (cfop);
create index if not exists ix_doc_dt         on doc_fiscal (cnpj, dt_doc);
