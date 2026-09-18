-- 037 — Reimportar um cancelamento diz que ja estava registrado.
--
-- Na 036, o mesmo -can.xml importado duas vezes respondia de novo "nota
-- cancelada, 0 movimentos removidos". O efeito estava certo — nada mudava —
-- mas o log de importacao dava a entender que algo tinha acontecido.

create or replace function registrar_evento(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_novo  boolean;
  v_nfe   record;
  v_movs  int := 0;
begin
  insert into nfe_evento_todos (chave, tp_evento, n_seq, descricao, dh_evento,
         cnpj, c_stat, protocolo, justificativa, nome_arquivo, sha256,
         importado_por)
  values (p->>'chave', p->>'tp_evento', coalesce((p->>'n_seq')::int, 1),
          p->>'descricao', (p->>'dh_evento')::timestamptz, p->>'cnpj',
          p->>'c_stat', p->>'protocolo', p->>'justificativa',
          p->>'nome_arquivo', p->>'sha256', p->>'importado_por')
  on conflict (trabalho_id, chave, tp_evento, n_seq) do nothing;
  get diagnostics v_movs = row_count;
  v_novo := v_movs > 0;
  v_movs := 0;

  if not cancelamento_valido(p->>'chave') then
    return jsonb_build_object('situacao',
      case when v_novo then 'evento_sem_efeito' else 'ja_importado' end,
      'c_stat', p->>'c_stat');
  end if;

  select id, situacao, num_nf into v_nfe from nfe where chave = p->>'chave';
  if v_nfe.id is null then
    return jsonb_build_object('situacao',
      case when v_novo then 'cancelamento_guardado' else 'ja_importado' end);
  end if;

  if not v_novo and v_nfe.situacao = 'cancelada' then
    return jsonb_build_object('situacao', 'ja_importado', 'nfe_id', v_nfe.id);
  end if;

  delete from movimento where nfe_id = v_nfe.id;
  get diagnostics v_movs = row_count;
  update nfe set situacao = 'cancelada' where id = v_nfe.id;

  return jsonb_build_object('situacao', 'nota_cancelada', 'nfe_id', v_nfe.id,
                            'num_nf', v_nfe.num_nf, 'movimentos_removidos', v_movs);
end $$;
