-- 024 — Importacao de NF-e em uma chamada.
--
-- Mesmo desenho do EFD: o parser continua em Python e o banco recebe o
-- resultado inteiro. Uma nota fiscal fazia de 5 a 15 chamadas; agora faz uma.

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
        insert into item_pendente (cnpj, parceiro_doc, parceiro_nome,
               c_prod_externo, x_prod, ncm, u_com, ocorrencias, qtd_total,
               vl_total, primeira_chave)
        values (v_cnpj, v_parc,
                case when v_sent = 'entrada' then p->>'emit_nome' else p->>'dest_nome' end,
                it->>'c_prod', it->>'x_prod', it->>'ncm', it->>'u_com', 1,
                (it->>'q_com')::numeric, (it->>'v_prod')::numeric, v_chave)
        on conflict (cnpj, parceiro_doc, c_prod_externo) do update set
          ocorrencias = item_pendente.ocorrencias + 1,
          qtd_total = coalesce(item_pendente.qtd_total,0) + excluded.qtd_total,
          vl_total  = coalesce(item_pendente.vl_total,0) + excluded.vl_total;
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
