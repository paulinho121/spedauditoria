-- 068 — o navegador também manda o extrato em partes
--
-- A 063 fatiava o extrato do lado do servidor, que tinha o arquivo inteiro e
-- sabia o período, a contagem de itens e os avisos antes de mandar a primeira
-- parte. Na versão web isso não existe: o arquivo de 12 MB nem chega ao
-- servidor (o limite do corpo é 4,5 MB). Quem fatia é o navegador, e cada
-- parte é lida sozinha.
--
-- Duas mudanças para isso funcionar:
--   · o cabeçalho do arquivo (período, itens, movimentos) é calculado na
--     última parte, a partir das linhas gravadas — nenhuma parte o conhece;
--   · os avisos de cada parte se acumulam, em vez de valer só os da primeira.
--
-- A garantia continua a mesma: só vira vigente o arquivo que chegou inteiro.

create or replace function importar_erp_extrato_parte(p jsonb)
returns jsonb language plpgsql as $$
declare
  a jsonb := p->'arquivo';
  v_parte  int := coalesce((a->>'parte')::int, 1);
  v_partes int := coalesce((a->>'partes')::int, 1);
  v_id bigint; v_completo boolean; v_dep text; v_cnpj text;
  v_ant int := 0; v_n int; v_ini date; v_fin date;
begin
  select id, completo into v_id, v_completo
    from erp_extrato_arquivo where sha256 = a->>'sha256';
  if v_id is not null and v_completo then
    return jsonb_build_object('situacao', 'ja_importado', 'arquivo_id', v_id);
  end if;

  v_dep := a->>'deposito';
  v_cnpj := erp_cnpj_do_deposito(v_dep);

  if v_parte = 1 then
    -- Envio anterior do mesmo arquivo que não terminou: recomeça do zero.
    if v_id is not null then
      delete from erp_extrato_arquivo where id = v_id;
    end if;
    insert into erp_extrato_arquivo (
      nome_arquivo, sha256, deposito, cnpj, uf, dt_ini, dt_fin, linhas, itens,
      movimentos, aberturas, problemas, importado_por, vigente, completo)
    values (
      a->>'nome_arquivo', a->>'sha256', v_dep, v_cnpj,
      (select uf from estabelecimento where cnpj = v_cnpj),
      (a->>'dt_ini')::date, (a->>'dt_fin')::date, (a->>'linhas')::int,
      (a->>'itens')::int, (a->>'movimentos')::int, (a->>'aberturas')::int,
      a->'problemas', a->>'importado_por', false, false)
    returning id into v_id;
  elsif v_id is null then
    raise exception 'parte % de % chegou sem a primeira', v_parte, v_partes;
  else
    -- Os avisos de cada parte se somam: quem lê o arquivo aos pedaços só
    -- conhece os problemas do pedaço que leu.
    update erp_extrato_arquivo
       set problemas = coalesce(problemas, '[]'::jsonb) || coalesce(a->'problemas', '[]'::jsonb)
     where id = v_id and jsonb_typeof(coalesce(a->'problemas', '[]'::jsonb)) = 'array';
  end if;

  insert into erp_extrato_linha (
    arquivo_id, seq, abertura, cod_item, descr_item, unid, ncm, deposito, cnpj, dt, hora,
    ch_mov, ch_doc, doc_modelo, doc_serie, doc_num, doc_texto, tipo, entidade,
    qtd_entrada, qtd_saida, qtd_saldo, custo_entrada, custo_saida, custo_saldo, custo_medio)
  select v_id, (x->>'seq')::int, coalesce((x->>'abertura')::boolean, false),
         x->>'cod_item', nullif(x->>'descr_item',''), nullif(x->>'unid',''),
         nullif(x->>'ncm',''),
         coalesce(nullif(x->>'deposito',''), v_dep),
         -- Quase sempre o depósito da linha é o do arquivo; só consulta de
         -- novo quando não é, para não repetir a busca vinte mil vezes.
         case when coalesce(nullif(x->>'deposito',''), v_dep) is not distinct from v_dep
              then v_cnpj
              else erp_cnpj_do_deposito(x->>'deposito') end,
         (x->>'dt')::date, x->>'hora', x->>'ch_mov', x->>'ch_doc',
         x->>'doc_modelo', x->>'doc_serie', x->>'doc_num', x->>'doc_texto',
         x->>'tipo', x->>'entidade',
         (x->>'qtd_entrada')::numeric, (x->>'qtd_saida')::numeric, (x->>'qtd_saldo')::numeric,
         (x->>'custo_entrada')::numeric, (x->>'custo_saida')::numeric,
         (x->>'custo_saldo')::numeric, (x->>'custo_medio')::numeric
    from jsonb_array_elements(coalesce(p->'linhas','[]')) x;

  select count(*) into v_n from erp_extrato_linha where arquivo_id = v_id;

  if v_parte < v_partes then
    return jsonb_build_object('situacao', 'parte', 'arquivo_id', v_id,
                              'parte', v_parte, 'partes', v_partes, 'linhas', v_n);
  end if;

  -- Última parte: só publica se chegou tudo.
  if v_n <> (a->>'linhas')::int then
    raise exception 'extrato incompleto: chegaram % de % linhas', v_n, a->>'linhas';
  end if;

  -- O cabeçalho sai das linhas gravadas, e não do que a parte disse: quando
  -- o navegador fatia o arquivo, nenhuma parte conhece o período inteiro.
  select date_trunc('month', min(l.dt))::date,
         (date_trunc('month', max(l.dt)) + interval '1 month - 1 day')::date
    into v_ini, v_fin
    from erp_extrato_linha l where l.arquivo_id = v_id;

  update erp_extrato_arquivo set vigente = false
   where coalesce(deposito,'') = coalesce(v_dep,'')
     and dt_ini = v_ini and dt_fin = v_fin
     and vigente and id <> v_id;
  get diagnostics v_ant = row_count;

  update erp_extrato_arquivo x
     set vigente = true, completo = true, dt_ini = v_ini, dt_fin = v_fin,
         linhas = v_n,
         itens = (select count(distinct l.cod_item) from erp_extrato_linha l
                   where l.arquivo_id = v_id),
         movimentos = (select count(*) from erp_extrato_linha l
                        where l.arquivo_id = v_id and not l.abertura),
         aberturas = (select count(*) from erp_extrato_linha l
                       where l.arquivo_id = v_id and l.abertura)
   where x.id = v_id;

  return jsonb_build_object(
    'situacao', case when v_ant > 0 then 'substituiu' else 'importado' end,
    'arquivo_id', v_id, 'cnpj', v_cnpj, 'deposito', v_dep, 'linhas', v_n,
    'com_ncm', (select count(*) from erp_extrato_linha
                 where arquivo_id = v_id and ncm is not null));
end $$;
comment on function importar_erp_extrato_parte(jsonb) is
  'Importa o extrato do ERP em partes. O arquivo so vira vigente na ultima, '
  'depois de conferida a contagem de linhas.';
