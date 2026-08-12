-- 014 — Unidade ilegivel nao vai para o texto do relatorio.
--
-- O motivo saia "Saldo de -2 1 em 11/01/2023": a unidade e o codigo '1' do
-- registro 0190, cadastrado com a descricao-modelo 'DESC. UNIDADE'. Codigo de
-- unidade puramente numerico nao significa nada para quem le o relatorio.

create or replace function unid_legivel(v text)
returns text language sql immutable as $$
  select case
    when v is null or btrim(v) = '' then 'un'
    when btrim(v) ~ '^[0-9]+$'      then 'un'   -- codigo numerico: sem sentido no texto
    else lower(btrim(v))
  end;
$$;

comment on function unid_legivel(text) is
  'Unidade para exibicao em texto corrido. Codigo numerico do 0190 vira "un".';

create or replace function relatorio_achados(p_data date)
returns table (
  tipo text, severidade text, ordem int, uf text, cnpj text, cod_item text,
  descr_item text, quantidade numeric, valor numeric, motivo text, prova text
)
language sql stable as $$
  select 'valoracao', 'critico', 1,
         d.uf, d.cnpj, d.cod_item, d.descr_item, d.qtd, d.exposicao, d.motivo,
         'Registro H010, linha ' || d.linha_arquivo || ' de ' || d.nome_arquivo
           || ' (sha ' || d.sha_arquivo || '). Documento de entrada: CFOP '
           || d.cfops || ', ' || d.documentos || ' nota(s).'
  from v_divergencia_detalhe d
  union all
  select 'saldo_negativo',
         case when e.valor < 0 then 'alto' else 'medio' end, 2,
         e.uf, e.cnpj, e.cod_item, e.descr_item, e.qtd, e.valor,
         'Saldo de ' || fmt_br_int(e.qtd) || ' ' || unid_legivel(e.unid)
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
  select 'terceiros', 'alto', 3,
         v.uf, v.cnpj, null, v.depositario, null, sum(v.vl_item),
         'Sao ' || count(*) || ' itens, no valor de R$ ' || fmt_br(sum(v.vl_item))
           || ', declarados como de propriedade da empresa mas em poder de '
           || coalesce(v.depositario, 'terceiro nao identificado')
           || ' (IND_PROP = 1). O inventario declara a posse; nao a comprova. '
           || 'A existencia depende de confirmacao junto ao depositario.',
         'Registros H010 com IND_PROP = 1 e COD_PART preenchido.'
  from v_inventario v where v.ind_prop = '1'
  group by v.uf, v.cnpj, v.depositario
  union all
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
  select 'item_pendente', 'medio', 5,
         null, p.cnpj, p.c_prod_externo, p.x_prod, p.qtd_total, p.vl_total,
         'O codigo ' || p.c_prod_externo || ' de '
           || coalesce(p.parceiro_nome, p.parceiro_doc, 'fornecedor')
           || ' aparece em ' || p.ocorrencias || ' lancamento(s) e ainda nao foi '
           || 'ligado a um item do cadastro. Sem esse de-para a entrada nao '
           || 'chega ao Kardex.',
         'Primeira nota: chave ' || coalesce(p.primeira_chave,'-') || '.'
  from item_pendente p where p.status = 'aberto'
  union all
  select 'ressalva', 'informativo', 6,
         null, null, r.tipo, r.tipo, r.qtd_itens, r.valor, r.descricao,
         'Decidido por ' || coalesce(r.decidido_por,'-') || ' em '
           || to_char(r.decidido_em,'DD/MM/YYYY') || '.'
  from auditoria_ressalva r
  order by 3, 9 desc nulls last;
$$;
