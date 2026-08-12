-- 018 — O corte de trivialidade so vale para achado de natureza monetaria.
--
-- A primeira varredura descartou 46 dos 87 achados por ficarem abaixo do
-- trivial. Entre eles, os saldos negativos com valor zero — que sao os mais
-- graves de todos: valor zero ali significa que o item NUNCA teve entrada
-- registrada, so saidas. Materialidade mede distorcao de valor; nao serve para
-- decidir se uma falha estrutural merece atencao.
--
-- Sujeito a materialidade: valoracao e item pendente (o achado E um valor).
-- Sempre listado: saldo negativo, CFOP sem classificacao, mercadoria em
-- terceiros e ressalva (o achado e a existencia do fato).

create or replace function achado_sujeito_a_materialidade(p_tipo text)
returns boolean language sql immutable as $$
  select p_tipo in ('valoracao', 'item_pendente');
$$;

comment on function achado_sujeito_a_materialidade(text) is
  'Diz se o tipo de achado pode ser descartado por ficar abaixo do trivial. '
  'Falha estrutural nunca e trivial, por menor que seja o valor envolvido.';

create or replace function varrer(p_data date, p_quem text default null)
returns TABLE (novos int, mantidos int, resolvidos int, total_aberto int)
language plpgsql as $$
declare
  v_mat   materialidade;
  v_quem  text := coalesce(p_quem, 'sistema');
  v_motor text := '0.4.1';
  v_novos int := 0; v_mant int := 0; v_resol int := 0; v_total int := 0;
  v_hash  text;
  r       record;
begin
  select * into v_mat from materialidade_vigente();

  create temp table _atual on commit drop as
  select chave_achado(a.tipo, a.cnpj, a.cod_item) as chave, a.*
  from relatorio_achados(p_data) a
  where not achado_sujeito_a_materialidade(a.tipo)
     or coalesce(abs(a.valor), 0) >= coalesce(v_mat.trivial, 0);

  create temp table _antes on commit drop as
  select chave from achado;

  for r in select * from _atual loop
    insert into achado (chave, tipo, severidade, data_base, cnpj, uf, cod_item,
                        descr_item, quantidade, valor, motivo, prova, versao_motor)
    values (r.chave, r.tipo, r.severidade, p_data, r.cnpj, r.uf, r.cod_item,
            r.descr_item, r.quantidade, r.valor, r.motivo, r.prova, v_motor)
    on conflict (chave) do update set
      severidade      = excluded.severidade,
      data_base       = greatest(achado.data_base, excluded.data_base),
      quantidade      = excluded.quantidade,
      valor           = excluded.valor,
      motivo          = excluded.motivo,
      prova           = excluded.prova,
      ultima_deteccao = now(),
      execucoes       = achado.execucoes + 1,
      status          = case when achado.status = 'resolvido' then 'aberto'
                             else achado.status end,
      resolvido_em    = case when achado.status = 'resolvido' then null
                             else achado.resolvido_em end;
  end loop;

  -- Novo e o que nao existia antes desta varredura. Comparar por chave e
  -- exato; a versao anterior usava janela de tempo e errava em reexecucao.
  select count(*) into v_novos
    from _atual t where not exists (select 1 from _antes b where b.chave = t.chave);
  select count(*) into v_mant
    from _atual t where exists (select 1 from _antes b where b.chave = t.chave);

  update achado a
     set status = 'resolvido', resolvido_em = now()
   where a.status in ('aberto','em_analise','respondido')
     and a.data_base <= p_data
     and not exists (select 1 from _atual t where t.chave = a.chave);
  get diagnostics v_resol = row_count;

  insert into achado_evento (achado_id, de_status, para_status, quem, nota)
  select a.id, 'aberto', 'resolvido', v_quem,
         'Deixou de ser detectado na varredura de ' || to_char(p_data,'DD/MM/YYYY')
  from achado a where a.resolvido_em > now() - interval '5 seconds';

  select count(*) into v_total from achado where status <> 'resolvido';
  select md5(string_agg(chave || coalesce(valor::text,''), '|' order by chave))
    into v_hash from _atual;

  insert into varredura (data_base, executada_por, versao_motor, materialidade,
                         novos, mantidos, resolvidos, total_aberto, hash_dados)
  values (p_data, v_quem, v_motor, v_mat.id, v_novos, v_mant, v_resol, v_total, v_hash);

  novos := v_novos; mantidos := v_mant; resolvidos := v_resol; total_aberto := v_total;
  return next;
end $$;
