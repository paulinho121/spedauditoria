-- 017 — O achado vira objeto, com identidade e ciclo de vida.
--
-- Ate aqui o achado era o resultado de uma consulta: existia enquanto a tela
-- estava aberta. Nao havia "achado 47, aberto em 3 de marco, respondido pelo
-- cliente, aceito". O auditor apontava a divergencia, mandava o relatorio, o
-- cliente respondia — e nada disso voltava para o sistema.
--
-- Aqui o achado ganha identidade estavel, status, responsavel e historico. As
-- regras deixam de SER a lista e passam a ALIMENTAR a lista.

-- ====================================================== materialidade
create table if not exists materialidade (
  id             bigserial primary key,
  escopo         text not null default 'padrao',
  vigente_de     date not null default current_date,
  -- Os tres niveis que uma auditoria usa.
  planejamento   numeric(18,2) not null,
  execucao       numeric(18,2) not null,
  trivial        numeric(18,2) not null,
  -- Limiares das regras. Antes estavam fixos no codigo, escolhidos por mim.
  mult_valoracao      numeric(10,2) not null default 2.0,
  mult_dispersao      numeric(10,2) not null default 1.5,
  pct_margem_negativa numeric(10,2) not null default 5.0,
  meses_sem_giro      int           not null default 12,
  definido_por   text,
  definido_em    timestamptz not null default now(),
  observacao     text
);
comment on table materialidade is
  'Limiares da auditoria. Sao decisao do auditor e constam do papel de '
  'trabalho — nao podem viver no codigo.';
comment on column materialidade.planejamento is
  'Materialidade global: distorcao a partir da qual o trabalho e afetado.';
comment on column materialidade.execucao is
  'Materialidade de execucao: margem de seguranca, tipicamente 60-75% da '
  'materialidade de planejamento.';
comment on column materialidade.trivial is
  'Abaixo disto o achado e contado mas nao listado: e o claramente trivial.';

create or replace function materialidade_vigente(p_escopo text default 'padrao')
returns materialidade language sql stable as $$
  select * from materialidade
  where escopo = p_escopo and vigente_de <= current_date
  order by vigente_de desc, id desc limit 1;
$$;

-- Valores iniciais derivados do proprio estoque: 1% do saldo de abertura como
-- materialidade de planejamento e uma referencia comum em auditoria de estoque.
insert into materialidade (escopo, planejamento, execucao, trivial,
                           definido_por, observacao)
select 'padrao',
       round(sum(vl_item) * 0.01, 2),
       round(sum(vl_item) * 0.0075, 2),
       round(sum(vl_item) * 0.0005, 2),
       'valor inicial do sistema',
       'Derivado do saldo de abertura: 1% de planejamento, 0,75% de execucao e '
       '0,05% de trivial. DEVE ser revisto pelo auditor responsavel.'
from saldo_abertura
where not exists (select 1 from materialidade where escopo = 'padrao');

-- ============================================================ achado
create table if not exists achado (
  id                bigserial primary key,
  chave             text not null unique,
  tipo              text not null,
  severidade        text not null,
  data_base         date not null,
  cnpj              text,
  uf                text,
  cod_item          text,
  descr_item        text,
  quantidade        numeric(18,3),
  valor             numeric(18,2),
  motivo            text,
  prova             text,
  status            text not null default 'aberto',
  responsavel       text,
  prazo             date,
  resposta_cliente  text,
  desfecho          text,
  primeira_deteccao timestamptz not null default now(),
  ultima_deteccao   timestamptz not null default now(),
  resolvido_em      timestamptz,
  execucoes         int not null default 1,
  versao_motor      text
);
comment on table achado is
  'Achado com identidade propria. A chave e estavel entre execucoes: a mesma '
  'divergencia reaparece como o mesmo achado, com o historico preservado.';
comment on column achado.chave is
  'tipo + estabelecimento + objeto. Nao inclui valor nem data: o achado e o '
  'mesmo ainda que o numero mude entre uma varredura e outra.';
comment on column achado.status is
  'aberto | em_analise | respondido | aceito | refutado | resolvido';

create index if not exists ix_achado_status on achado (status, severidade);
create index if not exists ix_achado_tipo   on achado (tipo, data_base);

create table if not exists achado_evento (
  id          bigserial primary key,
  achado_id   bigint not null references achado(id) on delete cascade,
  de_status   text,
  para_status text not null,
  quem        text,
  quando      timestamptz not null default now(),
  nota        text
);
comment on table achado_evento is
  'Historico de transicoes. Nada e sobrescrito: o caminho do achado fica.';
create index if not exists ix_evento_achado on achado_evento (achado_id, quando);

-- ========================================================== varredura
create table if not exists varredura (
  id             bigserial primary key,
  data_base      date not null,
  executada_em   timestamptz not null default now(),
  executada_por  text,
  versao_motor   text,
  materialidade  bigint references materialidade(id),
  novos          int not null default 0,
  mantidos       int not null default 0,
  resolvidos     int not null default 0,
  total_aberto   int not null default 0,
  hash_dados     text
);
comment on table varredura is
  'Cada execucao das regras. Guarda o que mudou e o hash dos dados, para que '
  'um relatorio emitido possa ser reproduzido depois.';


-- ==================================================== motor de varredura
create or replace function chave_achado(p_tipo text, p_cnpj text, p_cod_item text)
returns text language sql immutable as $$
  select p_tipo || '|' || coalesce(p_cnpj,'-') || '|' || coalesce(p_cod_item,'-');
$$;

create or replace function varrer(p_data date, p_quem text default null)
returns TABLE (novos int, mantidos int, resolvidos int, total_aberto int)
language plpgsql as $$
declare
  v_mat    materialidade;
  v_quem   text := coalesce(p_quem, 'sistema');
  v_motor  text := '0.4.0';
  v_novos  int := 0;
  v_mant   int := 0;
  v_resol  int := 0;
  v_total  int := 0;
  v_hash   text;
  r        record;
begin
  select * into v_mat from materialidade_vigente();

  create temp table _atual on commit drop as
  select chave_achado(a.tipo, a.cnpj, a.cod_item) as chave, a.*
  from relatorio_achados(p_data) a
  -- Claramente trivial nao entra na lista: e contado no resumo e some daqui.
  where a.tipo = 'ressalva'
     or coalesce(abs(a.valor), 0) >= coalesce(v_mat.trivial, 0);

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
      -- Achado que voltou a aparecer sai de resolvido e volta para aberto.
      status          = case when achado.status = 'resolvido' then 'aberto'
                             else achado.status end,
      resolvido_em    = case when achado.status = 'resolvido' then null
                             else achado.resolvido_em end;
    if found then null; end if;
  end loop;

  select count(*) into v_novos from achado
   where primeira_deteccao > now() - interval '5 seconds';
  select count(*) into v_mant from _atual;
  v_mant := v_mant - v_novos;

  -- Some da varredura e estava aberto: passa a resolvido, sem ser apagado.
  -- So considera achado de data_base anterior ou igual: varrer uma data antiga
  -- nao pode resolver achado de periodo posterior.
  update achado a
     set status = 'resolvido', resolvido_em = now()
   where a.status in ('aberto', 'em_analise', 'respondido')
     and a.data_base <= p_data
     and not exists (select 1 from _atual t where t.chave = a.chave);
  get diagnostics v_resol = row_count;

  insert into achado_evento (achado_id, de_status, para_status, quem, nota)
  select a.id, 'aberto', 'resolvido', v_quem,
         'Deixou de ser detectado na varredura de ' || to_char(p_data,'DD/MM/YYYY')
  from achado a where a.resolvido_em > now() - interval '5 seconds';

  select count(*) into v_total from achado where status not in ('resolvido');

  select md5(string_agg(chave || coalesce(valor::text,''), '|' order by chave))
    into v_hash from _atual;

  insert into varredura (data_base, executada_por, versao_motor, materialidade,
                         novos, mantidos, resolvidos, total_aberto, hash_dados)
  values (p_data, v_quem, v_motor, v_mat.id, v_novos, greatest(v_mant,0),
          v_resol, v_total, v_hash);

  novos := v_novos; mantidos := greatest(v_mant,0);
  resolvidos := v_resol; total_aberto := v_total;
  return next;
end $$;

comment on function varrer(date, text) is
  'Executa as regras e concilia com os achados ja registrados: cria os novos, '
  'atualiza os que persistem e marca como resolvidos os que sumiram. Nunca '
  'apaga. Achado abaixo do trivial nao entra na lista.';


-- ============================================== mudar o status de um achado
create or replace function achado_mudar_status(
  p_id bigint, p_status text, p_quem text, p_nota text default null)
returns achado language plpgsql as $$
declare
  v_antes text;
  v_out achado;
begin
  select status into v_antes from achado where id = p_id;
  if v_antes is null then
    raise exception 'achado % nao existe', p_id;
  end if;
  if p_status not in ('aberto','em_analise','respondido','aceito','refutado','resolvido') then
    raise exception 'status invalido: %', p_status;
  end if;

  update achado set
    status = p_status,
    resposta_cliente = case when p_status = 'respondido'
                            then coalesce(p_nota, resposta_cliente)
                            else resposta_cliente end,
    desfecho = case when p_status in ('aceito','refutado')
                    then coalesce(p_nota, desfecho) else desfecho end,
    resolvido_em = case when p_status = 'resolvido' then now() else resolvido_em end
  where id = p_id
  returning * into v_out;

  insert into achado_evento (achado_id, de_status, para_status, quem, nota)
  values (p_id, v_antes, p_status, p_quem, p_nota);
  return v_out;
end $$;


-- ===================================================================== visoes
create or replace view v_achado_painel as
select a.*,
       (select count(*) from achado_evento e where e.achado_id = a.id) as eventos,
       case a.status
         when 'aberto'     then 1 when 'em_analise' then 2
         when 'respondido' then 3 when 'refutado'   then 4
         when 'aceito'     then 5 else 6 end as ordem_status,
       case a.severidade
         when 'critico' then 1 when 'alto' then 2
         when 'medio' then 3 else 4 end as ordem_sev
from achado a;

create or replace view v_achado_resumo as
select
  count(*) filter (where status = 'aberto')      as aberto,
  count(*) filter (where status = 'em_analise')  as em_analise,
  count(*) filter (where status = 'respondido')  as respondido,
  count(*) filter (where status = 'aceito')      as aceito,
  count(*) filter (where status = 'refutado')    as refutado,
  count(*) filter (where status = 'resolvido')   as resolvido,
  count(*)                                       as total,
  count(*) filter (where status <> 'resolvido'
                     and severidade = 'critico') as criticos_abertos,
  coalesce(sum(valor) filter (where status not in ('resolvido','refutado')
                                and valor > 0), 0) as exposicao_aberta,
  count(*) filter (where prazo is not null and prazo < current_date
                     and status in ('aberto','em_analise'))  as atrasados
from achado;
