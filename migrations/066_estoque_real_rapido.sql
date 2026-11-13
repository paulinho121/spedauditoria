-- 066 — as listas de notas sem o cruzamento caro
--
-- "Saída sem estoque" e "retorno sem remessa" precisam, para cada nota, da
-- linha que a cobriu (a entrada que zerou o negativo; a remessa que deu
-- lastro). A 064 achava essa linha cruzando a base com ela mesma por produto —
-- quatro mil notas contra vinte mil movimentos, quinze segundos.
--
-- O número da linha (seq) é único dentro do arquivo: basta buscá-la por ele.
-- Com o índice abaixo, cada nota acha a sua cobertura direto.

create index if not exists ix_erp_real_linha_seq
  on erp_real_linha_todos (arquivo_id, seq);

create or replace function erp_real_sem_estoque(p_arquivo_id bigint)
returns table (
  seq int, dt date, doc_texto text, doc_num text, tipo text, natureza text,
  entidade text, cod_item text, descr_item text,
  qtd numeric, saldo_depois numeric, descoberto numeric,
  situacao text, coberta_em date, coberta_doc text, coberta_tipo text,
  coberta_natureza text, dias int
)
language sql stable as $$
  select l.seq, l.dt, l.doc_texto, l.doc_num, l.tipo, l.natureza, l.entidade,
         l.cod_item, l.descr_item,
         l.sai, l.saldo, least(l.sai, -l.saldo),
         case when c.seq is null then 'aberta' else 'coberta' end,
         c.dt, c.doc_texto, c.tipo, c.natureza,
         case when c.seq is not null then c.dt - l.dt end
    from erp_real_linha l
    left join erp_real_linha c on c.arquivo_id = l.arquivo_id and c.seq = l.cura_seq
   where l.arquivo_id = p_arquivo_id and l.sai > 0 and l.saldo < 0
   order by l.dt, l.seq
$$;

create or replace function erp_real_sem_remessa(p_arquivo_id bigint)
returns table (
  seq int, dt date, doc_texto text, doc_num text, tipo text, natureza text,
  entidade text, cod_item text, descr_item text,
  qtd numeric, saldo_depois numeric, sem_lastro numeric,
  situacao text, coberta_em date, coberta_doc text, coberta_tipo text, dias int
)
language sql stable as $$
  select l.seq, l.dt, l.doc_texto, l.doc_num, l.tipo, l.natureza, l.entidade,
         l.cod_item, l.descr_item,
         l.ent, l.fora, least(l.ent, -l.fora),
         case when c.seq is null then 'aberta' else 'coberta' end,
         c.dt, c.doc_texto, c.tipo,
         case when c.seq is not null then c.dt - l.dt end
    from erp_real_linha l
    left join erp_real_linha c on c.arquivo_id = l.arquivo_id and c.seq = l.lastro_seq
   where l.arquivo_id = p_arquivo_id and l.terceiro and l.ent > 0 and l.fora < 0
   order by l.dt, l.seq
$$;
