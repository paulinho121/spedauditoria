-- 039 — Onze CFOPs classificados, e as notas ja importadas reprocessadas.
--
-- Julho/2026 tinha 38 linhas de nota (R$ 154 mil) paradas por CFOP sem
-- classificacao. Classificacao aprovada pelo auditor em 18/09/2026.
--
-- O par que exige cuidado e o da venda para entrega futura: a 5922/6922 e so o
-- faturamento, a mercadoria sai depois, na 5117/6117. Se as duas baixassem, a
-- mesma mercadoria sairia duas vezes. Baixa a remessa; o faturamento e
-- simbolico.
--
-- Ate aqui so o lado de quem RECEBE podia ser reprocessado. Classificar um CFOP
-- nao fazia as notas ja importadas ganharem movimento do lado de quem EMITE — so
-- as importadas dali em diante. gerar_movimento_emitente() resolve isso, e o
-- importador passa a chamar a mesma funcao: a regra do emitente fica num lugar
-- so, como ja estava a do destino.

insert into cfop_efeito (cfop, descricao, sentido, efeito, move_fisico,
                         muda_propriedade, compoe_custo, observacao) values
 ('5922','Faturamento de venda para entrega futura','saida','simbolico',false,false,false,
  'So faturamento. A saida fisica e a 5117 — baixar as duas contaria duas vezes'),
 ('6922','Faturamento de venda para entrega futura, outro estado','saida','simbolico',false,false,false,
  'So faturamento. A saida fisica e a 6117 — baixar as duas contaria duas vezes'),
 ('5117','Venda de mercadoria adquirida, originada de encomenda para entrega futura','saida','baixa',true,true,false,
  'Saida fisica da venda para entrega futura faturada na 5922'),
 ('6117','Venda de mercadoria adquirida, originada de encomenda para entrega futura, outro estado','saida','baixa',true,true,false,
  'Saida fisica da venda para entrega futura faturada na 6922'),
 ('5910','Remessa em bonificacao, doacao ou brinde','saida','baixa',true,true,false,
  'A mercadoria sai e deixa de ser nossa'),
 ('6912','Remessa de mercadoria para demonstracao, outro estado','saida','para_terceiros',true,false,false,
  'Continua nossa, em poder de terceiro'),
 ('2915','Entrada de mercadoria recebida para conserto, outro estado','entrada','fora_escopo',true,false,false,
  'Bem de terceiro: nao e estoque nosso'),
 ('6916','Retorno de mercadoria recebida para conserto, outro estado','saida','fora_escopo',true,false,false,
  'Devolve bem de terceiro: nao e estoque nosso'),
 ('6557','Transferencia de material de uso ou consumo, outro estado','saida','fora_escopo',true,false,false,
  'Uso e consumo, nao mercadoria'),
 ('5655','Venda de combustivel ou lubrificante adquirido de terceiros','saida','fora_escopo',true,true,false,
  'Recebida de oficina: consumo, nao mercadoria para revenda'),
 ('5656','Venda de combustivel ou lubrificante a consumidor final','saida','fora_escopo',true,true,false,
  'Recebida de oficina: consumo, nao mercadoria para revenda')
on conflict (cfop) do nothing;


-- ================================================ movimento do lado de quem emite
create or replace function gerar_movimento_emitente(p_nfe_id bigint)
returns int language plpgsql as $$
declare
  n      record;
  it     record;
  v_ef   record;
  v_vu   numeric;
  v_movs int := 0;
  k      int;
begin
  select * into n from nfe where id = p_nfe_id;
  if n.id is null or n.situacao <> 'autorizada'
     or not exists (select 1 from estabelecimento where cnpj = n.emit_cnpj) then
    return 0;
  end if;

  for it in select * from nfe_item where nfe_id = p_nfe_id order by n_item loop
    -- Idempotente: reprocessar nao duplica.
    if exists (select 1 from movimento m
                where m.nfe_item_id = it.id and m.cnpj = n.emit_cnpj) then
      continue;
    end if;
    select * into v_ef from cfop_efeito where cfop = it.cfop;
    if v_ef.cfop is null then continue; end if;
    if it.q_com is null or it.q_com <= 0 then continue; end if;
    v_vu := it.v_prod / it.q_com;

    -- Nota nossa: o cProd e o nosso codigo, e o CFOP e o nosso.
    insert into movimento (cnpj, dt, cod_item, origem, nfe_id, nfe_item_id,
           chave, n_item, cfop, efeito, qtd, vl_unit, vl_total, ind_prop,
           observacao)
    select n.emit_cnpj, n.dt_emi, it.c_prod, 'nfe', n.id, it.id, n.chave,
           it.n_item, it.cfop, v_ef.efeito, m.q, v_vu, abs(m.q) * v_vu, m.prop,
           'saida · ' || v_ef.descricao
    from (values
      (case v_ef.efeito when 'soma' then it.q_com when 'baixa' then -it.q_com
            when 'para_terceiros' then -it.q_com when 'de_terceiros' then it.q_com end, '0'),
      (case v_ef.efeito when 'para_terceiros' then it.q_com
            when 'de_terceiros' then -it.q_com end, '1')
    ) as m(q, prop)
    where m.q is not null;
    get diagnostics k = row_count;
    v_movs := v_movs + k;
  end loop;
  return v_movs;
end $$;
comment on function gerar_movimento_emitente(bigint) is
  'Gera o movimento de quem emite a nota. Idempotente. Unico lugar da regra: o '
  'importador e o reprocessamento chamam esta funcao.';


-- ================================= importador: as duas pontas em funcoes proprias
create or replace function importar_nfe(p jsonb)
returns jsonb
language plpgsql as $$
declare
  v_chave  text := p->>'chave';
  v_sha    text := p->>'sha256';
  v_ja     record;
  v_id     bigint;
  v_movs   int := 0;
  it       jsonb;
  v_dest   record;
begin
  select id, sha256 into v_ja from nfe where chave = v_chave;
  if v_ja.id is not null then
    if v_ja.sha256 = v_sha then
      return jsonb_build_object('situacao', 'ja_importada', 'nfe_id', v_ja.id);
    end if;
    if nfe_mesmo_conteudo(v_ja.id, p) then
      return jsonb_build_object('situacao', 'ja_importada', 'nfe_id', v_ja.id,
                                'outro_arquivo', true);
    end if;
    return jsonb_build_object('situacao', 'conflito', 'nfe_id', v_ja.id);
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
            (it->>'v_outro')::numeric, it->>'ind_tot', it->>'cst_icms');
  end loop;

  perform gerar_movimento_emitente(v_id);
  select * into v_dest from gerar_movimento_destino(v_id, true);

  select count(*) into v_movs from movimento where nfe_id = v_id;
  return jsonb_build_object('situacao','importada','nfe_id',v_id,
                            'movimentos',v_movs,
                            'pendencias',coalesce(v_dest.pendencias, 0),
                            'automaticos',coalesce(v_dest.automaticos, 0));
end $$;


-- ==================================== reprocessar as duas pontas do que ja entrou
create or replace function reprocessar_notas()
returns table (notas int, movimentos_emitente int, movimentos_destino int,
               pendencias_fechadas int)
language plpgsql as $$
declare r record; k int; x record;
begin
  notas := 0; movimentos_emitente := 0; movimentos_destino := 0;
  for r in select id from nfe where situacao = 'autorizada' order by dt_emi, id loop
    k := gerar_movimento_emitente(r.id);
    select * into x from gerar_movimento_destino(r.id, false);
    if k + x.movimentos > 0 then notas := notas + 1; end if;
    movimentos_emitente := movimentos_emitente + k;
    movimentos_destino  := movimentos_destino + x.movimentos;
  end loop;
  select d.pendencias_fechadas into pendencias_fechadas from reprocessar_destino() d;
  return next;
end $$;
comment on function reprocessar_notas() is
  'Gera o que falta dos dois lados de todas as notas do trabalho ativo. Rodar '
  'depois de classificar um CFOP ou confirmar um de-para. Idempotente.';
