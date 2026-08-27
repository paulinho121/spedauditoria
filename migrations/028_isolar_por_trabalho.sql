-- 028 — O filtro por trabalho passa a ser invisível para quem lê.
--
-- Cada tabela de dados vira `<nome>_todos` e no lugar do nome original nasce
-- uma view que mostra só o trabalho ativo. Assim as ~30 views e funções que já
-- existem continuam escritas do mesmo jeito e passam a enxergar um trabalho por
-- vez, sem uma linha de mudança em cada uma.
--
-- Três detalhes que sustentam o desenho, todos verificados antes:
--   · view sobre tabela única é gravável, e o INSERT herda o DEFAULT da tabela
--     — por isso trabalho_atual() continua preenchendo sozinho;
--   · trocar o trabalho ativo muda o que a view mostra, sem tocar nos dados;
--   · ON CONFLICT não funciona sobre view. As gravações que usam upsert passam
--     a apontar para a tabela física, com sufixo _todos. É a única concessão.

do $$
declare
  t text;
  cols text;
  tabelas text[] := array[
    'sped_arquivo','estabelecimento','sped_unidade','sped_participante',
    'sped_item','inventario','inventario_item','doc_fiscal','doc_item',
    'nfe','nfe_item','movimento','saldo_abertura','item_depara',
    'item_pendente','achado','varredura','materialidade',
    'auditoria_ressalva','fechamento','importacao_problema'];
begin
  foreach t in array tabelas loop
    -- Já renomeada numa execução anterior? Então nada a fazer.
    if exists (select 1 from information_schema.tables
               where table_schema='public' and table_name = t || '_todos') then
      continue;
    end if;
    execute format('alter table %I rename to %I', t, t || '_todos');
    execute format(
      'create view %I as select * from %I where trabalho_id = trabalho_atual()',
      t, t || '_todos');
    execute format(
      'comment on view %I is %L', t,
      'Mostra apenas o trabalho ativo. A tabela física é ' || t || '_todos; '
      'grave nela quando precisar de ON CONFLICT.');
  end loop;
end $$;

-- achado_evento não tem trabalho_id: é sempre lido pelo achado, que já filtra.
-- Renomear traria complexidade sem ganho.
