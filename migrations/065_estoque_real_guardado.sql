-- 065 — o cálculo do estoque real fica guardado
--
-- Cada função da tela (produtos, saída sem estoque, retorno sem remessa, em
-- terceiros, resumo) parte da mesma base: os vinte mil movimentos com o saldo
-- corrido de cada produto e de cada terceiro. Recalcular essa base a cada
-- chamada custa uns dois segundos — e o resumo a pede cinco vezes. Na função
-- serverless isso estoura o tempo.
--
-- O extrato não muda depois de importado, então a base também não: ela passa a
-- ser calculada uma vez (erp_real_prepara) e lida de uma tabela. A conta é a
-- mesma da 064, só mudou de lugar: erp_real_calcula faz, erp_real_linhas lê.

create table if not exists erp_real_linha_todos (
  id          bigserial primary key,
  trabalho_id bigint not null default trabalho_atual()
              references trabalho(id) on delete cascade,
  arquivo_id  bigint not null references erp_extrato_arquivo_todos(id) on delete cascade,
  seq int, cod_item text, descr_item text, unid text, dt date, hora text,
  doc_texto text, doc_num text, tipo text, natureza text, terceiro boolean,
  entidade text, entidade_chave text,
  ent numeric, sai numeric, saldo numeric, saldo_impresso numeric,
  fora numeric, remetido numeric, devolvido numeric,
  cura_seq int, lastro_seq int, custo_medio numeric, custo_entrada numeric
);
create index if not exists ix_erp_real_linha
  on erp_real_linha_todos (arquivo_id, cod_item, descr_item, seq);
comment on table erp_real_linha_todos is
  'Base calculada do estoque real: cada movimento do extrato com o saldo '
  'corrido. Derivada de erp_extrato_linha; refeita por erp_real_prepara.';
create or replace view erp_real_linha as
  select * from erp_real_linha_todos where trabalho_id = trabalho_atual();


-- A conta (era erp_real_linhas na 064).
create or replace function erp_real_calcula(p_arquivo_id bigint)
returns table (
  seq int, cod_item text, descr_item text, unid text, dt date, hora text,
  doc_texto text, doc_num text, tipo text, natureza text, terceiro boolean,
  entidade text, entidade_chave text,
  ent numeric, sai numeric,
  saldo numeric, saldo_impresso numeric,
  fora numeric, remetido numeric, devolvido numeric,
  cura_seq int, lastro_seq int, custo_medio numeric, custo_entrada numeric
)
language sql stable as $$
  with l as (
    select x.seq, x.cod_item, coalesce(x.descr_item, '') descr_item, x.unid,
           x.dt, x.hora, x.doc_texto, x.doc_num, x.tipo,
           erp_natureza(x.tipo) natureza, x.entidade,
           upper(regexp_replace(btrim(coalesce(x.entidade, '')), '\s+', ' ', 'g')) entidade_chave,
           coalesce(x.qtd_entrada, 0) ent, coalesce(x.qtd_saida, 0) sai,
           x.qtd_saldo, x.custo_medio, x.custo_entrada
      from erp_extrato_linha x
     where x.arquivo_id = p_arquivo_id and not x.abertura
  ), s as (
    select l.*,
           l.natureza in ('armazem','locacao','comodato','demonstracao',
                          'exposicao','conserto','garantia') terceiro,
           sum(l.ent - l.sai) over (partition by l.cod_item, l.descr_item
                                    order by l.seq) saldo
      from l
  ), p as (
    select s.*,
           sum(s.sai - s.ent) over w  fora,
           sum(s.sai) over w          remetido,
           sum(s.ent) over (partition by s.cod_item, s.descr_item,
                                         s.natureza, s.entidade_chave) devolvido
      from s
    window w as (partition by s.cod_item, s.descr_item, s.natureza, s.entidade_chave
                 order by s.seq)
  )
  select p.seq, p.cod_item, p.descr_item, p.unid, p.dt, p.hora,
         p.doc_texto, p.doc_num, p.tipo, p.natureza, p.terceiro,
         p.entidade, p.entidade_chave, p.ent, p.sai,
         p.saldo, p.qtd_saldo,
         case when p.terceiro then p.fora end,
         case when p.terceiro then p.remetido end,
         case when p.terceiro then p.devolvido end,
         -- A primeira linha seguinte em que o depósito volta a não dever nada.
         min(case when p.saldo >= 0 then p.seq end)
           over (partition by p.cod_item, p.descr_item order by p.seq
                 rows between 1 following and unbounded following),
         -- Idem para o par: a remessa que deu lastro ao retorno adiantado.
         case when p.terceiro then
           min(case when p.fora >= 0 then p.seq end)
             over (partition by p.cod_item, p.descr_item, p.natureza, p.entidade_chave
                   order by p.seq
                   rows between 1 following and unbounded following) end,
         p.custo_medio, p.custo_entrada
    from p
$$;


create or replace function erp_real_prepara(p_arquivo_id bigint)
returns int language plpgsql as $$
declare v_n int;
begin
  delete from erp_real_linha where arquivo_id = p_arquivo_id;
  insert into erp_real_linha (
    arquivo_id, seq, cod_item, descr_item, unid, dt, hora, doc_texto, doc_num,
    tipo, natureza, terceiro, entidade, entidade_chave, ent, sai, saldo,
    saldo_impresso, fora, remetido, devolvido, cura_seq, lastro_seq,
    custo_medio, custo_entrada)
  select p_arquivo_id, c.seq, c.cod_item, c.descr_item, c.unid, c.dt, c.hora,
         c.doc_texto, c.doc_num, c.tipo, c.natureza, c.terceiro, c.entidade,
         c.entidade_chave, c.ent, c.sai, c.saldo, c.saldo_impresso, c.fora,
         c.remetido, c.devolvido, c.cura_seq, c.lastro_seq, c.custo_medio,
         c.custo_entrada
    from erp_real_calcula(p_arquivo_id) c;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
comment on function erp_real_prepara(bigint) is
  'Calcula e guarda a base do estoque real de um extrato. Pode ser chamada de '
  'novo a qualquer momento: apaga e refaz.';


create or replace function erp_real_pronto(p_arquivo_id bigint)
returns boolean language sql stable as $$
  select exists (select 1 from erp_real_linha where arquivo_id = p_arquivo_id)
$$;


-- A leitura: mesmo nome e mesmas colunas da 064, agora vindo da tabela.
create or replace function erp_real_linhas(p_arquivo_id bigint)
returns table (
  seq int, cod_item text, descr_item text, unid text, dt date, hora text,
  doc_texto text, doc_num text, tipo text, natureza text, terceiro boolean,
  entidade text, entidade_chave text,
  ent numeric, sai numeric,
  saldo numeric, saldo_impresso numeric,
  fora numeric, remetido numeric, devolvido numeric,
  cura_seq int, lastro_seq int, custo_medio numeric, custo_entrada numeric
)
language sql stable as $$
  select r.seq, r.cod_item, r.descr_item, r.unid, r.dt, r.hora, r.doc_texto,
         r.doc_num, r.tipo, r.natureza, r.terceiro, r.entidade, r.entidade_chave,
         r.ent, r.sai, r.saldo, r.saldo_impresso, r.fora, r.remetido, r.devolvido,
         r.cura_seq, r.lastro_seq, r.custo_medio, r.custo_entrada
    from erp_real_linha r
   where r.arquivo_id = p_arquivo_id
$$;
