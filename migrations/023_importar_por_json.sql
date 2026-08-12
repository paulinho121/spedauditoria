-- 023 — Importacao em uma chamada, com o arquivo ja parseado.
--
-- A carga fazia ~220 chamadas ao banco por EFD: uma por lote de cada registro e
-- duas por documento fiscal. Na maquina local isso custa 7 minutos; numa funcao
-- serverless, que morre em 10 a 60 segundos, e inviavel.
--
-- Aqui o parser continua em Python — ele e puro e tem teste golden — mas o
-- resultado vai inteiro num jsonb e o banco faz todos os inserts de uma vez,
-- dentro de uma transacao. De ~220 chamadas para 1.
--
-- Efeito colateral bem-vindo: a importacao volta a ser atomica mesmo pelo
-- caminho sem DATABASE_URL, porque a transacao agora e do lado do banco.

create or replace function importar_efd(p jsonb)
returns jsonb
language plpgsql as $$
declare
  a          jsonb := p->'arquivo';
  v_sha      text  := a->>'sha256';
  v_cnpj     text  := a->>'cnpj';
  v_dt_ini   date  := (a->>'dt_ini')::date;
  v_dt_fin   date  := (a->>'dt_fin')::date;
  v_id       bigint;
  v_inv      bigint;
  v_ja       bigint;
  v_ant      int := 0;
  d          jsonb;
  v_doc      bigint;
  v_cont     jsonb := '{}'::jsonb;
begin
  select id into v_ja from sped_arquivo where sha256 = v_sha;
  if v_ja is not null then
    return jsonb_build_object('situacao','ja_importado','arquivo_id',v_ja);
  end if;

  insert into estabelecimento (cnpj, nome, uf, ie)
  values (v_cnpj, a->>'nome_empresa', a->>'uf', a->>'ie')
  on conflict (cnpj) do update set nome = excluded.nome, uf = excluded.uf,
                                   ie = excluded.ie;

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

  insert into sped_unidade (arquivo_id, cnpj, unid, descr, linha_arquivo)
  select v_id, v_cnpj, x.unid, x.descr, x.linha
  from jsonb_to_recordset(coalesce(p->'unidades','[]'))
       as x(unid text, descr text, linha int)
  on conflict do nothing;

  insert into sped_participante (arquivo_id, cnpj_estab, cod_part, nome,
         cod_pais, cnpj, cpf, ie, cod_mun, linha_arquivo)
  select v_id, v_cnpj, x.cod_part, x.nome, x.cod_pais, x.cnpj, x.cpf, x.ie,
         x.cod_mun, x.linha
  from jsonb_to_recordset(coalesce(p->'participantes','[]'))
       as x(cod_part text, nome text, cod_pais text, cnpj text, cpf text,
            ie text, cod_mun text, linha int)
  on conflict do nothing;

  insert into sped_item (arquivo_id, cnpj_estab, cod_item, descr_item,
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
    select v_doc, v_id, v_cnpj, x.num_item, x.cod_item, x.qtd, x.unid,
           x.vl_item, x.vl_desc, x.cfop, x.cst_icms, (d->>'dt_doc')::date,
           d->>'ind_oper', x.linha
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

comment on function importar_efd(jsonb) is
  'Importa um EFD ja parseado, em uma chamada e uma transacao. O parser fica em '
  'Python, onde tem teste golden; aqui entra so a gravacao.';
