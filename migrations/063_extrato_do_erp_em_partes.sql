-- 063 — extrato do ERP grande entra em partes
--
-- O extrato de um depósito por três anos tem vinte mil linhas e doze megabytes.
-- Não cabe numa chamada: a função serverless recusa corpo acima de 4,5 MB, e a
-- API de administração do banco também tem teto.
--
-- A importação em partes mantém a garantia que importava na chamada única —
-- extrato pela metade nunca aparece para ninguém:
--
--   · a primeira parte cria o arquivo como NÃO vigente e NÃO completo;
--   · as seguintes só acrescentam linhas;
--   · a última confere a contagem com o que o leitor disse que mandaria e só
--     então publica: marca completo, vira vigente e aposenta o extrato anterior
--     do mesmo depósito e período.
--
-- Se o envio morrer no meio, sobra um arquivo incompleto que nenhuma tela lê
-- (todas filtram por vigente) e que o próximo envio do mesmo arquivo apaga.

alter table erp_extrato_arquivo_todos
  add column if not exists completo boolean not null default true;
comment on column erp_extrato_arquivo_todos.completo is
  'Falso enquanto a importacao em partes nao terminou. So o completo vira vigente.';

create or replace view erp_extrato_arquivo as
  select * from erp_extrato_arquivo_todos where trabalho_id = trabalho_atual();


create or replace function importar_erp_extrato_parte(p jsonb)
returns jsonb language plpgsql as $$
declare
  a jsonb := p->'arquivo';
  v_parte  int := coalesce((a->>'parte')::int, 1);
  v_partes int := coalesce((a->>'partes')::int, 1);
  v_id bigint; v_completo boolean; v_dep text; v_cnpj text;
  v_ant int := 0; v_n int;
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

  update erp_extrato_arquivo set vigente = false
   where coalesce(deposito,'') = coalesce(v_dep,'')
     and dt_ini = (a->>'dt_ini')::date and dt_fin = (a->>'dt_fin')::date
     and vigente and id <> v_id;
  get diagnostics v_ant = row_count;

  update erp_extrato_arquivo set vigente = true, completo = true where id = v_id;

  return jsonb_build_object(
    'situacao', case when v_ant > 0 then 'substituiu' else 'importado' end,
    'arquivo_id', v_id, 'cnpj', v_cnpj, 'deposito', v_dep, 'linhas', v_n,
    'com_ncm', (select count(*) from erp_extrato_linha
                 where arquivo_id = v_id and ncm is not null));
end $$;
comment on function importar_erp_extrato_parte(jsonb) is
  'Importa o extrato do ERP em partes. O arquivo so vira vigente na ultima, '
  'depois de conferida a contagem de linhas.';
