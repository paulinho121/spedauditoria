-- 036 — Evento de cancelamento passa a valer.
--
-- O emissor exporta a nota cancelada so como evento, num -can.xml separado. O
-- leitor recusava esse arquivo por nao ter infNFe, e o cancelamento se perdia
-- como "arquivo ignorado". Se a nota tivesse chegado por outro caminho, ficaria
-- no estoque como venda valida — baixando mercadoria que nunca saiu.
--
-- A regra "nota cancelada nao gera movimento" fica no nivel dos dados, e nao
-- nos importadores, pelo mesmo motivo das anteriores: sao dois importadores, e
-- o evento pode chegar antes ou depois da nota.
--
--   evento chega DEPOIS da nota -> a nota vira cancelada e perde os movimentos
--   evento chega ANTES da nota  -> a nota ja nasce cancelada
--   qualquer movimento de nota nao autorizada e recusado na entrada
--
-- Os movimentos de uma nota cancelada sao APAGADOS, e isso e a excecao ao "nada
-- se apaga". Movimento e derivado: sai da nota pela tabela de CFOP, e se refaz
-- dela a qualquer momento. A prova — a nota e o evento, com hash e protocolo —
-- fica.
--
-- Vale o RETORNO da SEFAZ, nao o pedido: cStat 135 (registrado e vinculado) ou
-- 155 (cancelamento fora de prazo). Um pedido recusado continua sendo um
-- arquivo com tpEvento 110111, e nao cancela nada.

create table if not exists nfe_evento_todos (
  id            bigserial primary key,
  trabalho_id   bigint not null default trabalho_atual()
                references trabalho(id) on delete cascade,
  chave         text not null,
  tp_evento     text not null,
  n_seq         int  not null default 1,
  descricao     text,
  dh_evento     timestamptz,
  cnpj          text,
  c_stat        text,
  protocolo     text,
  justificativa text,
  nome_arquivo  text,
  sha256        text,
  importado_por text,
  importado_em  timestamptz not null default now()
);
create unique index if not exists ux_nfe_evento
  on nfe_evento_todos (trabalho_id, chave, tp_evento, n_seq);
comment on table nfe_evento_todos is
  'Eventos da NF-e (hoje: cancelamento). O evento e prova: guarda arquivo, hash '
  'e protocolo da SEFAZ.';

create or replace view nfe_evento as
  select * from nfe_evento_todos where trabalho_id = trabalho_atual();


create or replace function cancelamento_valido(p_chave text)
returns boolean language sql stable as $$
  select exists (select 1 from nfe_evento
                  where chave = p_chave and tp_evento = '110111'
                    and c_stat in ('135', '155'));
$$;


-- ======================================= evento que chega depois da nota
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
    -- A nota ainda nao esta aqui. Quando chegar, nasce cancelada.
    return jsonb_build_object('situacao',
      case when v_novo then 'cancelamento_guardado' else 'ja_importado' end);
  end if;

  delete from movimento where nfe_id = v_nfe.id;
  get diagnostics v_movs = row_count;
  update nfe set situacao = 'cancelada' where id = v_nfe.id;

  return jsonb_build_object('situacao', 'nota_cancelada', 'nfe_id', v_nfe.id,
                            'num_nf', v_nfe.num_nf, 'movimentos_removidos', v_movs);
end $$;
comment on function registrar_evento(jsonb) is
  'Grava o evento e, se for cancelamento valido, cancela a nota e remove os '
  'movimentos dela. Idempotente.';


-- ======================================= evento que chega antes da nota
create or replace function tg_nfe_nasce_cancelada()
returns trigger language plpgsql as $$
begin
  if cancelamento_valido(new.chave) then
    new.situacao := 'cancelada';
  end if;
  return new;
end $$;

drop trigger if exists nfe_nasce_cancelada on nfe_todos;
create trigger nfe_nasce_cancelada
  before insert on nfe_todos
  for each row execute function tg_nfe_nasce_cancelada();


-- ==================== nota nao autorizada nao gera movimento, por nenhum caminho
-- Os importadores ja pulam nota nao autorizada, mas decidem pela situacao que
-- leram do XML. A nota que nasce cancelada pelo gatilho acima tem o XML dizendo
-- "autorizada". Esta guarda e o que garante a regra independentemente de quem
-- esta gravando.
create or replace function tg_movimento_so_de_nota_valida()
returns trigger language plpgsql as $$
begin
  if new.nfe_id is not null
     and exists (select 1 from nfe_todos n
                  where n.id = new.nfe_id and n.situacao <> 'autorizada') then
    return null;
  end if;
  return new;
end $$;

drop trigger if exists movimento_so_de_nota_valida on movimento_todos;
create trigger movimento_so_de_nota_valida
  before insert on movimento_todos
  for each row execute function tg_movimento_so_de_nota_valida();
