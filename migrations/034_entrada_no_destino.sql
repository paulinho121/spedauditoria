-- 034 — O lado de quem RECEBE a nota passa a gerar movimento.
--
-- Até aqui nenhuma nota recebida chegou ao estoque. Nenhuma: de fornecedor ou
-- de filial, toda linha parou no de-para. Numa transferencia SC -> SP isso
-- deixava SC com a saida e SP sem a entrada — o estoque do grupo encolhia a
-- cada transferencia.
--
-- Tres problemas, e os tres precisam ser resolvidos juntos:
--
-- 1. O EFEITO ESTAVA DO LADO ERRADO. O CFOP da nota e o do emitente: 6152 e
--    "transferencia de saida", baixa. Os dois importadores aplicavam esse mesmo
--    efeito a quem recebe — a entrada em SP sairia como saida. Nunca apareceu
--    porque nenhuma entrada chegou a gerar movimento. Quem recebe tem o efeito
--    espelhado: o que saiu de uma mao entrou na outra.
--
--      emitente   baixa  ->  destino soma
--      emitente   soma   ->  destino baixa
--      remessa (para/de terceiros) -> destino NAO gera movimento: a mercadoria
--      troca de mao sem trocar de dono, e o lado do emitente ja registra a
--      mudanca de posse. Lancar tambem no destino contaria duas vezes.
--
-- 2. TRANSFERENCIA ENTRE FILIAIS EXIGIA DE-PARA MANUAL. O grupo usa o mesmo
--    cadastro de codigos na maior parte dos itens: SP vende o "4907 IP STORM
--    1200X" com o mesmo codigo que SC transfere. Mas nao em todos — o 4083 e
--    "MT PRO, tubo de LED" em SC e "AMARAN T2C, luminaria" em SP. Aceitar o
--    codigo as cegas lancaria um produto na conta do outro.
--
--    Regra: numa transferencia interna o codigo do emitente e aceito como o do
--    destino quando
--      · o destino nao conhece o codigo (nem no 0200, nem em nota que ele
--        emitiu) — nao ha com o que colidir; ou
--      · conhece, e a descricao confere: similaridade de trigramas >= 0,30 nos
--        primeiros 40 caracteres, sem acento, que e onde fica o modelo.
--    Senao, vai para o de-para manual como antes.
--
--    O 0,30 foi medido nos dados, nao escolhido: a colisao real (4083) fica em
--    0,10; o produto igual de descricao mais diferente (3881, "B7C") fica em
--    0,36. Nada entre os dois. Na duvida o item continua pendente, que e o erro
--    barato — o caro e somar um produto na conta de outro.
--
--    Cada aceite vira uma linha em item_depara com o motivo e a similaridade,
--    para ser revista e, se preciso, revogada.
--
-- 3. DOIS IMPORTADORES COM A MESMA LOGICA. O servidor local importa em Python
--    (carga_nfe.py) e o Vercel e a linha de comando pelo banco (importar_nfe).
--    O lado do destino passa a existir num lugar so, gerar_movimento_destino(),
--    e os dois chamam. Duplicado, divergiria na primeira correcao.

-- =========================================================== efeito espelhado
create or replace function efeito_no_destino(p_efeito text)
returns text language sql immutable as $$
  select case p_efeito
           when 'baixa' then 'soma'
           when 'soma'  then 'baixa'
         end;
$$;
comment on function efeito_no_destino(text) is
  'Efeito do CFOP do emitente visto por quem recebe. Remessa, simbolico e fora '
  'de escopo nao geram movimento no destino.';


-- ================================================= comparacao de descricao
create or replace function texto_comparavel(p text)
returns text language sql immutable as $$
  select left(regexp_replace(upper(translate(coalesce(p, ''),
           'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
           'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc')),
         '[^A-Z0-9]+', ' ', 'g'), 40);
$$;
comment on function texto_comparavel(text) is
  'Descricao sem acento e pontuacao, 40 primeiros caracteres. descr_norm nao '
  'serve para trigrama: tira os espacos.';


-- ====================================== de-para automatico de transferencia
create or replace function depara_transferencia(
  p_dest text, p_emit text, p_cprod text, p_xprod text)
returns text language plpgsql as $$
declare
  v_melhor numeric;
  v_fontes int;
  v_metodo text;
begin
  -- So entre estabelecimentos auditados. Codigo de fornecedor nunca e aceito.
  if not exists (select 1 from estabelecimento where cnpj = p_emit)
     or not exists (select 1 from estabelecimento where cnpj = p_dest)
     or p_emit = p_dest then
    return null;
  end if;

  select max(similarity(texto_comparavel(p_xprod), texto_comparavel(k.descr))),
         count(*)
    into v_melhor, v_fontes
    from (
      select si.descr_item as descr from sped_item si
       where si.cnpj_estab = p_dest and si.cod_item = p_cprod
      union all
      select ni.x_prod from nfe_item ni join nfe n on n.id = ni.nfe_id
       where n.emit_cnpj = p_dest and ni.c_prod = p_cprod
    ) k;

  if v_fontes = 0 then
    v_metodo := 'transferencia interna: codigo novo no destino';
  elsif v_melhor >= 0.30 then
    v_metodo := 'transferencia interna: descricao confere ('
                || to_char(v_melhor, 'FM0.00') || ')';
  else
    return null;   -- mesmo codigo, produto diferente: colisao
  end if;

  insert into item_depara_todos (cnpj, parceiro_doc, c_prod_externo, cod_item,
                                 fator_unidade, metodo, resolvido_por, resolvido_em)
  values (p_dest, p_emit, p_cprod, p_cprod, 1, v_metodo, 'sistema', now())
  on conflict (trabalho_id, cnpj, coalesce(parceiro_doc, ''), c_prod_externo)
  do nothing;

  return p_cprod;
end $$;
comment on function depara_transferencia(text, text, text, text) is
  'Aceita o codigo do emitente como o do destino numa transferencia interna, '
  'salvo colisao. Grava o aceite em item_depara com o motivo.';


-- ================================================ movimento do lado do destino
create or replace function gerar_movimento_destino(
  p_nfe_id bigint, p_registra_pendencia boolean default true)
returns table (movimentos int, pendencias int, automaticos int)
language plpgsql as $$
declare
  n         record;
  it        record;
  v_ef      text;
  v_desc    text;
  v_ef_dest text;
  v_cod     text;
  v_fator   numeric;
  v_qtd     numeric;
  v_vu      numeric;
  v_auto    boolean;
begin
  movimentos := 0; pendencias := 0; automaticos := 0;

  select * into n from nfe where id = p_nfe_id;
  if n.id is null or n.situacao <> 'autorizada'
     or n.emit_cnpj = n.dest_doc
     or not exists (select 1 from estabelecimento where cnpj = n.dest_doc) then
    return next; return;
  end if;

  for it in select * from nfe_item where nfe_id = p_nfe_id order by n_item loop
    -- Idempotente: reprocessar nao duplica.
    if exists (select 1 from movimento m
                where m.nfe_item_id = it.id and m.cnpj = n.dest_doc) then
      continue;
    end if;

    select c.efeito, c.descricao into v_ef, v_desc
      from cfop_efeito c where c.cfop = it.cfop;
    if v_ef is null then continue; end if;          -- aparece nos bloqueios
    v_ef_dest := efeito_no_destino(v_ef);
    if v_ef_dest is null then continue; end if;     -- remessa: so o emitente lanca

    v_cod := null; v_fator := null; v_auto := false;
    select d.cod_item, d.fator_unidade into v_cod, v_fator
      from item_depara d
     where d.cnpj = n.dest_doc and d.c_prod_externo = it.c_prod
       and (d.parceiro_doc = n.emit_cnpj or d.parceiro_doc is null)
     order by d.parceiro_doc nulls last
     limit 1;

    if v_cod is null then
      v_cod := depara_transferencia(n.dest_doc, n.emit_cnpj, it.c_prod, it.x_prod);
      v_fator := 1;
      v_auto := v_cod is not null;
    end if;

    if v_cod is null then
      if p_registra_pendencia then
        insert into item_pendente_todos (cnpj, parceiro_doc, parceiro_nome,
               c_prod_externo, x_prod, ncm, u_com, ocorrencias, qtd_total,
               vl_total, primeira_chave)
        values (n.dest_doc, n.emit_cnpj, n.emit_nome, it.c_prod, it.x_prod,
                it.ncm, it.u_com, 1, it.q_com, it.v_prod, n.chave)
        on conflict (trabalho_id, cnpj, coalesce(parceiro_doc, ''), c_prod_externo)
        do update set
          ocorrencias = item_pendente_todos.ocorrencias + 1,
          qtd_total = coalesce(item_pendente_todos.qtd_total, 0) + excluded.qtd_total,
          vl_total  = coalesce(item_pendente_todos.vl_total, 0) + excluded.vl_total;
      end if;
      pendencias := pendencias + 1;
      continue;
    end if;

    v_qtd := it.q_com * coalesce(v_fator, 1);
    if v_qtd is null or v_qtd <= 0 then continue; end if;
    v_vu := it.v_prod / v_qtd;

    insert into movimento (cnpj, dt, cod_item, origem, nfe_id, nfe_item_id,
           chave, n_item, cfop, efeito, qtd, vl_unit, vl_total, ind_prop,
           observacao)
    values (n.dest_doc, n.dt_emi, v_cod, 'nfe', n.id, it.id, n.chave, it.n_item,
            it.cfop, v_ef_dest,
            case v_ef_dest when 'soma' then v_qtd else -v_qtd end,
            v_vu, v_qtd * v_vu, '0',
            'entrada · ' || coalesce(v_desc, '')
              || case when v_auto then ' · de-para automatico' else '' end);

    movimentos := movimentos + 1;
    if v_auto then automaticos := automaticos + 1; end if;
  end loop;

  return next;
end $$;
comment on function gerar_movimento_destino(bigint, boolean) is
  'Gera o movimento de quem recebe a nota, com o efeito espelhado. Unico lugar '
  'onde isso acontece: os dois importadores chamam esta funcao.';


-- ============================================ importador pelo banco (Vercel)
-- O emitente continua lancando aqui dentro; o destino passa para a funcao acima.
create or replace function importar_nfe(p jsonb)
returns jsonb
language plpgsql as $$
declare
  v_chave  text := p->>'chave';
  v_sha    text := p->>'sha256';
  v_ja     record;
  v_id     bigint;
  v_movs   int := 0;
  v_pend   int := 0;
  it       jsonb;
  v_item   bigint;
  v_ef     record;
  v_qtd    numeric;
  v_vu     numeric;
  v_dest   record;
begin
  select id, sha256 into v_ja from nfe where chave = v_chave;
  if v_ja.id is not null then
    return jsonb_build_object('situacao',
      case when v_ja.sha256 = v_sha then 'ja_importada' else 'conflito' end,
      'nfe_id', v_ja.id);
  end if;

  if not exists (select 1 from estabelecimento e
                 where e.cnpj = p->>'emit_cnpj' or e.cnpj = p->>'dest_doc') then
    return jsonb_build_object('situacao','fora_do_grupo');
  end if;

  insert into nfe (chave, sha256, nome_arquivo, modelo, serie, num_nf, dh_emi,
         dt_emi, tp_nf, fin_nfe, nat_op, emit_cnpj, emit_nome, emit_uf,
         dest_doc, dest_nome, dest_uf, vl_nf, vl_prod, situacao, importado_por,
         versao_motor)
  values (v_chave, v_sha, p->>'nome_arquivo', p->>'modelo', p->>'serie',
          p->>'num_nf', (p->>'dh_emi')::timestamptz, (p->>'dt_emi')::date,
          p->>'tp_nf', p->>'fin_nfe', p->>'nat_op', p->>'emit_cnpj',
          p->>'emit_nome', p->>'emit_uf', p->>'dest_doc', p->>'dest_nome',
          p->>'dest_uf', (p->>'vl_nf')::numeric, (p->>'vl_prod')::numeric,
          p->>'situacao', p->>'importado_por', p->>'versao_motor')
  returning id into v_id;

  for it in select * from jsonb_array_elements(coalesce(p->'itens','[]'))
  loop
    insert into nfe_item (nfe_id, n_item, c_prod, c_ean, x_prod, x_prod_norm,
           ncm, cest, cfop, u_com, q_com, v_un_com, v_prod, u_trib, q_trib,
           v_desc, v_frete, v_seg, v_outro, ind_tot, cst_icms)
    values (v_id, (it->>'n_item')::int, it->>'c_prod', it->>'c_ean',
            it->>'x_prod', it->>'x_prod_norm', it->>'ncm', it->>'cest',
            it->>'cfop', it->>'u_com', (it->>'q_com')::numeric,
            (it->>'v_un_com')::numeric, (it->>'v_prod')::numeric,
            it->>'u_trib', (it->>'q_trib')::numeric, (it->>'v_desc')::numeric,
            (it->>'v_frete')::numeric, (it->>'v_seg')::numeric,
            (it->>'v_outro')::numeric, it->>'ind_tot', it->>'cst_icms')
    returning id into v_item;

    if p->>'situacao' <> 'autorizada' then continue; end if;
    -- Lado do EMITENTE: nota nossa, o cProd e o nosso codigo e o CFOP e o nosso.
    if not exists (select 1 from estabelecimento where cnpj = p->>'emit_cnpj') then
      continue;
    end if;

    select * into v_ef from cfop_efeito where cfop = it->>'cfop';
    if v_ef.cfop is null then continue; end if;

    v_qtd := (it->>'q_com')::numeric;
    if v_qtd is null or v_qtd <= 0 then continue; end if;
    v_vu := (it->>'v_prod')::numeric / v_qtd;

    insert into movimento (cnpj, dt, cod_item, origem, nfe_id, nfe_item_id,
           chave, n_item, cfop, efeito, qtd, vl_unit, vl_total, ind_prop,
           observacao)
    select p->>'emit_cnpj', (p->>'dt_emi')::date, it->>'c_prod', 'nfe', v_id,
           v_item, v_chave, (it->>'n_item')::int, it->>'cfop', v_ef.efeito,
           m.q, v_vu, abs(m.q) * v_vu, m.prop, 'saida · ' || v_ef.descricao
    from (values
      (case v_ef.efeito when 'soma' then v_qtd when 'baixa' then -v_qtd
            when 'para_terceiros' then -v_qtd when 'de_terceiros' then v_qtd end, '0'),
      (case v_ef.efeito when 'para_terceiros' then v_qtd
            when 'de_terceiros' then -v_qtd end, '1')
    ) as m(q, prop)
    where m.q is not null;
  end loop;

  -- Lado do DESTINO: um lugar so para os dois importadores.
  select * into v_dest from gerar_movimento_destino(v_id, true);

  select count(*) into v_movs from movimento where nfe_id = v_id;
  return jsonb_build_object('situacao','importada','nfe_id',v_id,
                            'movimentos',v_movs,
                            'pendencias',coalesce(v_dest.pendencias, 0),
                            'automaticos',coalesce(v_dest.automaticos, 0));
end $$;


-- ============================================ reprocessar o que ja foi importado
create or replace function reprocessar_destino()
returns table (notas int, movimentos int, automaticos int, pendencias_fechadas int)
language plpgsql as $$
declare
  r   record;
  x   record;
begin
  notas := 0; movimentos := 0; automaticos := 0; pendencias_fechadas := 0;

  for r in select id from nfe where situacao = 'autorizada'
                              and dest_doc in (select cnpj from estabelecimento)
                            order by dt_emi, id loop
    -- false: a pendencia dessas notas ja foi contada quando foram importadas.
    select * into x from gerar_movimento_destino(r.id, false);
    if x.movimentos > 0 then notas := notas + 1; end if;
    movimentos  := movimentos + x.movimentos;
    automaticos := automaticos + x.automaticos;
  end loop;

  -- Pendencia que agora tem de-para deixa de ser pendencia. Nao se apaga:
  -- muda de status, e o historico de que um dia esteve pendente fica.
  update item_pendente p
     set status = 'resolvido'
   where p.status = 'aberto'
     and exists (select 1 from item_depara d
                  where d.cnpj = p.cnpj
                    and coalesce(d.parceiro_doc, '') = coalesce(p.parceiro_doc, '')
                    and d.c_prod_externo = p.c_prod_externo);
  get diagnostics pendencias_fechadas = row_count;

  return next;
end $$;
comment on function reprocessar_destino() is
  'Gera o lado do destino das notas ja importadas no trabalho ativo. '
  'Idempotente. Rodar depois de confirmar um de-para.';


-- ===================================================== bloqueios, por lado
-- A 033 contava por linha de nota. Numa transferencia a linha tem DOIS lados:
-- a saida de SC gerava movimento, a linha contava como resolvida, e a entrada
-- de SP que nao existia ficava invisivel no painel. Agora e por lado.
create or replace function periodo_bloqueios(p_ini date, p_fim date)
returns table (
  motivo      text,
  linhas      bigint,
  notas       bigint,
  quantidade  numeric,
  valor       numeric,
  onde_tratar text
)
language sql stable as $$
  with lado as (
    select v.id as nfe_id, v.situacao, i.id as item_id, i.cfop, i.q_com, i.v_prod,
           e.cnpj,
           case when e.cnpj = v.emit_cnpj then 'emitente' else 'destino' end as lado
      from nfe v
      join nfe_item i on i.nfe_id = v.id
      join estabelecimento e on e.cnpj in (v.emit_cnpj, v.dest_doc)
     where v.dt_emi between p_ini and p_fim
  ), parado as (
    select l.*, c.efeito
      from lado l
      left join cfop_efeito c on c.cfop = l.cfop
     where not exists (select 1 from movimento m
                        where m.nfe_item_id = l.item_id and m.cnpj = l.cnpj)
  ), classificado as (
    select *,
           case
             when situacao <> 'autorizada' then 'nota_nao_autorizada'
             when efeito is null then 'cfop_sem_classificacao'
             when lado = 'emitente' and efeito in ('simbolico', 'fora_escopo')
                  then 'sem_efeito_no_estoque'
             when lado = 'destino' and efeito_no_destino(efeito) is null
                  then 'sem_efeito_no_estoque'
             when lado = 'destino' then 'item_sem_depara'
             else 'outro'
           end as motivo
      from parado
  )
  select motivo,
         count(*)::bigint,
         count(distinct nfe_id)::bigint,
         coalesce(sum(q_com), 0),
         coalesce(sum(v_prod), 0),
         case motivo
           when 'cfop_sem_classificacao' then 'classificar o CFOP'
           when 'item_sem_depara'        then 'ligar o código do fornecedor a um item seu'
           when 'nota_nao_autorizada'    then 'nada a fazer: a nota não existe para o estoque'
           when 'sem_efeito_no_estoque'  then 'nada a fazer: o CFOP não movimenta este lado'
           else 'verificar'
         end
    from classificado
   where motivo <> 'sem_efeito_no_estoque'
   group by motivo
   order by 5 desc nulls last;
$$;


-- ============================================ aplica ao que ja esta no banco
select * from reprocessar_destino();
