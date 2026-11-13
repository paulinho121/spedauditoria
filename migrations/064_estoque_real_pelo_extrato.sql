-- 064 — estoque real, e as notas que faltam, a partir do Kardex do ERP
--
-- O extrato de movimentos do ERP diz, nota a nota, o que entrou e o que saiu do
-- depósito. Três coisas nele denunciam estoque errado, e cada uma aponta um
-- tipo de nota que falta:
--
--   1. SAÍDA SEM ESTOQUE — a nota saiu e o saldo do depósito ficou negativo.
--      Falta uma ENTRADA antes dela (retorno do armazém, compra, saldo inicial).
--   2. RETORNO SEM REMESSA — voltou de um terceiro mais do que foi mandado.
--      Falta uma SAÍDA: a remessa, ou o saldo que já estava lá.
--   3. REMESSA SEM RETORNO — o que está em poder de terceiros hoje. Vira erro
--      quando a mercadoria já voltou ou foi vendida e não houve nota de retorno.
--
-- ESTOQUE REAL = saldo do depósito + o que está em terceiros, sem deixar
-- negativo. "Em terceiros" é, por terceiro, o que foi menos o que voltou, só
-- quando sobra; onde voltou a mais, nada está lá — o excesso já está no saldo.
-- Vale a posição de hoje, não o pior momento do caminho: lançamento errado e
-- estornado, ou retorno emitido dias depois da venda, não criam estoque.
--
-- A regra está escrita e testada em auditoria/estoque_real.py; aqui é a mesma
-- conta, em SQL, para a tela.

create or replace function erp_natureza(p_tipo text)
returns text language sql immutable as $$
  -- O tipo de operação do ERP é texto livre. A ordem das regras importa:
  -- "Ent Ret Remet p Dep Fec Armaz" é armazém antes de ser qualquer outra coisa.
  select case
    when t like '%dep fec%' or t like '%armaz%' then 'armazem'
    when t like '%loca%'       then 'locacao'
    when t like '%comodato%'   then 'comodato'
    when t like '%demonstra%'  then 'demonstracao'
    when t like '%exposi%'     then 'exposicao'
    when t like '%conserto%'   then 'conserto'
    when t like '%garantia%'   then 'garantia'
    when t like '%transf%'     then 'transferencia'
    when t like '%brinde%'     then 'brinde'
    when t like '%dev%'        then 'devolucao'
    when t like '%produ%'      then 'producao'
    when t like '%ajust%' or t like '%corre%' or t like '%complement%' then 'ajuste'
    when t like 'v %' or t like '%venda%'  then 'venda'
    when t like 'c p%' or t like '%compra%' then 'compra'
    else 'outros'
  end
  from (select btrim(translate(lower(coalesce(p_tipo, '')),
                               'áàâãäéèêëíìîïóòôõöúùûüç',
                               'aaaaaeeeeiiiiooooouuuuc')) t) x
$$;
comment on function erp_natureza(text) is
  'Natureza da operacao a partir do tipo do ERP (texto livre), por palavra-chave.';


-- Cada movimento com o que a análise precisa: saldo do depósito depois dele,
-- saldo do par (natureza, terceiro) depois dele, e onde cada negativo se cura.
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


-- 1. Saída sem estoque: a nota que precisa de uma ENTRADA antes dela.
create or replace function erp_real_sem_estoque(p_arquivo_id bigint)
returns table (
  seq int, dt date, doc_texto text, doc_num text, tipo text, natureza text,
  entidade text, cod_item text, descr_item text,
  qtd numeric, saldo_depois numeric, descoberto numeric,
  situacao text, coberta_em date, coberta_doc text, coberta_tipo text,
  coberta_natureza text, dias int
)
language sql stable as $$
  with b as (select * from erp_real_linhas(p_arquivo_id))
  select l.seq, l.dt, l.doc_texto, l.doc_num, l.tipo, l.natureza, l.entidade,
         l.cod_item, l.descr_item,
         l.sai, l.saldo, least(l.sai, -l.saldo),
         case when c.seq is null then 'aberta' else 'coberta' end,
         c.dt, c.doc_texto, c.tipo, c.natureza,
         case when c.seq is not null then c.dt - l.dt end
    from b l
    left join b c on c.cod_item = l.cod_item and c.descr_item = l.descr_item
                 and c.seq = l.cura_seq
   where l.sai > 0 and l.saldo < 0
   order by l.dt, l.seq
$$;
comment on function erp_real_sem_estoque(bigint) is
  'Notas de saida emitidas com o deposito sem saldo: precisam de uma entrada '
  'antes. Coberta = a entrada veio depois; aberta = ainda nao veio.';


-- 2. Retorno sem remessa: a nota que precisa de uma SAÍDA antes dela.
create or replace function erp_real_sem_remessa(p_arquivo_id bigint)
returns table (
  seq int, dt date, doc_texto text, doc_num text, tipo text, natureza text,
  entidade text, cod_item text, descr_item text,
  qtd numeric, saldo_depois numeric, sem_lastro numeric,
  situacao text, coberta_em date, coberta_doc text, coberta_tipo text, dias int
)
language sql stable as $$
  with b as (select * from erp_real_linhas(p_arquivo_id) where terceiro)
  select l.seq, l.dt, l.doc_texto, l.doc_num, l.tipo, l.natureza, l.entidade,
         l.cod_item, l.descr_item,
         l.ent, l.fora, least(l.ent, -l.fora),
         case when c.seq is null then 'aberta' else 'coberta' end,
         c.dt, c.doc_texto, c.tipo,
         case when c.seq is not null then c.dt - l.dt end
    from b l
    left join b c on c.cod_item = l.cod_item and c.descr_item = l.descr_item
                 and c.natureza = l.natureza and c.entidade_chave = l.entidade_chave
                 and c.seq = l.lastro_seq
   where l.ent > 0 and l.fora < 0
   order by l.dt, l.seq
$$;
comment on function erp_real_sem_remessa(bigint) is
  'Entradas de retorno de um terceiro sem remessa que as cubra: falta a nota '
  'de saida, ou o saldo que ja estava la quando o ERP comecou.';


-- 3. Remessa sem retorno: o que está em poder de terceiros, nota a nota.
create or replace function erp_real_em_terceiros(p_arquivo_id bigint)
returns table (
  seq int, dt date, doc_texto text, doc_num text, tipo text, natureza text,
  entidade text, cod_item text, descr_item text,
  qtd numeric, pendente numeric, dias int
)
language sql stable as $$
  with b as (select * from erp_real_linhas(p_arquivo_id) where terceiro),
       ref as (select max(dt) dt from erp_extrato_linha where arquivo_id = p_arquivo_id)
  -- Os retornos quitam as remessas mais antigas primeiro: fica pendente, em
  -- cada remessa, o que passa do total que aquele terceiro devolveu.
  select l.seq, l.dt, l.doc_texto, l.doc_num, l.tipo, l.natureza, l.entidade,
         l.cod_item, l.descr_item,
         l.sai, least(l.sai, l.remetido - l.devolvido),
         (select dt from ref) - l.dt
    from b l
   where l.sai > 0 and l.remetido - l.devolvido > 0
   order by l.dt, l.seq
$$;
comment on function erp_real_em_terceiros(bigint) is
  'Remessas ainda nao retornadas, com a quantidade pendente de cada nota e ha '
  'quantos dias esta fora (contados ate o ultimo movimento do extrato).';


-- O produto: onde está, quanto falta, quanto é o estoque real.
create or replace function erp_real_produtos(p_arquivo_id bigint)
returns table (
  cod_item text, descr_item text, unid text, ncm text,
  movimentos bigint, primeira date, ultima date,
  entradas numeric, saidas numeric,
  saldo_erp numeric, saldo_impresso numeric, menor_saldo numeric,
  em_armazem numeric, em_locacao numeric, em_comodato numeric,
  em_demonstracao numeric, em_outros numeric, em_terceiros numeric,
  retorno_sem_remessa numeric, falta_entrada numeric, estoque_real numeric,
  situacao text, cadastros bigint,
  custo numeric, custo_erp numeric, valor_real numeric, saldo_foto numeric
)
language plpgsql stable as $$
#variable_conflict use_column
declare a record; v_foto bigint;
begin
  select * into a from erp_extrato_arquivo where id = p_arquivo_id;
  if a.id is null then return; end if;
  -- A foto de saldo mais recente do mesmo depósito dá o NCM e o custo médio
  -- que o ERP declara, para ficar ao lado do custo da última entrada.
  select f.id into v_foto from erp_saldo_arquivo f
   where f.vigente and f.cnpj is not distinct from a.cnpj
   order by f.dt desc, f.id desc limit 1;

  return query
  with b as (select * from erp_real_linhas(p_arquivo_id)),
  par as (                       -- saldo final de cada (natureza, terceiro)
    select l.cod_item, l.descr_item, l.natureza, l.entidade_chave,
           sum(l.sai - l.ent) fora
      from b l where l.terceiro
     group by 1, 2, 3, 4
  ), terc as (
    select p.cod_item, p.descr_item,
           sum(greatest(p.fora, 0)) filter (where p.natureza = 'armazem')      armazem,
           sum(greatest(p.fora, 0)) filter (where p.natureza = 'locacao')      locacao,
           sum(greatest(p.fora, 0)) filter (where p.natureza = 'comodato')     comodato,
           sum(greatest(p.fora, 0)) filter (where p.natureza = 'demonstracao') demonstracao,
           sum(greatest(p.fora, 0)) filter (where p.natureza in
                 ('exposicao','conserto','garantia'))                          outros,
           sum(greatest(p.fora, 0))  total,
           sum(greatest(-p.fora, 0)) volta_a_mais
      from par p group by 1, 2
  ), prod as (
    select l.cod_item, l.descr_item, max(l.unid) unid,
           count(*) movimentos, min(l.dt) primeira, max(l.dt) ultima,
           sum(l.ent) entradas, sum(l.sai) saidas,
           sum(l.ent - l.sai) saldo,
           (array_agg(l.saldo_impresso order by l.seq desc))[1] impresso,
           least(min(l.saldo), 0) menor,
           -- Custo unitário da última entrada. O custo MÉDIO do extrato não
           -- serve: a saída por venda vem com custo zero, o custo do saldo não
           -- baixa, e a média seguinte sai inflada (ou negativa, quando o saldo
           -- passou por negativo). A entrada traz o custo do documento.
           (array_agg(l.custo_entrada / l.ent order by l.seq desc)
              filter (where l.ent > 0 and l.custo_entrada > 0))[1] cm
      from b l group by 1, 2
  ), calc as (
    select p.*, coalesce(t.armazem, 0) armazem, coalesce(t.locacao, 0) locacao,
           coalesce(t.comodato, 0) comodato, coalesce(t.demonstracao, 0) demonstracao,
           coalesce(t.outros, 0) outros, coalesce(t.total, 0) terceiros,
           coalesce(t.volta_a_mais, 0) volta_a_mais,
           p.saldo + coalesce(t.total, 0) posicao,
           count(*) over (partition by p.cod_item) cadastros
      from prod p
      left join terc t on t.cod_item = p.cod_item and t.descr_item = p.descr_item
  )
  select c.cod_item, c.descr_item, c.unid, f.ncm,
         c.movimentos, c.primeira, c.ultima, c.entradas, c.saidas,
         c.saldo, c.impresso, c.menor,
         c.armazem, c.locacao, c.comodato, c.demonstracao, c.outros, c.terceiros,
         c.volta_a_mais,
         greatest(-c.posicao, 0), greatest(c.posicao, 0),
         case when c.posicao < 0      then 'falta_entrada'
              when c.saldo < 0        then 'negativo_hoje'
              when c.volta_a_mais > 0 then 'retorno_sem_remessa'
              when c.menor < 0        then 'ficou_negativo'
              else 'ok' end,
         c.cadastros,
         round(c.cm, 4), round(f.custo, 4),
         round(greatest(c.posicao, 0) * c.cm, 2),
         f.qtd
    from calc c
    left join lateral (
      -- Mesmo código em dois cadastros: casa primeiro pela descrição.
      select s.ncm, nullif(greatest(s.custo_unit, 0), 0) custo, s.qtd
        from erp_saldo_linha s
       where s.arquivo_id = v_foto and s.cod_item = c.cod_item
       order by (coalesce(s.descr_item, '') = c.descr_item) desc, s.seq
       limit 1
    ) f on true
   order by case when c.cod_item ~ '^\d+$' then lpad(c.cod_item, 20, '0')
                 else c.cod_item end, c.descr_item;
end $$;
comment on function erp_real_produtos(bigint) is
  'Por produto do extrato: saldo do deposito, em poder de terceiros por '
  'natureza, retorno sem remessa, entrada que falta e estoque real.';


-- O que o próprio extrato tem de estranho, antes de qualquer conclusão.
create or replace function erp_real_inconsistencias(p_arquivo_id bigint)
returns table (
  seq int, dt date, doc_texto text, tipo text, entidade text,
  cod_item text, descr_item text, problema text, detalhe text,
  ent numeric, sai numeric, saldo_impresso numeric, saldo_calculado numeric
)
language sql stable as $$
  with b as (
    select l.*,
           lag(l.saldo_impresso) over (partition by l.cod_item, l.descr_item
                                       order by l.seq) impresso_ant
      from erp_real_linhas(p_arquivo_id) l
  )
  select l.seq, l.dt, l.doc_texto, l.tipo, l.entidade, l.cod_item, l.descr_item,
         'saldo_nao_fecha',
         'o ERP imprime saldo ' || trim(to_char(l.saldo_impresso, 'FM999G999G990D999')) ||
         '; pelo anterior e pelo movimento seria ' ||
         trim(to_char(coalesce(l.impresso_ant, 0) + l.ent - l.sai, 'FM999G999G990D999')),
         l.ent, l.sai, l.saldo_impresso, l.saldo
    from b l
   where l.saldo_impresso is not null
     and abs(coalesce(l.impresso_ant, 0) + l.ent - l.sai - l.saldo_impresso) > 0.001
  union all
  select l.seq, l.dt, l.doc_texto, l.tipo, l.entidade, l.cod_item, l.descr_item,
         'quantidade_fracionada',
         'quantidade com fração num item vendido por unidade',
         l.ent, l.sai, l.saldo_impresso, l.saldo
    from b l
   where lower(coalesce(l.unid, '')) in ('un', 'und', 'unid', 'pc', 'pç', 'pca')
     and (l.ent <> trunc(l.ent) or l.sai <> trunc(l.sai))
   order by 2, 1
$$;


create or replace function erp_real_resumo(p_arquivo_id bigint)
returns jsonb language sql stable as $$
  with p as (select * from erp_real_produtos(p_arquivo_id)),
       se as (select * from erp_real_sem_estoque(p_arquivo_id)),
       sr as (select * from erp_real_sem_remessa(p_arquivo_id)),
       et as (select * from erp_real_em_terceiros(p_arquivo_id))
  select jsonb_build_object(
    'produtos', (select count(*) from p),
    'movimentos', (select coalesce(sum(movimentos), 0) from p),
    'primeira', (select min(primeira) from p),
    'ultima', (select max(ultima) from p),
    'saldo_erp', (select coalesce(sum(saldo_erp), 0) from p),
    'negativos_hoje', (select count(*) from p where saldo_erp < 0),
    'qtd_negativa_hoje', (select coalesce(-sum(saldo_erp), 0) from p where saldo_erp < 0),
    'em_terceiros', (select coalesce(sum(em_terceiros), 0) from p),
    'em_armazem', (select coalesce(sum(em_armazem), 0) from p),
    'em_locacao', (select coalesce(sum(em_locacao), 0) from p),
    'em_comodato', (select coalesce(sum(em_comodato), 0) from p),
    'em_demonstracao', (select coalesce(sum(em_demonstracao), 0) from p),
    'em_outros', (select coalesce(sum(em_outros), 0) from p),
    'retorno_sem_remessa', (select coalesce(sum(retorno_sem_remessa), 0) from p),
    'falta_entrada', (select coalesce(sum(falta_entrada), 0) from p),
    'produtos_falta_entrada', (select count(*) from p where falta_entrada > 0),
    'estoque_real', (select coalesce(sum(estoque_real), 0) from p),
    'valor_real', (select coalesce(sum(valor_real), 0) from p),
    'sem_custo', (select count(*) from p where estoque_real > 0 and custo is null),
    'situacoes', (select jsonb_object_agg(situacao, n)
                    from (select situacao, count(*) n from p group by 1) x),
    'sem_estoque_linhas', (select count(*) from se),
    'sem_estoque_notas', (select count(distinct doc_texto) from se),
    'sem_estoque_qtd', (select coalesce(sum(descoberto), 0) from se),
    'sem_estoque_abertas', (select count(*) from se where situacao = 'aberta'),
    'sem_estoque_abertas_notas',
       (select count(distinct doc_texto) from se where situacao = 'aberta'),
    'sem_estoque_abertas_qtd',
       (select coalesce(sum(descoberto), 0) from se where situacao = 'aberta'),
    'sem_remessa_linhas', (select count(*) from sr),
    'sem_remessa_notas', (select count(distinct doc_texto) from sr),
    'sem_remessa_qtd', (select coalesce(sum(sem_lastro), 0) from sr),
    'sem_remessa_abertas', (select count(*) from sr where situacao = 'aberta'),
    'sem_remessa_abertas_notas',
       (select count(distinct doc_texto) from sr where situacao = 'aberta'),
    'em_terceiros_linhas', (select count(*) from et),
    'em_terceiros_notas', (select count(distinct doc_texto) from et),
    'em_terceiros_qtd', (select coalesce(sum(pendente), 0) from et),
    'inconsistencias', (select count(*) from erp_real_inconsistencias(p_arquivo_id))
  ) || (
    -- O custo do extrato: saída sem custo não baixa o custo do saldo, e o custo
    -- médio seguinte sai errado. Contado aqui para a tela dizer o tamanho.
    select jsonb_build_object(
      'saidas', count(*) filter (where x.qtd_saida > 0),
      'saidas_custo_zero',
         count(*) filter (where x.qtd_saida > 0 and coalesce(x.custo_saida, 0) = 0),
      'vendas', count(*) filter (where x.qtd_saida > 0 and erp_natureza(x.tipo) = 'venda'),
      'vendas_custo_zero',
         count(*) filter (where x.qtd_saida > 0 and coalesce(x.custo_saida, 0) = 0
                            and erp_natureza(x.tipo) = 'venda'),
      'custo_medio_negativo', count(*) filter (where x.custo_medio < 0),
      'saldo_zero_com_custo',
         count(*) filter (where x.qtd_saldo = 0 and x.custo_saldo > 0.01))
      from erp_extrato_linha x
     where x.arquivo_id = p_arquivo_id and not x.abertura
  )
$$;
comment on function erp_real_resumo(bigint) is
  'Os numeros do topo da tela Estoque real.';
