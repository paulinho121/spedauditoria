-- 056 — NCM nos produtos que vem do ERP.
--
-- O extrato de dezembro/2023 nao traz NCM. Duas saidas, e as duas sao
-- necessarias:
--
--   1. Se o relatorio PASSAR a trazer a coluna, o leitor ja a reconhece (a
--      leitura agora e pelo nome da coluna, nao pela posicao) e o NCM do ERP
--      fica guardado na linha.
--   2. Enquanto nao trouxer, o NCM e buscado PELO CODIGO no nosso cadastro:
--      primeiro o 0200 do EFD, que e o que a empresa declarou ao fisco;
--      depois o lido dos XML. A tela diz de onde veio — NCM de origem
--      desconhecida nao serve para auditar tributacao.
--
-- E quando as duas pontas existem e divergem, isso vira alerta: NCM errado
-- muda aliquota, muda ST, muda IPI. E o tipo de divergencia que so aparece
-- quando se compara o cadastro do ERP com o que foi declarado.

alter table erp_extrato_linha_todos add column if not exists ncm text;
comment on column erp_extrato_linha_todos.ncm is
  'NCM como veio no relatorio do ERP, quando o relatorio traz a coluna.';

create or replace view erp_extrato_linha as
  select * from erp_extrato_linha_todos where trabalho_id = trabalho_atual();


create or replace function importar_erp_extrato(p jsonb)
returns jsonb language plpgsql as $$
declare
  a jsonb := p->'arquivo';
  v_ja bigint; v_id bigint; v_ant int; v_cnpj text; v_dep text;
begin
  select id into v_ja from erp_extrato_arquivo where sha256 = a->>'sha256';
  if v_ja is not null then
    return jsonb_build_object('situacao', 'ja_importado', 'arquivo_id', v_ja);
  end if;

  v_dep := a->>'deposito';
  v_cnpj := erp_cnpj_do_deposito(v_dep);

  update erp_extrato_arquivo set vigente = false
   where coalesce(deposito,'') = coalesce(v_dep,'')
     and dt_ini = (a->>'dt_ini')::date and dt_fin = (a->>'dt_fin')::date and vigente;
  get diagnostics v_ant = row_count;

  insert into erp_extrato_arquivo (
    nome_arquivo, sha256, deposito, cnpj,
    uf, dt_ini, dt_fin, linhas, itens, movimentos, aberturas, problemas, importado_por)
  values (
    a->>'nome_arquivo', a->>'sha256', v_dep, v_cnpj,
    (select uf from estabelecimento where cnpj = v_cnpj),
    (a->>'dt_ini')::date, (a->>'dt_fin')::date, (a->>'linhas')::int,
    (a->>'itens')::int, (a->>'movimentos')::int, (a->>'aberturas')::int,
    a->'problemas', a->>'importado_por')
  returning id into v_id;

  insert into erp_extrato_linha (
    arquivo_id, seq, abertura, cod_item, descr_item, unid, ncm, deposito, cnpj, dt, hora,
    ch_mov, ch_doc, doc_modelo, doc_serie, doc_num, doc_texto, tipo, entidade,
    qtd_entrada, qtd_saida, qtd_saldo, custo_entrada, custo_saida, custo_saldo, custo_medio)
  select v_id, (x->>'seq')::int, (x->>'abertura')::boolean,
         x->>'cod_item', nullif(x->>'descr_item',''), nullif(x->>'unid',''),
         nullif(x->>'ncm',''),
         coalesce(nullif(x->>'deposito',''), v_dep),
         erp_cnpj_do_deposito(coalesce(nullif(x->>'deposito',''), v_dep)),
         (x->>'dt')::date, x->>'hora', x->>'ch_mov', x->>'ch_doc',
         x->>'doc_modelo', x->>'doc_serie', x->>'doc_num', x->>'doc_texto',
         x->>'tipo', x->>'entidade',
         (x->>'qtd_entrada')::numeric, (x->>'qtd_saida')::numeric, (x->>'qtd_saldo')::numeric,
         (x->>'custo_entrada')::numeric, (x->>'custo_saida')::numeric,
         (x->>'custo_saldo')::numeric, (x->>'custo_medio')::numeric
    from jsonb_array_elements(coalesce(p->'linhas','[]')) x;

  return jsonb_build_object(
    'situacao', case when v_ant > 0 then 'substituiu' else 'importado' end,
    'arquivo_id', v_id, 'cnpj', v_cnpj, 'deposito', v_dep,
    'linhas', (select count(*) from erp_extrato_linha where arquivo_id = v_id),
    'com_ncm', (select count(*) from erp_extrato_linha
                 where arquivo_id = v_id and ncm is not null));
end $$;


-- O NCM de um codigo, e de onde ele veio. A ordem e a da confiabilidade: o
-- 0200 e o que a empresa declarou ao fisco; o XML e o que ela imprimiu na
-- nota; o extrato e o cadastro do ERP, que ninguem conferiu.
create or replace function erp_ncm_do_item(p_cnpj text, p_cod_item text, p_do_erp text default null)
returns table (ncm text, origem text)
language sql stable as $$
  select coalesce(s.ncm, k.ncm, p_do_erp),
         case when s.ncm is not null then 'EFD 0200'
              when k.ncm is not null then 'XML'
              when p_do_erp is not null then 'ERP'
         end
    from (select 1) _
    left join sped_item s on s.cnpj_estab = p_cnpj and s.cod_item = p_cod_item
    left join item_cadastro_nfe k on k.cnpj = p_cnpj and k.cod_item = p_cod_item
   limit 1;
$$;


drop function if exists erp_confronto_item(bigint);
create or replace function erp_confronto_item(p_arquivo_id bigint)
returns table (
  cod_item text, descr_item text, unid text, cnpj text,
  ncm text, ncm_origem text, ncm_erp text,
  erp_inicial numeric, erp_entradas numeric, erp_saidas numeric,
  erp_final numeric, erp_custo_medio numeric, erp_valor numeric,
  nosso_inicial numeric, nossas_entradas numeric, nossas_saidas numeric,
  nosso_final numeric, nosso_custo_medio numeric, nosso_valor numeric,
  dif_inicial numeric, dif_final numeric, dif_valor numeric, situacao text
)
language plpgsql stable as $$
declare a record;
begin
  select * into a from erp_extrato_arquivo where id = p_arquivo_id;
  if a.id is null then return; end if;

  return query
  with erp as (
    select l.cod_item,
           max(l.descr_item) filter (where l.descr_item is not null) descr_item,
           max(l.unid) unid, max(l.cnpj) cnpj,
           max(l.ncm) filter (where l.ncm is not null) ncm,
           coalesce(sum(l.qtd_saldo) filter (where l.abertura), 0) inicial,
           coalesce(sum(l.qtd_entrada) filter (where not l.abertura), 0) entradas,
           coalesce(sum(l.qtd_saida) filter (where not l.abertura), 0) saidas,
           (array_agg(l.qtd_saldo order by l.seq desc))[1] final,
           (array_agg(l.custo_medio order by l.seq desc))[1] custo_medio,
           (array_agg(l.custo_saldo order by l.seq desc))[1] valor
      from erp_extrato_linha l
     where l.arquivo_id = p_arquivo_id
     group by l.cod_item
  ), ini as (
    select e.cod_item, e.qtd from estoque_em(a.dt_ini - 1) e where e.cnpj = a.cnpj
  ), fim as (
    select e.cod_item, e.qtd, e.custo_medio, e.valor
      from estoque_em(a.dt_fin) e where e.cnpj = a.cnpj
  ), per as (
    select m.cod_item,
           coalesce(sum(m.qtd) filter (where m.qtd > 0), 0) entradas,
           coalesce(-sum(m.qtd) filter (where m.qtd < 0), 0) saidas
      from movimento m
     where m.cnpj = a.cnpj and m.dt between a.dt_ini and a.dt_fin
       and coalesce(m.ind_prop,'0') = '0'
     group by m.cod_item
  )
  select coalesce(e.cod_item, f.cod_item, p.cod_item),
         e.descr_item, e.unid, a.cnpj,
         nc.ncm, nc.origem, e.ncm,
         coalesce(e.inicial, 0), coalesce(e.entradas, 0), coalesce(e.saidas, 0),
         coalesce(e.final, 0), e.custo_medio, round(coalesce(e.valor, 0), 2),
         coalesce(i.qtd, 0), coalesce(p.entradas, 0), coalesce(p.saidas, 0),
         coalesce(f.qtd, 0), f.custo_medio, round(coalesce(f.valor, 0), 2),
         coalesce(e.inicial, 0) - coalesce(i.qtd, 0),
         coalesce(e.final, 0) - coalesce(f.qtd, 0),
         round(coalesce(e.valor, 0) - coalesce(f.valor, 0), 2),
         case
           when e.cod_item is null and coalesce(p.entradas,0) + coalesce(p.saidas,0) > 0
                then 'so_nosso'
           when e.cod_item is null then 'sem_movimento'
           when coalesce(f.qtd,0) = 0 and coalesce(p.entradas,0) + coalesce(p.saidas,0) = 0
                and coalesce(i.qtd,0) = 0 then 'so_erp'
           when abs(coalesce(e.final,0) - coalesce(f.qtd,0)) > 0.001 then 'saldo_difere'
           when abs(coalesce(e.inicial,0) - coalesce(i.qtd,0)) > 0.001 then 'abertura_difere'
           when abs(coalesce(e.valor,0) - coalesce(f.valor,0)) > 0.01 then 'valor_difere'
           else 'confere'
         end
    from erp e
    full join fim f on f.cod_item = e.cod_item
    full join per p on p.cod_item = coalesce(e.cod_item, f.cod_item)
    left join ini i on i.cod_item = coalesce(e.cod_item, f.cod_item, p.cod_item)
    left join lateral erp_ncm_do_item(
      a.cnpj, coalesce(e.cod_item, f.cod_item, p.cod_item), e.ncm) nc on true
   order by abs(coalesce(e.final,0) - coalesce(f.qtd,0)) desc,
            abs(coalesce(e.valor,0) - coalesce(f.valor,0)) desc;
end $$;


drop function if exists erp_confronto_resumo(bigint);
create or replace function erp_confronto_resumo(p_arquivo_id bigint)
returns table (
  cnpj text, uf text, deposito text, dt_ini date, dt_fin date,
  itens bigint, confere bigint, saldo_difere bigint, abertura_difere bigint,
  valor_difere bigint, so_erp bigint, so_nosso bigint, sem_movimento bigint,
  erp_valor_final numeric, nosso_valor_final numeric, dif_valor numeric,
  docs_so_erp bigint, docs_so_nosso bigint, docs_qtd_difere bigint,
  linhas_sem_documento bigint,
  nossas_notas bigint, nossos_movimentos bigint,
  itens_com_ncm bigint, itens_sem_ncm bigint, ncm_do_erp bigint
)
language sql stable as $$
  select a.cnpj, a.uf, a.deposito, a.dt_ini, a.dt_fin,
         count(i.*)::bigint,
         count(*) filter (where i.situacao = 'confere')::bigint,
         count(*) filter (where i.situacao = 'saldo_difere')::bigint,
         count(*) filter (where i.situacao = 'abertura_difere')::bigint,
         count(*) filter (where i.situacao = 'valor_difere')::bigint,
         count(*) filter (where i.situacao = 'so_erp')::bigint,
         count(*) filter (where i.situacao = 'so_nosso')::bigint,
         count(*) filter (where i.situacao = 'sem_movimento')::bigint,
         round(coalesce(sum(i.erp_valor), 0), 2),
         round(coalesce(sum(i.nosso_valor), 0), 2),
         round(coalesce(sum(i.erp_valor) - sum(i.nosso_valor), 0), 2),
         (select count(*) from erp_confronto_documento(p_arquivo_id) d where d.situacao = 'so_erp'),
         (select count(*) from erp_confronto_documento(p_arquivo_id) d where d.situacao = 'so_nosso'),
         (select count(*) from erp_confronto_documento(p_arquivo_id) d where d.situacao = 'qtd_difere'),
         (select count(*) from erp_extrato_linha l
           where l.arquivo_id = p_arquivo_id and not l.abertura
             and coalesce(l.doc_num, '') = ''),
         (select count(distinct m.nfe_id) from movimento m
           where m.cnpj = a.cnpj and m.dt between a.dt_ini and a.dt_fin
             and m.nfe_id is not null),
         (select count(*) from movimento m
           where m.cnpj = a.cnpj and m.dt between a.dt_ini and a.dt_fin),
         -- Sem NCM nao se audita tributacao: o numero tem de estar na tela.
         count(*) filter (where i.ncm is not null
                            and i.situacao <> 'sem_movimento')::bigint,
         count(*) filter (where i.ncm is null
                            and i.situacao <> 'sem_movimento')::bigint,
         count(*) filter (where i.ncm_erp is not null)::bigint
    from erp_extrato_arquivo a
    left join erp_confronto_item(p_arquivo_id) i on true
   where a.id = p_arquivo_id
   group by a.cnpj, a.uf, a.deposito, a.dt_ini, a.dt_fin;
$$;


-- NCM do ERP diferente do declarado: muda aliquota, ST e IPI.
create or replace function erp_ncm_divergente(p_arquivo_id bigint)
returns table (cod_item text, descr_item text, ncm_erp text, ncm_nosso text,
               origem_nosso text, linhas bigint, valor numeric)
language sql stable as $$
  select l.cod_item,
         max(l.descr_item),
         l.ncm,
         nc.ncm,
         nc.origem,
         count(*)::bigint,
         round(coalesce(sum(coalesce(l.custo_entrada, 0)
                            + coalesce(l.custo_saida, 0)), 0), 2)
    from erp_extrato_linha l
    join lateral (select * from erp_ncm_do_item(l.cnpj, l.cod_item, null)) nc on true
   where l.arquivo_id = p_arquivo_id
     and l.ncm is not null and nc.ncm is not null and l.ncm <> nc.ncm
   group by l.cod_item, l.ncm, nc.ncm, nc.origem
   order by 7 desc;
$$;
comment on function erp_ncm_divergente(bigint) is
  'Item cujo NCM no ERP difere do declarado no EFD 0200 ou impresso no XML.';
