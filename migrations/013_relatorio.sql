-- 013 — Relatorio de achados por data.
--
-- Reune num formato unico o que hoje esta espalhado em varias views. Cada
-- achado carrega severidade, motivo em texto e a prova — o que um papel de
-- trabalho precisa para ser defensavel se alguem contestar.
--
-- A data importa: saldo negativo e uma posicao, muda conforme o corte. Ja a
-- divergencia de valoracao e do inventario de abertura e nao depende da data,
-- mas entra no relatorio porque contamina todo periodo seguinte.

create or replace function relatorio_achados(p_data date)
returns table (
  tipo        text,
  severidade  text,
  ordem       int,
  uf          text,
  cnpj        text,
  cod_item    text,
  descr_item  text,
  quantidade  numeric,
  valor       numeric,
  motivo      text,
  prova       text
)
language sql stable as $$
  -- 1. Divergencia de valoracao no saldo de abertura
  select 'valoracao', 'critico', 1,
         d.uf, d.cnpj, d.cod_item, d.descr_item, d.qtd, d.exposicao,
         d.motivo,
         'Registro H010, linha ' || d.linha_arquivo || ' de ' || d.nome_arquivo
           || ' (sha ' || d.sha_arquivo || '). Documento de entrada: CFOP '
           || d.cfops || ', ' || d.documentos || ' nota(s).'
  from v_divergencia_detalhe d

  union all

  -- 2. Saldo negativo na data
  select 'saldo_negativo',
         case when e.valor < 0 then 'alto' else 'medio' end, 2,
         e.uf, e.cnpj, e.cod_item, e.descr_item, e.qtd, e.valor,
         'Saldo de ' || fmt_br_int(e.qtd) || ' ' || coalesce(e.unid,'un')
           || ' em ' || to_char(p_data,'DD/MM/YYYY') || ' apos '
           || e.movimentos || ' movimento(s). '
           || case when e.valor = 0
                then 'O item nunca teve entrada registrada: so ha saidas. '
                     || 'Indica nota de compra ou transferencia nao importada.'
                else 'O item tinha saldo e ficou negativo, o que significa '
                     || 'saida maior que a disponibilidade. Exige conferencia '
                     || 'das quantidades das notas.' end,
         'Origem do cadastro: ' || e.origem_cadastro
           || '. Ultimo movimento em ' || to_char(e.ultima_mov,'DD/MM/YYYY') || '.'
  from estoque_em_detalhe(p_data) e
  where e.qtd < 0

  union all

  -- 3. Mercadoria em poder de terceiros
  select 'terceiros', 'alto', 3,
         v.uf, v.cnpj, null, v.depositario, null, sum(v.vl_item),
         'Sao ' || count(*) || ' itens, no valor de R$ ' || fmt_br(sum(v.vl_item))
           || ', declarados como de propriedade da empresa mas em poder de '
           || coalesce(v.depositario, 'terceiro nao identificado')
           || ' (IND_PROP = 1). O inventario declara a posse; nao a comprova. '
           || 'A existencia depende de confirmacao junto ao depositario.',
         'Registros H010 com IND_PROP = 1 e COD_PART preenchido.'
  from v_inventario v
  where v.ind_prop = '1'
  group by v.uf, v.cnpj, v.depositario

  union all

  -- 4. CFOP sem classificacao: bloqueia o Kardex
  select 'cfop_aberto', 'alto', 4,
         null, null, c.cfop, 'CFOP ' || c.cfop, c.ocorrencias, c.valor,
         'O CFOP ' || c.cfop || ' aparece em ' || c.notas || ' nota(s), '
           || c.ocorrencias || ' item(ns), mas nao esta na tabela de efeitos. '
           || 'Enquanto isso, esses itens NAO geram movimento e o saldo '
           || 'apurado esta incompleto.',
         'Primeira ocorrencia em ' || to_char(c.primeira,'DD/MM/YYYY')
           || ', ultima em ' || to_char(c.ultima,'DD/MM/YYYY') || '.'
  from v_cfop_nao_classificado c

  union all

  -- 5. Item de fornecedor ainda sem de-para
  select 'item_pendente', 'medio', 5,
         null, p.cnpj, p.c_prod_externo, p.x_prod, p.qtd_total, p.vl_total,
         'O codigo ' || p.c_prod_externo || ' de '
           || coalesce(p.parceiro_nome, p.parceiro_doc, 'fornecedor')
           || ' aparece em ' || p.ocorrencias || ' lancamento(s) e ainda nao foi '
           || 'ligado a um item do cadastro. Sem esse de-para a entrada nao '
           || 'chega ao Kardex.',
         'Primeira nota: chave ' || coalesce(p.primeira_chave,'-') || '.'
  from item_pendente p
  where p.status = 'aberto'

  union all

  -- 6. Ressalvas assumidas pelo auditor
  select 'ressalva', 'informativo', 6,
         null, null, r.tipo, r.tipo, r.qtd_itens, r.valor,
         r.descricao,
         'Decidido por ' || coalesce(r.decidido_por,'-') || ' em '
           || to_char(r.decidido_em,'DD/MM/YYYY') || '.'
  from auditoria_ressalva r

  order by 3, 9 desc nulls last;
$$;

comment on function relatorio_achados(date) is
  'Todos os achados de uma data em formato unico, com severidade, motivo e '
  'prova. Base do papel de trabalho.';


create or replace function relatorio_resumo(p_data date)
returns table (
  data_base       date,
  itens_saldo     bigint,
  unidades        numeric,
  valor_estoque   numeric,
  filiais         bigint,
  achados         bigint,
  criticos        bigint,
  altos           bigint,
  exposicao       numeric,
  arquivos        bigint,
  notas           bigint,
  movimentos      bigint,
  gerado_em       timestamptz
)
language sql stable as $$
  select p_data,
         (select count(*) from estoque_em_detalhe(p_data) where qtd <> 0),
         (select coalesce(sum(qtd),0) from estoque_em_detalhe(p_data) where qtd <> 0),
         (select coalesce(sum(valor),0) from estoque_em_detalhe(p_data) where qtd <> 0),
         (select count(*) from estabelecimento),
         (select count(*) from relatorio_achados(p_data)),
         (select count(*) from relatorio_achados(p_data) where severidade = 'critico'),
         (select count(*) from relatorio_achados(p_data) where severidade = 'alto'),
         (select coalesce(sum(valor),0) from relatorio_achados(p_data)
            where tipo = 'valoracao'),
         (select count(*) from sped_arquivo where vigente),
         (select count(*) from nfe),
         (select count(*) from movimento),
         now();
$$;


-- Arquivos que sustentam o relatorio: e a procedencia da prova.
create or replace view v_relatorio_fontes as
select a.cnpj, e.uf, e.nome, a.nome_arquivo, left(a.sha256, 24) as sha256,
       a.dt_ini, a.dt_fin, a.cod_fin, a.ind_perfil, a.linhas_lidas,
       a.importado_por, a.importado_em, a.versao_motor
from sped_arquivo a
left join estabelecimento e on e.cnpj = a.cnpj
where a.vigente
order by e.uf;
