-- 022 — As conciliacoes viram achado.
--
-- Agregadas por estabelecimento, nao uma por nota: 191 achados dizendo "falta
-- o XML desta nota" seria ruido. Um achado por filial dizendo quantas faltam e
-- acionavel — o auditor pede o lote, nao a nota avulsa.
--
-- A NF-e autorizada e nao escriturada e a excecao: essa vai uma a uma, porque
-- cada caso e um documento especifico a explicar.

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
           || ' (IND_PROP = 1). O inventario declara a posse; nao a comprova.',
         'Registros H010 com IND_PROP = 1 e COD_PART preenchido.'
  from v_inventario v
  where v.ind_prop = '1'
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
  from item_pendente p
  where p.status = 'aberto'

  -- ---------------------------------------------- conciliacao EFD x XML
  union all
  select 'sem_documento', 'alto', 6,
         x.uf, x.cnpj, null,
         'Notas escrituradas sem o XML correspondente',
         count(*)::numeric, sum(x.vl_doc),
         'Sao ' || count(*) || ' notas escrituradas no EFD, somando R$ '
           || fmt_br(sum(x.vl_doc)) || ', para as quais o XML nao foi importado. '
           || 'Sem o documento nao ha como confrontar o que foi declarado com o '
           || 'que foi emitido — que e o teste mais forte de uma auditoria '
           || 'fiscal. Nao e irregularidade da empresa: e limite do trabalho.',
         'Periodo de ' || to_char(min(x.dt_doc),'DD/MM/YYYY') || ' a '
           || to_char(max(x.dt_doc),'DD/MM/YYYY') || '. Solicitar o lote de XML.'
  from v_efd_sem_xml x
  group by x.uf, x.cnpj

  union all
  select 'nao_escriturada', 'critico', 7,
         null, x.cnpj, x.chave, x.emit_nome, 1::numeric, x.vl_nf,
         'A NF-e ' || x.num_nf || '/' || x.serie || ' de '
           || to_char(x.dt_emi,'DD/MM/YYYY') || ', no valor de R$ '
           || fmt_br(x.vl_nf) || ', existe como documento autorizado mas NAO '
           || 'foi encontrada na escrituracao — e o EFD daquele periodo esta '
           || 'carregado. Documento emitido e nao escriturado.',
         'Chave ' || x.chave || '. Situacao no protocolo: ' || x.situacao || '.'
  from v_xml_sem_efd x
  where x.periodo_coberto

  union all
  select 'transferencia_divergente', 'critico', 8,
         null, t.cnpj_saida, t.num_doc,
         'Transferencia com total diferente nas duas escrituracoes',
         1::numeric, abs(t.dif_valor),
         'A NF ' || t.num_doc || ' de ' || to_char(t.dt_doc,'DD/MM/YYYY')
           || ' foi escriturada por R$ ' || fmt_br(t.vl_saida) || ' na saida e '
           || 'por R$ ' || fmt_br(t.vl_entrada) || ' na entrada. A mesma '
           || 'operacao nao pode ter dois valores.',
         'Saida em ' || t.cnpj_saida || ', entrada em ' || t.cnpj_entrada || '.'
  from v_transferencia_divergente t

  union all
  select 'cobertura_item', 'informativo', 9,
         c.uf, c.cnpj, null,
         'Movimento sem detalhe por item na escrituracao',
         (c.saidas_sem_item + c.entradas_sem_item)::numeric, null,
         'Das ' || c.saidas || ' saidas escrituradas, ' || c.saidas_sem_item
           || ' nao trazem o registro C170. Na saida a escrituracao usa o '
           || 'analitico C190, por CST e CFOP, sem detalhe por item. O Kardex '
           || 'dessas operacoes depende do XML da nota.',
         'Estabelecimento de perfil ' || c.ind_perfil || '.'
  from v_cobertura_item c
  where c.saidas_sem_item > 0 or c.entradas_sem_item > 0

  union all
  select 'ressalva', 'informativo', 10,
         null, null, r.tipo, r.tipo, r.qtd_itens, r.valor, r.descricao,
         'Decidido por ' || coalesce(r.decidido_por,'-') || ' em '
           || to_char(r.decidido_em,'DD/MM/YYYY') || '.'
  from auditoria_ressalva r

  order by 3, 9 desc nulls last;
$$;

comment on function relatorio_achados(date) is
  'Todos os achados de uma data em formato unico. Inclui as conciliacoes entre '
  'EFD e XML e entre filiais, agregadas por estabelecimento.';
