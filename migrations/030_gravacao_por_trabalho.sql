-- 030 — As gravações com ON CONFLICT voltam a funcionar.
--
-- Duas coisas as quebraram, e as duas precisam ser desfeitas juntas:
--
--   · a 027 pôs trabalho_id nas chaves únicas. `on conflict (cnpj)` e
--     `on conflict (chave)` deixaram de casar com índice nenhum — importar um
--     EFD ou rodar a varredura falharia agora, antes mesmo da 028;
--   · a 028 trocou as tabelas por views, e ON CONFLICT não funciona sobre view.
--
-- A correção é a mesma nos dois casos: o upsert aponta para a tabela física
-- `*_todos` e o alvo do conflito passa a incluir trabalho_id. Quem grava não
-- precisa dizer a qual trabalho pertence — o DEFAULT trabalho_atual() continua
-- resolvendo isso. As leituras seguem pelas views, filtradas.
--
-- Os INSERTs sem ON CONFLICT ficam como estão: view de tabela única é gravável
-- e herda o DEFAULT.

-- =================================================================== EFD
create or replace function importar_efd(p jsonb)
returns jsonb
language plpgsql as $$
declare
  a        jsonb := p->'arquivo';
  v_sha    text  := a->>'sha256';
  v_cnpj   text  := a->>'cnpj';
  v_dt_ini date  := (a->>'dt_ini')::date;
  v_dt_fin date  := (a->>'dt_fin')::date;
  v_id     bigint; v_inv bigint; v_ja bigint; v_ant int := 0;
  d        jsonb;  v_doc bigint; v_cont jsonb := '{}'::jsonb;
begin
  -- Lê pela view: o mesmo arquivo pode — e deve — ser importado de novo em
  -- outro trabalho sem ser recusado por duplicidade.
  select id into v_ja from sped_arquivo where sha256 = v_sha;
  if v_ja is not null then
    return jsonb_build_object('situacao','ja_importado','arquivo_id',v_ja);
  end if;

  insert into estabelecimento_todos (cnpj, nome, uf, ie)
  values (v_cnpj, a->>'nome_empresa', a->>'uf', a->>'ie')
  on conflict (trabalho_id, cnpj) do update set nome = excluded.nome,
                                   uf = excluded.uf, ie = excluded.ie;

  select count(*) into v_ant from sped_arquivo
   where cnpj = v_cnpj and dt_ini = v_dt_ini and dt_fin = v_dt_fin and vigente;

  insert into sped_arquivo (nome_arquivo, cnpj, nome_empresa, uf, ie, dt_ini,
    dt_fin, cod_fin, cod_ver, ind_perfil, ind_ativ, sha256, importado_por,
    linhas_lidas, contagem_reg, problemas, versao_motor)
  values (a->>'nome_arquivo', v_cnpj, a->>'nome_empresa', a->>'uf', a->>'ie',
          v_dt_ini, v_dt_fin, a->>'cod_fin', a->>'cod_ver', a->>'ind_perfil',
          a->>'ind_ativ', v_sha, a->>'importado_por',
          (a->>'linhas_lidas')::int, a->'contagem', a->'problemas',
          a->>'versao_motor')
  returning id into v_id;

  update sped_arquivo set vigente = false, substituido_por = v_id
   where cnpj = v_cnpj and dt_ini = v_dt_ini and dt_fin = v_dt_fin
     and vigente and id <> v_id;

  insert into sped_unidade_todos (arquivo_id, cnpj, unid, descr, linha_arquivo)
  select v_id, v_cnpj, x.unid, x.descr, x.linha
  from jsonb_to_recordset(coalesce(p->'unidades','[]'))
       as x(unid text, descr text, linha int)
  on conflict do nothing;

  insert into sped_participante_todos (arquivo_id, cnpj_estab, cod_part, nome,
         cod_pais, cnpj, cpf, ie, cod_mun, linha_arquivo)
  select v_id, v_cnpj, x.cod_part, x.nome, x.cod_pais, x.cnpj, x.cpf, x.ie,
         x.cod_mun, x.linha
  from jsonb_to_recordset(coalesce(p->'participantes','[]'))
       as x(cod_part text, nome text, cod_pais text, cnpj text, cpf text,
            ie text, cod_mun text, linha int)
  on conflict do nothing;

  insert into sped_item_todos (arquivo_id, cnpj_estab, cod_item, descr_item,
         descr_norm, cod_barra, unid_inv, tipo_item, ncm, ex_ipi, cod_gen,
         cod_lst, aliq_icms, cest, linha_arquivo)
  select v_id, v_cnpj, x.cod_item, x.descr_item, x.descr_norm, x.cod_barra,
         x.unid_inv, x.tipo_item, x.ncm, x.ex_ipi, x.cod_gen, x.cod_lst,
         x.aliq_icms, x.cest, x.linha
  from jsonb_to_recordset(coalesce(p->'itens','[]'))
       as x(cod_item text, descr_item text, descr_norm text, cod_barra text,
            unid_inv text, tipo_item text, ncm text, ex_ipi text, cod_gen text,
            cod_lst text, aliq_icms numeric, cest text, linha int)
  on conflict do nothing;

  if p->'inventario' is not null and p->'inventario' <> 'null'::jsonb then
    insert into inventario (arquivo_id, cnpj, dt_inv, vl_inv, mot_inv, linha_arquivo)
    values (v_id, v_cnpj, (p->'inventario'->>'dt_inv')::date,
            (p->'inventario'->>'vl_inv')::numeric, p->'inventario'->>'mot_inv',
            (p->'inventario'->>'linha')::int)
    returning id into v_inv;

    insert into inventario_item (inventario_id, cnpj, dt_inv, cod_item, unid,
           qtd, vl_unit, vl_item, ind_prop, cod_part, txt_compl, cod_cta,
           vl_item_ir, linha_arquivo)
    select v_inv, v_cnpj, (p->'inventario'->>'dt_inv')::date, x.cod_item,
           x.unid, x.qtd, x.vl_unit, x.vl_item, x.ind_prop, x.cod_part,
           x.txt_compl, x.cod_cta, x.vl_item_ir, x.linha
    from jsonb_to_recordset(coalesce(p->'inventario_itens','[]'))
         as x(cod_item text, unid text, qtd numeric, vl_unit numeric,
              vl_item numeric, ind_prop text, cod_part text, txt_compl text,
              cod_cta text, vl_item_ir numeric, linha int);
  end if;

  for d in select * from jsonb_array_elements(coalesce(p->'documentos','[]'))
  loop
    insert into doc_fiscal (arquivo_id, cnpj, ind_oper, ind_emit, cod_part,
           cod_mod, cod_sit, ser, num_doc, chv_nfe, dt_doc, dt_e_s, vl_doc,
           linha_arquivo)
    values (v_id, v_cnpj, d->>'ind_oper', d->>'ind_emit', d->>'cod_part',
            d->>'cod_mod', d->>'cod_sit', d->>'ser', d->>'num_doc',
            d->>'chv_nfe', (d->>'dt_doc')::date, (d->>'dt_e_s')::date,
            (d->>'vl_doc')::numeric, (d->>'linha')::int)
    returning id into v_doc;

    insert into doc_item (doc_id, arquivo_id, cnpj, num_item, cod_item, qtd,
           unid, vl_item, vl_desc, cfop, cst_icms, dt_doc, ind_oper,
           linha_arquivo)
    select v_doc, v_id, v_cnpj, nullif(x.num_item,'')::int, x.cod_item, x.qtd,
           x.unid, x.vl_item, x.vl_desc, x.cfop, x.cst_icms,
           (d->>'dt_doc')::date, d->>'ind_oper', x.linha
    from jsonb_to_recordset(coalesce(d->'itens','[]'))
         as x(num_item text, cod_item text, qtd numeric, unid text,
              vl_item numeric, vl_desc numeric, cfop text, cst_icms text,
              linha int);
  end loop;

  insert into importacao_problema (arquivo_id, tipo, detalhe)
  select v_id, x.tipo, x.detalhe
  from jsonb_to_recordset(coalesce(a->'problemas','[]'))
       as x(tipo text, detalhe text);

  select jsonb_build_object(
    '0190', (select count(*) from sped_unidade where arquivo_id = v_id),
    '0150', (select count(*) from sped_participante where arquivo_id = v_id),
    '0200', (select count(*) from sped_item where arquivo_id = v_id),
    'H010', coalesce((select count(*) from inventario_item where inventario_id = v_inv),0),
    'C100', (select count(*) from doc_fiscal where arquivo_id = v_id),
    'C170', (select count(*) from doc_item where arquivo_id = v_id))
  into v_cont;

  return jsonb_build_object(
    'situacao', case when v_ant > 0 then 'substituiu' else 'importado' end,
    'arquivo_id', v_id, 'contagens', v_cont);
end $$;

-- =================================================================== NF-e
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
  v_cnpj   text;
  v_sent   text;
  v_ef     record;
  v_cod    text;
  v_fator  numeric;
  v_parc   text;
  v_qtd    numeric;
  v_vu     numeric;
begin
  select id, sha256 into v_ja from nfe where chave = v_chave;
  if v_ja.id is not null then
    return jsonb_build_object('situacao',
      case when v_ja.sha256 = v_sha then 'ja_importada' else 'conflito' end,
      'nfe_id', v_ja.id);
  end if;

  -- So interessa nota em que um estabelecimento auditado e parte.
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

    select * into v_ef from cfop_efeito where cfop = it->>'cfop';
    if v_ef.cfop is null then continue; end if;

    -- Cada estabelecimento auditado envolvido gera o seu proprio movimento.
    for v_cnpj, v_sent in
      select e.cnpj, case when e.cnpj = p->>'emit_cnpj' then 'saida' else 'entrada' end
      from estabelecimento e
      where e.cnpj = p->>'emit_cnpj' or e.cnpj = p->>'dest_doc'
    loop
      v_parc := case when v_sent = 'saida' then p->>'dest_doc' else p->>'emit_cnpj' end;
      v_cod := null; v_fator := 1;

      if v_sent = 'saida' then
        -- Nota nossa: o cProd E o nosso codigo, por definicao.
        v_cod := it->>'c_prod';
      else
        select cod_item, fator_unidade into v_cod, v_fator from item_depara
         where cnpj = v_cnpj and c_prod_externo = it->>'c_prod'
           and (parceiro_doc = v_parc or parceiro_doc is null)
         limit 1;
      end if;

      if v_cod is null then
        -- O alvo do conflito reproduz ux_pendente, que a 027 recriou com
        -- trabalho_id e com coalesce no parceiro — parceiro nulo tem de colidir
        -- com parceiro nulo.
        insert into item_pendente_todos (cnpj, parceiro_doc, parceiro_nome,
               c_prod_externo, x_prod, ncm, u_com, ocorrencias, qtd_total,
               vl_total, primeira_chave)
        values (v_cnpj, v_parc,
                case when v_sent = 'entrada' then p->>'emit_nome' else p->>'dest_nome' end,
                it->>'c_prod', it->>'x_prod', it->>'ncm', it->>'u_com', 1,
                (it->>'q_com')::numeric, (it->>'v_prod')::numeric, v_chave)
        on conflict (trabalho_id, cnpj, coalesce(parceiro_doc,''), c_prod_externo)
        do update set
          ocorrencias = item_pendente_todos.ocorrencias + 1,
          qtd_total = coalesce(item_pendente_todos.qtd_total,0) + excluded.qtd_total,
          vl_total  = coalesce(item_pendente_todos.vl_total,0) + excluded.vl_total;
        v_pend := v_pend + 1;
        continue;
      end if;

      v_qtd := (it->>'q_com')::numeric * coalesce(v_fator,1);
      if v_qtd is null or v_qtd <= 0 then continue; end if;
      v_vu := (it->>'v_prod')::numeric / v_qtd;

      insert into movimento (cnpj, dt, cod_item, origem, nfe_id, nfe_item_id,
             chave, n_item, cfop, efeito, qtd, vl_unit, vl_total, ind_prop,
             observacao)
      select v_cnpj, (p->>'dt_emi')::date, v_cod, 'nfe', v_id, v_item, v_chave,
             (it->>'n_item')::int, it->>'cfop', v_ef.efeito, m.q, v_vu,
             abs(m.q) * v_vu, m.prop, v_sent || ' · ' || v_ef.descricao
      from (values
        (case v_ef.efeito when 'soma' then v_qtd when 'baixa' then -v_qtd
              when 'para_terceiros' then -v_qtd when 'de_terceiros' then v_qtd end,
         case v_ef.efeito when 'de_terceiros' then '0' else '0' end),
        (case v_ef.efeito when 'para_terceiros' then v_qtd
              when 'de_terceiros' then -v_qtd end, '1')
      ) as m(q, prop)
      where m.q is not null;
      get diagnostics v_movs = row_count;
    end loop;
  end loop;

  select count(*) into v_movs from movimento where nfe_id = v_id;
  return jsonb_build_object('situacao','importada','nfe_id',v_id,
                            'movimentos',v_movs,'pendencias',v_pend);
end $$;

comment on function importar_nfe(jsonb) is
  'Importa uma NF-e ja parseada, em uma chamada e uma transacao, gerando os '
  'movimentos conforme a tabela de efeitos do CFOP.';

-- ============================================================== varredura
create or replace function varrer(p_data date, p_quem text default null)
returns TABLE (novos int, mantidos int, resolvidos int, total_aberto int)
language plpgsql as $$
declare
  v_mat   materialidade;
  v_quem  text := coalesce(p_quem, 'sistema');
  v_motor text := '0.4.2';
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
    insert into achado_todos (chave, tipo, severidade, data_base, cnpj, uf,
                        cod_item, descr_item, quantidade, valor, motivo, prova,
                        versao_motor)
    values (r.chave, r.tipo, r.severidade, p_data, r.cnpj, r.uf, r.cod_item,
            r.descr_item, r.quantidade, r.valor, r.motivo, r.prova, v_motor)
    on conflict (trabalho_id, chave) do update set
      severidade      = excluded.severidade,
      data_base       = greatest(achado_todos.data_base, excluded.data_base),
      quantidade      = excluded.quantidade,
      valor           = excluded.valor,
      motivo          = excluded.motivo,
      prova           = excluded.prova,
      ultima_deteccao = now(),
      execucoes       = achado_todos.execucoes + 1,
      status          = case when achado_todos.status = 'resolvido' then 'aberto'
                             else achado_todos.status end,
      resolvido_em    = case when achado_todos.status = 'resolvido' then null
                             else achado_todos.resolvido_em end;
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

-- ================================================ materialidade do trabalho novo
-- Sem uma linha de materialidade, materialidade_vigente() volta vazia e todo
-- achado passa no corte de trivialidade. O trabalho nasce com o mesmo padrao
-- que a 017 usou no primeiro: percentuais sobre o saldo de abertura. Como o
-- trabalho novo ainda nao tem abertura, ficam nulos e devem ser revistos assim
-- que o inventario for carregado.
create or replace function trabalho_novo(
  p_nome text, p_cliente text default null, p_exercicio text default null,
  p_descricao text default null, p_quem text default null, p_usar boolean default true)
returns trabalho language plpgsql as $$
declare v trabalho;
begin
  insert into trabalho (nome, cliente, exercicio, descricao, criado_por)
  values (p_nome, p_cliente, p_exercicio, p_descricao, coalesce(p_quem,'sistema'))
  returning * into v;

  insert into materialidade_todos (trabalho_id, escopo, definido_por, observacao)
  values (v.id, 'padrao', coalesce(p_quem,'sistema'),
          'Trabalho recem-criado: sem saldo de abertura ainda. Reveja os '
          'limiares depois de importar o inventario.');

  if p_usar then perform trabalho_usar(v.id, p_quem); end if;
  return v;
end $$;
