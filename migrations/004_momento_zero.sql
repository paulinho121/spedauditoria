-- 004 — Momento zero e ingestão de NF-e.
--
-- Decisões do auditor registradas nesta migração:
--   1. O saldo de 31/12/2022 e congelado EXATAMENTE como declarado no Bloco H.
--      A divergencia de valoracao de R$ 1.100.565,31 em 8 itens fica como
--      ressalva de abertura, nao ajustada.
--   2. Equipamento em locacao (CFOP 5908/6908) permanece no estoque, migrando
--      para 'em poder de terceiros'. Nao baixa patrimonio.

-- ============================================================ saldo de abertura
create table if not exists saldo_abertura (
  id            bigserial primary key,
  cnpj          text not null,
  data_base     date not null,
  cod_item      text not null,
  descr_item    text,
  unid          text,
  qtd           numeric(18,3) not null,
  vl_unit       numeric(18,6) not null,
  vl_item       numeric(18,2) not null,
  ind_prop      text,
  cod_part      text,
  origem_item   bigint references inventario_item(id),
  congelado_em  timestamptz not null default now(),
  congelado_por text,
  unique (cnpj, data_base, cod_item, ind_prop, cod_part)
);
comment on table saldo_abertura is
  'Momento zero. Imutavel: e o ponto de partida do Kardex mes a mes.';

create table if not exists auditoria_ressalva (
  id           bigserial primary key,
  escopo       text not null,
  data_base    date,
  tipo         text not null,
  descricao    text not null,
  valor        numeric(18,2),
  qtd_itens    int,
  decidido_por text,
  decidido_em  timestamptz not null default now(),
  detalhe      jsonb
);
comment on table auditoria_ressalva is
  'Limitacoes assumidas conscientemente. Vao no papel de trabalho.';

-- ================================================================ CFOP → efeito
create table if not exists cfop_efeito (
  cfop             text primary key,
  descricao        text not null,
  sentido          text not null check (sentido in ('entrada','saida')),
  efeito           text not null check (efeito in
                     ('soma','baixa','para_terceiros','de_terceiros','simbolico','fora_escopo')),
  move_fisico      boolean not null,
  muda_propriedade boolean not null,
  compoe_custo     boolean not null default false,
  observacao       text
);
comment on table cfop_efeito is
  'Traducao de CFOP em efeito no estoque. E o coracao fiscal do Kardex: '
  'CFOP ausente aqui BLOQUEIA o calculo em vez de adivinhar.';
comment on column cfop_efeito.efeito is
  'soma=entra no saldo proprio; baixa=sai definitivo; para_terceiros=sai do poder '
  'mas continua nosso; de_terceiros=volta ao nosso poder; simbolico=nao move '
  'fisico; fora_escopo=nao e estoque (ativo, uso e consumo)';

insert into cfop_efeito (cfop, descricao, sentido, efeito, move_fisico, muda_propriedade, compoe_custo, observacao) values
 ('1101','Compra para industrializacao','entrada','soma',true,true,true,null),
 ('2101','Compra para industrializacao, outro estado','entrada','soma',true,true,true,null),
 ('3101','Compra para industrializacao, exterior','entrada','soma',true,true,true,null),
 ('1102','Compra para comercializacao','entrada','soma',true,true,true,null),
 ('2102','Compra para comercializacao, outro estado','entrada','soma',true,true,true,null),
 ('3102','Compra para comercializacao, exterior','entrada','soma',true,true,true,'Importacao'),
 ('1113','Compra decorrente de encomenda para industrializacao','entrada','soma',true,true,true,null),
 ('1126','Compra para utilizacao na prestacao de servico','entrada','soma',true,true,true,null),
 ('1152','Transferencia para comercializacao','entrada','soma',true,false,true,'Entre filiais'),
 ('2152','Transferencia para comercializacao, outro estado','entrada','soma',true,false,true,'Entre filiais'),
 ('1201','Devolucao de venda de producao propria','entrada','soma',true,true,true,null),
 ('2201','Devolucao de venda de producao propria, outro estado','entrada','soma',true,true,true,null),
 ('1202','Devolucao de venda de mercadoria adquirida','entrada','soma',true,true,true,null),
 ('2202','Devolucao de venda de mercadoria adquirida, outro estado','entrada','soma',true,true,true,null),
 ('1403','Compra para comercializacao com ST','entrada','soma',true,true,true,null),
 ('2403','Compra para comercializacao com ST, outro estado','entrada','soma',true,true,true,null),
 ('1409','Transferencia para comercializacao com ST','entrada','soma',true,false,true,'Entre filiais'),
 ('2409','Transferencia para comercializacao com ST, outro estado','entrada','soma',true,false,true,'Entre filiais'),
 ('1411','Devolucao de venda com ST','entrada','soma',true,true,true,null),
 ('2411','Devolucao de venda com ST, outro estado','entrada','soma',true,true,true,null),
 ('1551','Compra de bem para o ativo imobilizado','entrada','fora_escopo',true,true,false,'Ativo, nao estoque'),
 ('2551','Compra de bem para o ativo imobilizado, outro estado','entrada','fora_escopo',true,true,false,'Ativo, nao estoque'),
 ('3551','Compra de bem para o ativo imobilizado, exterior','entrada','fora_escopo',true,true,false,'Ativo, nao estoque'),
 ('1556','Compra de material para uso e consumo','entrada','fora_escopo',true,true,false,'Consumo imediato'),
 ('2556','Compra de material para uso e consumo, outro estado','entrada','fora_escopo',true,true,false,'Consumo imediato'),
 ('3556','Compra de material para uso e consumo, exterior','entrada','fora_escopo',true,true,false,'Consumo imediato'),
 ('1904','Retorno de remessa para venda fora do estabelecimento','entrada','de_terceiros',true,false,false,null),
 ('1905','Entrada de mercadoria recebida para deposito','entrada','fora_escopo',true,false,false,'Somos o depositario'),
 ('2905','Entrada de mercadoria recebida para deposito, outro estado','entrada','fora_escopo',true,false,false,'Somos o depositario'),
 ('1906','Retorno de mercadoria remetida para deposito','entrada','de_terceiros',true,false,false,'Volta do armazem geral'),
 ('2906','Retorno de mercadoria remetida para deposito, outro estado','entrada','de_terceiros',true,false,false,'Volta do armazem geral'),
 ('1907','Retorno simbolico de mercadoria remetida para deposito','entrada','simbolico',false,false,false,'Apenas simbolico'),
 ('2907','Retorno simbolico, outro estado','entrada','simbolico',false,false,false,'Apenas simbolico'),
 ('1908','Entrada de bem por retorno de comodato ou locacao','entrada','de_terceiros',true,false,false,'Volta da locacao'),
 ('2908','Entrada de bem por retorno de comodato ou locacao, outro estado','entrada','de_terceiros',true,false,false,'Volta da locacao'),
 ('1909','Retorno de bem remetido por conta de comodato ou locacao','entrada','de_terceiros',true,false,false,null),
 ('2909','Retorno de bem remetido por comodato ou locacao, outro estado','entrada','de_terceiros',true,false,false,null),
 ('1915','Entrada de mercadoria recebida para conserto','entrada','fora_escopo',true,false,false,'Bem de terceiro'),
 ('1916','Retorno de mercadoria remetida para conserto','entrada','de_terceiros',true,false,false,'Nosso bem voltando'),
 ('2916','Retorno de mercadoria remetida para conserto, outro estado','entrada','de_terceiros',true,false,false,'Nosso bem voltando'),
 ('1949','Outra entrada nao especificada','entrada','fora_escopo',true,false,false,'EXIGE ANALISE CASO A CASO'),
 ('2949','Outra entrada nao especificada, outro estado','entrada','fora_escopo',true,false,false,'EXIGE ANALISE CASO A CASO'),
 ('5101','Venda de producao do estabelecimento','saida','baixa',true,true,false,null),
 ('6101','Venda de producao do estabelecimento, outro estado','saida','baixa',true,true,false,null),
 ('5102','Venda de mercadoria adquirida de terceiros','saida','baixa',true,true,false,null),
 ('6102','Venda de mercadoria adquirida, outro estado','saida','baixa',true,true,false,null),
 ('7102','Venda de mercadoria adquirida, exterior','saida','baixa',true,true,false,'Exportacao'),
 ('5108','Venda de mercadoria a nao contribuinte','saida','baixa',true,true,false,null),
 ('6108','Venda de mercadoria a nao contribuinte, outro estado','saida','baixa',true,true,false,null),
 ('5152','Transferencia de mercadoria adquirida','saida','baixa',true,false,false,'Entre filiais'),
 ('6152','Transferencia de mercadoria adquirida, outro estado','saida','baixa',true,false,false,'Entre filiais'),
 ('5202','Devolucao de compra para comercializacao','saida','baixa',true,true,false,null),
 ('6202','Devolucao de compra para comercializacao, outro estado','saida','baixa',true,true,false,null),
 ('5403','Venda de mercadoria com ST','saida','baixa',true,true,false,null),
 ('6403','Venda de mercadoria com ST, outro estado','saida','baixa',true,true,false,null),
 ('5405','Venda de mercadoria com ST, como substituido','saida','baixa',true,true,false,null),
 ('6404','Venda de mercadoria com ST, outro estado','saida','baixa',true,true,false,null),
 ('5409','Transferencia de mercadoria com ST','saida','baixa',true,false,false,'Entre filiais'),
 ('6409','Transferencia de mercadoria com ST, outro estado','saida','baixa',true,false,false,'Entre filiais'),
 ('5410','Devolucao de compra com ST','saida','baixa',true,true,false,null),
 ('6410','Devolucao de compra com ST, outro estado','saida','baixa',true,true,false,null),
 ('5551','Venda de bem do ativo imobilizado','saida','fora_escopo',true,true,false,'Ativo, nao estoque'),
 ('6551','Venda de bem do ativo imobilizado, outro estado','saida','fora_escopo',true,true,false,'Ativo, nao estoque'),
 ('5905','Remessa para deposito em armazem geral','saida','para_terceiros',true,false,false,'Continua nosso'),
 ('6905','Remessa para deposito em armazem geral, outro estado','saida','para_terceiros',true,false,false,'Continua nosso'),
 ('5906','Retorno de mercadoria depositada','saida','fora_escopo',true,false,false,'Devolvendo bem de terceiro'),
 ('5907','Retorno simbolico de mercadoria depositada','saida','simbolico',false,false,false,'Apenas simbolico'),
 ('6907','Retorno simbolico, outro estado','saida','simbolico',false,false,false,'Apenas simbolico'),
 ('5908','Remessa de bem por conta de comodato ou locacao','saida','para_terceiros',true,false,false,'LOCACAO: nao baixa estoque'),
 ('6908','Remessa de bem por conta de comodato ou locacao, outro estado','saida','para_terceiros',true,false,false,'LOCACAO: nao baixa estoque'),
 ('5909','Retorno de bem recebido por comodato ou locacao','saida','fora_escopo',true,false,false,'Devolvendo bem de terceiro'),
 ('6909','Retorno de bem recebido por comodato ou locacao, outro estado','saida','fora_escopo',true,false,false,'Devolvendo bem de terceiro'),
 ('5915','Remessa de mercadoria para conserto','saida','para_terceiros',true,false,false,'Continua nosso'),
 ('6915','Remessa de mercadoria para conserto, outro estado','saida','para_terceiros',true,false,false,'Continua nosso'),
 ('5916','Retorno de mercadoria recebida para conserto','saida','fora_escopo',true,false,false,'Devolvendo bem de terceiro'),
 ('5949','Outra saida nao especificada','saida','fora_escopo',true,false,false,'EXIGE ANALISE CASO A CASO'),
 ('6949','Outra saida nao especificada, outro estado','saida','fora_escopo',true,false,false,'EXIGE ANALISE CASO A CASO')
on conflict (cfop) do nothing;

-- ======================================================================= NF-e
create table if not exists nfe (
  id            bigserial primary key,
  chave         char(44) not null unique,
  sha256        text not null,
  nome_arquivo  text,
  modelo        text,
  serie         text,
  num_nf        text,
  dh_emi        timestamptz,
  dt_emi        date,
  tp_nf         text,
  fin_nfe       text,
  nat_op        text,
  emit_cnpj     text,
  emit_nome     text,
  emit_uf       text,
  dest_doc      text,
  dest_nome     text,
  dest_uf       text,
  vl_nf         numeric(18,2),
  vl_prod       numeric(18,2),
  situacao      text not null default 'autorizada',
  cancelada_em  timestamptz,
  importado_em  timestamptz not null default now(),
  importado_por text,
  versao_motor  text
);
comment on table nfe is 'Cabecalho da NF-e. A chave de acesso e a identidade.';
comment on column nfe.situacao is 'autorizada | cancelada | denegada | inutilizada';

create index if not exists ix_nfe_emit on nfe (emit_cnpj, dt_emi);
create index if not exists ix_nfe_dest on nfe (dest_doc, dt_emi);
create index if not exists ix_nfe_dt   on nfe (dt_emi);

create table if not exists nfe_item (
  id         bigserial primary key,
  nfe_id     bigint not null references nfe(id) on delete cascade,
  n_item     int not null,
  c_prod     text not null,
  c_ean      text,
  x_prod     text,
  x_prod_norm text,
  ncm        text,
  cest       text,
  cfop       text not null,
  u_com      text,
  q_com      numeric(18,4),
  v_un_com   numeric(18,6),
  v_prod     numeric(18,2),
  u_trib     text,
  q_trib     numeric(18,4),
  v_desc     numeric(18,2),
  v_frete    numeric(18,2),
  v_seg      numeric(18,2),
  v_outro    numeric(18,2),
  ind_tot    text,
  cst_icms   text,
  unique (nfe_id, n_item)
);
create index if not exists ix_nfeitem_cprod on nfe_item (c_prod);
create index if not exists ix_nfeitem_cfop  on nfe_item (cfop);
create index if not exists ix_nfeitem_norm  on nfe_item (x_prod_norm);

-- =========================================================== de-para de itens
create table if not exists item_depara (
  id             bigserial primary key,
  cnpj           text not null,
  parceiro_doc   text,
  c_prod_externo text not null,
  cod_item       text not null,
  fator_unidade  numeric(18,6) not null default 1,
  metodo         text not null,
  resolvido_por  text,
  resolvido_em   timestamptz not null default now(),
  unique (cnpj, parceiro_doc, c_prod_externo)
);
comment on table item_depara is
  'Liga o codigo do item na NF-e ao codigo interno. Nas notas que emitimos o '
  'cProd ja e o nosso; nas recebidas e o do fornecedor e precisa ser resolvido.';
comment on column item_depara.fator_unidade is
  'Multiplicador de quantidade. Um KT com 8 tubos que entra como 8 unidades '
  'de estoque tem fator 8.';
comment on column item_depara.metodo is
  'codigo_proprio | c170 | descricao | manual';

create table if not exists item_pendente (
  id             bigserial primary key,
  cnpj           text not null,
  parceiro_doc   text,
  parceiro_nome  text,
  c_prod_externo text not null,
  x_prod         text,
  ncm            text,
  u_com          text,
  ocorrencias    int not null default 1,
  qtd_total      numeric(18,4),
  vl_total       numeric(18,2),
  primeira_chave char(44),
  status         text not null default 'aberto',
  criado_em      timestamptz not null default now(),
  unique (cnpj, parceiro_doc, c_prod_externo)
);
comment on table item_pendente is
  'Fila de resolucao. Item que o sistema nao conseguiu casar sozinho para aqui '
  'em vez de virar movimento errado.';

-- ================================================================== movimento
create table if not exists movimento (
  id           bigserial primary key,
  cnpj         text not null,
  dt           date not null,
  cod_item     text not null,
  origem       text not null,
  nfe_id       bigint references nfe(id) on delete cascade,
  nfe_item_id  bigint references nfe_item(id) on delete cascade,
  chave        char(44),
  n_item       int,
  cfop         text,
  efeito       text not null,
  qtd          numeric(18,3) not null,
  vl_unit      numeric(18,6),
  vl_total     numeric(18,2),
  ind_prop     text not null default '0',
  observacao   text,
  criado_em    timestamptz not null default now()
);
comment on table movimento is
  'Linha do Kardex. qtd com sinal: positivo entra, negativo sai. '
  'origem: abertura | nfe | ajuste';
create index if not exists ix_mov_item on movimento (cnpj, cod_item, dt);
create index if not exists ix_mov_dt   on movimento (dt);
create index if not exists ix_mov_nfe  on movimento (nfe_id);

-- ============================================================ fechamento mensal
create table if not exists fechamento (
  id           bigserial primary key,
  cnpj         text not null,
  competencia  date not null,
  status       text not null default 'aberto',
  qtd_itens    int,
  valor_final  numeric(18,2),
  fechado_por  text,
  fechado_em   timestamptz,
  unique (cnpj, competencia)
);
comment on table fechamento is
  'Mes fechado nao se altera. O saldo final vira abertura do mes seguinte.';

-- ===================================================================== visoes
create or replace view v_cfop_nao_classificado as
select ni.cfop, count(*) as ocorrencias, count(distinct n.id) as notas,
       min(n.dt_emi) as primeira, max(n.dt_emi) as ultima,
       sum(ni.v_prod) as valor
from nfe_item ni
join nfe n on n.id = ni.nfe_id
left join cfop_efeito c on c.cfop = ni.cfop
where c.cfop is null
group by ni.cfop order by 5 desc;
comment on view v_cfop_nao_classificado is
  'CFOP presente nas notas e ausente da tabela de efeitos. Enquanto houver '
  'linha aqui, o Kardex esta incompleto.';
