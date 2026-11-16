-- 069 — ajuste manual das quantidades do estoque real
--
-- O estoque real que sai do extrato é um piso: o que o Kardex do ERP prova. O
-- auditor sabe coisas que o extrato não sabe — a contagem física, o extrato do
-- armazém, a mercadoria que voltou sem nota. Ele precisa poder pôr o número
-- certo no lugar do número do ERP.
--
-- O ajuste é uma camada POR CIMA do extrato, nunca dentro dele:
--
--   · vale para um produto e um componente (saldo do depósito, armazém,
--     locação, comodato, demonstração, outros);
--   · guarda a quantidade nova, a que o extrato dava, quem ajustou, quando e
--     por quê;
--   · apagar o ajuste devolve o número do extrato.
--
-- As funções erp_real_* continuam devolvendo o que o extrato diz. Quem soma o
-- ajuste é a tela — e o relatório exportado diz, linha a linha, o que foi
-- mexido e quanto era antes. Número ajustado sem rastro não é papel de trabalho.

create table if not exists erp_real_ajuste_todos (
  id            bigserial primary key,
  trabalho_id   bigint not null default trabalho_atual()
                references trabalho(id) on delete cascade,
  arquivo_id    bigint not null references erp_extrato_arquivo_todos(id) on delete cascade,
  cod_item      text not null,
  descr_item    text not null default '',
  campo         text not null check (campo in (
                  'saldo_erp', 'em_armazem', 'em_locacao', 'em_comodato',
                  'em_demonstracao', 'em_outros')),
  qtd           numeric(18,3) not null,
  qtd_original  numeric(18,3),
  observacao    text,
  ajustado_por  text,
  ajustado_em   timestamptz not null default now()
);
create unique index if not exists ux_erp_real_ajuste
  on erp_real_ajuste_todos (trabalho_id, arquivo_id, cod_item, descr_item, campo);
comment on table erp_real_ajuste_todos is
  'Quantidade informada pelo auditor no lugar da que o extrato do ERP da, por '
  'produto e componente. Camada por cima do extrato; apagar devolve o original.';
create or replace view erp_real_ajuste as
  select * from erp_real_ajuste_todos where trabalho_id = trabalho_atual();


create or replace function erp_real_ajustar(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_arq   bigint := (p->>'arquivo_id')::bigint;
  v_cod   text := p->>'cod_item';
  v_descr text := coalesce(p->>'descr_item', '');
  v_campo text := p->>'campo';
  v_qtd   numeric := nullif(p->>'qtd', '')::numeric;
  v_id    bigint;
begin
  if v_arq is null or v_cod is null or v_campo is null then
    raise exception 'ajuste sem arquivo, produto ou campo';
  end if;
  if not exists (select 1 from erp_extrato_arquivo where id = v_arq) then
    raise exception 'extrato % não encontrado', v_arq;
  end if;

  -- Sem quantidade: desfaz o ajuste e o número do extrato volta a valer.
  if v_qtd is null then
    delete from erp_real_ajuste
     where arquivo_id = v_arq and cod_item = v_cod and descr_item = v_descr
       and campo = v_campo;
    return jsonb_build_object('situacao', 'desfeito');
  end if;

  select id into v_id from erp_real_ajuste
   where arquivo_id = v_arq and cod_item = v_cod and descr_item = v_descr
     and campo = v_campo;
  if v_id is null then
    insert into erp_real_ajuste (arquivo_id, cod_item, descr_item, campo, qtd,
                                 qtd_original, observacao, ajustado_por)
    values (v_arq, v_cod, v_descr, v_campo, v_qtd,
            nullif(p->>'qtd_original', '')::numeric,
            nullif(p->>'observacao', ''), p->>'ajustado_por')
    returning id into v_id;
  else
    -- O original é o do extrato: fica o do primeiro ajuste, não o do anterior.
    update erp_real_ajuste
       set qtd = v_qtd,
           observacao = coalesce(nullif(p->>'observacao', ''), observacao),
           ajustado_por = p->>'ajustado_por', ajustado_em = now()
     where id = v_id;
  end if;
  return jsonb_build_object('situacao', 'ajustado', 'id', v_id);
end $$;
comment on function erp_real_ajustar(jsonb) is
  'Grava (ou, sem qtd, desfaz) o ajuste manual de um componente do estoque '
  'real de um produto.';


create or replace function erp_real_desfazer_ajustes(p_arquivo_id bigint)
returns int language plpgsql as $$
declare v_n int;
begin
  delete from erp_real_ajuste where arquivo_id = p_arquivo_id;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
