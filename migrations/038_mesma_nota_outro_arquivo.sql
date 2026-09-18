-- 038 — Mesma nota em outro arquivo nao e conflito.
--
-- A importacao reconhecia nota repetida pelo hash do ARQUIVO. A mesma NF-e
-- chega em arquivos diferentes: um sistema exporta no envelope de distribuicao
-- (nfeProc), outro so o NFe com o protocolo, um terceiro com outra quebra de
-- linha. Numa pasta de 249 notas, 16 ja importadas por outro caminho voltaram
-- como "conflito — mesma chave com conteudo diferente". Nenhum campo fiscal
-- diferia: cabecalho e itens identicos.
--
-- Para um auditor, "mesma chave, conteudo diferente" soa como nota adulterada.
-- Alarme falso nesse ponto ensina a ignorar o alarme — e ai o verdadeiro passa.
--
-- Agora, quando o hash difere, a nota e comparada campo a campo com a que ja
-- esta gravada: emitente, destinatario, numero, data, valor e, item por item,
-- codigo, CFOP, quantidade e valor. Igual e 'ja_importada' (de outro arquivo).
-- So o que difere de fato e 'conflito'.
--
-- Tambem: linha com quantidade zero (nota complementar de preco ou imposto)
-- aparecia no painel de bloqueios como "outro". Nao ha o que fazer com ela.

create or replace function nfe_mesmo_conteudo(p_id bigint, p jsonb)
returns boolean language sql stable as $$
  select
    n.num_nf = p->>'num_nf'
    and n.emit_cnpj = p->>'emit_cnpj'
    and coalesce(n.dest_doc, '') = coalesce(p->>'dest_doc', '')
    and n.dt_emi = (p->>'dt_emi')::date
    and n.vl_nf = (p->>'vl_nf')::numeric
    and (select count(*) from nfe_item i where i.nfe_id = n.id)
        = jsonb_array_length(coalesce(p->'itens', '[]'))
    and not exists (
      select 1 from jsonb_array_elements(coalesce(p->'itens', '[]')) it
       where not exists (
         select 1 from nfe_item i
          where i.nfe_id = n.id
            and i.n_item = (it->>'n_item')::int
            and i.c_prod = it->>'c_prod'
            and i.cfop   = it->>'cfop'
            and i.q_com  = (it->>'q_com')::numeric
            and i.v_prod = (it->>'v_prod')::numeric))
  from nfe n where n.id = p_id;
$$;
comment on function nfe_mesmo_conteudo(bigint, jsonb) is
  'A nota gravada e a do arquivo sao a mesma, campo a campo? Independe do '
  'envelope, da formatacao e do hash do arquivo.';


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
  v_item   bigint;
  v_ef     record;
  v_qtd    numeric;
  v_vu     numeric;
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


-- Quantidade zero nao e bloqueio: nao ha estoque a mover.
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
             when coalesce(q_com, 0) <= 0 then 'sem_efeito_no_estoque'
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
           else 'verificar'
         end
    from classificado
   where motivo <> 'sem_efeito_no_estoque'
   group by motivo
   order by 5 desc nulls last;
$$;
