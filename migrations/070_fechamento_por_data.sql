-- 070 — fechamento do estoque real, por data
--
-- Para cada fechamento de mês o auditor corrige quantidades e tira do cálculo o
-- que foi emitido de forma errada (uma nota, um produto). Isso é decisão dele
-- sobre uma data, e precisa sobreviver a recarregar a página e ao servidor —
-- por isso fica no banco, e não no navegador.
--
-- Cada linha é uma decisão, identificada por 'chave' (ver chave_fechamento em
-- auditoria/estoque_real.py): um ajuste de quantidade, uma nota excluída ou um
-- produto excluído. Gravar a mesma chave de novo substitui; remover apaga.
-- O extrato original nunca muda: o fechamento é uma camada por cima dele.

create table if not exists erp_fechamento_todos (
  id           bigserial primary key,
  trabalho_id  bigint not null default trabalho_atual()
               references trabalho(id) on delete cascade,
  arquivo_id   bigint not null references erp_extrato_arquivo_todos(id) on delete cascade,
  data_ref     date not null,
  chave        text not null,
  tipo         text not null check (tipo in ('ajuste', 'nota', 'produto')),
  cod_item     text,
  descr_item   text not null default '',
  campo        text,
  qtd          numeric(18,3),
  qtd_original numeric(18,3),
  doc_texto    text,
  dt           date,
  nota_tipo    text,
  entidade     text not null default '',
  observacao   text,
  feito_por    text,
  feito_em     timestamptz not null default now(),
  unique (trabalho_id, arquivo_id, data_ref, chave)
);
create index if not exists ix_erp_fechamento on erp_fechamento_todos (arquivo_id, data_ref);
comment on table erp_fechamento_todos is
  'Decisoes do auditor sobre uma data do estoque real: quantidades corrigidas, '
  'notas e produtos excluidos. Camada por cima do extrato; nao altera o extrato.';

create or replace view erp_fechamento as
  select * from erp_fechamento_todos where trabalho_id = trabalho_atual();


create or replace function erp_fechamento_gravar(p jsonb)
returns jsonb language plpgsql as $$
begin
  insert into erp_fechamento_todos (arquivo_id, data_ref, chave, tipo, cod_item, descr_item,
    campo, qtd, qtd_original, doc_texto, dt, nota_tipo, entidade, observacao, feito_por)
  values ((p->>'arquivo_id')::bigint, (p->>'data_ref')::date, p->>'chave', p->>'tipo',
    p->>'cod_item', coalesce(p->>'descr_item', ''), p->>'campo',
    nullif(p->>'qtd', '')::numeric, nullif(p->>'qtd_original', '')::numeric,
    p->>'doc_texto', nullif(p->>'dt', '')::date, p->>'nota_tipo',
    coalesce(p->>'entidade', ''), p->>'observacao', p->>'feito_por')
  on conflict (trabalho_id, arquivo_id, data_ref, chave) do update
    set qtd = excluded.qtd,
        -- O original é o do extrato: fica o do primeiro ajuste, não o do último.
        qtd_original = coalesce(erp_fechamento_todos.qtd_original, excluded.qtd_original),
        observacao = coalesce(excluded.observacao, erp_fechamento_todos.observacao),
        feito_por = excluded.feito_por,
        feito_em = now();
  return jsonb_build_object('situacao', 'gravado');
end $$;
comment on function erp_fechamento_gravar(jsonb) is
  'Grava uma decisao do fechamento (ajuste, nota ou produto excluido).';


create or replace function erp_fechamento_remover(p jsonb)
returns jsonb language plpgsql as $$
declare v_n int;
begin
  delete from erp_fechamento_todos
   where trabalho_id = trabalho_atual()
     and arquivo_id = (p->>'arquivo_id')::bigint
     and data_ref = (p->>'data_ref')::date
     and chave = p->>'chave';
  get diagnostics v_n = row_count;
  return jsonb_build_object('situacao', 'removido', 'linhas', v_n);
end $$;
comment on function erp_fechamento_remover(jsonb) is
  'Apaga uma decisao do fechamento: o item volta a valer como estava no extrato.';


create or replace function erp_fechamento_limpar(p jsonb)
returns jsonb language plpgsql as $$
declare v_n int;
begin
  delete from erp_fechamento_todos
   where trabalho_id = trabalho_atual()
     and arquivo_id = (p->>'arquivo_id')::bigint
     and data_ref = (p->>'data_ref')::date;
  get diagnostics v_n = row_count;
  return jsonb_build_object('situacao', 'limpo', 'linhas', v_n);
end $$;
comment on function erp_fechamento_limpar(jsonb) is
  'Apaga todas as decisoes do fechamento de uma data.';
