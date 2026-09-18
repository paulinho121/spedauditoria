-- 047 — Nota complementar e de ajuste nunca movimentam estoque; 5949/6949
-- tambem nao.
--
-- Nota complementar (finNFe 2) so completa valor ou imposto de uma nota
-- anterior: a mercadoria ja saiu na original. A de ajuste (finNFe 3) corrige
-- escrituracao. Nenhuma das duas move mercadoria.
--
-- O sistema decidia pelo CFOP e pela quantidade, e duas complementares de SC em
-- julho/2026 vieram com CFOP de venda e quantidade preenchida — o estoque foi
-- baixado de novo:
--
--   NF 562706  6102  -1 un
--   NF 562730  6108  -6 un
--
-- A regra passa a ser pela FINALIDADE da nota, antes do CFOP, e fica na guarda
-- de movimento (036) — vale para qualquer importador. Os movimentos que essas
-- notas geraram sao apagados: sao derivados, e a nota continua guardada.
--
-- A complementar de valor continua contando no FATURAMENTO: e preco cobrado.
-- So o estoque a ignora.
--
-- 5949 e 6949 ("outras saidas nao especificadas") ja estavam fora de escopo e
-- nao geravam movimento. Por decisao do auditor em 18/09/2026, deixam de ser
-- "caso a caso": nao movimentam estoque.

update cfop_efeito
   set efeito = 'fora_escopo', move_fisico = false,
       observacao = 'Nao movimenta estoque — decisao do auditor em 18/09/2026'
 where cfop in ('5949', '6949');

-- ============================================ guarda: finalidade antes do CFOP
create or replace function tg_movimento_so_de_nota_valida()
returns trigger language plpgsql as $$
begin
  if new.nfe_id is not null
     and exists (select 1 from nfe_todos n
                  where n.id = new.nfe_id
                    and (n.situacao <> 'autorizada'
                         -- complementar e ajuste nao movem mercadoria
                         or coalesce(n.fin_nfe, '1') in ('2', '3'))) then
    return null;
  end if;
  return new;
end $$;

delete from movimento m
 using nfe n
 where n.id = m.nfe_id and n.fin_nfe in ('2', '3');


-- ======================= bloqueios: complementar nao e linha parada, e esperado
create or replace function periodo_bloqueios(p_ini date, p_fim date)
returns table (motivo text, linhas bigint, notas bigint, quantidade numeric,
               valor numeric, onde_tratar text)
language sql stable as $$
  with lado as (
    select v.id as nfe_id, v.situacao, v.fin_nfe, i.id as item_id, i.cfop, i.q_com, i.v_prod,
           e.cnpj,
           case when e.cnpj = v.emit_cnpj then 'emitente' else 'destino' end as lado,
           v.emit_cnpj in (select cnpj from estabelecimento) as interna
      from nfe v
      join nfe_item i on i.nfe_id = v.id
      join estabelecimento e on e.cnpj in (v.emit_cnpj, v.dest_doc)
     where v.dt_emi between p_ini and p_fim
  ), parado as (
    select l.*, c.efeito from lado l left join cfop_efeito c on c.cfop = l.cfop
     where not exists (select 1 from movimento m
                        where m.nfe_item_id = l.item_id and m.cnpj = l.cnpj)
  ), classificado as (
    select *,
           case
             when situacao <> 'autorizada' then 'nota_nao_autorizada'
             when coalesce(fin_nfe, '1') in ('2', '3') then 'sem_efeito_no_estoque'
             when coalesce(q_com, 0) <= 0 then 'sem_efeito_no_estoque'
             when efeito is null then 'cfop_sem_classificacao'
             when lado = 'emitente' and efeito in ('simbolico', 'fora_escopo')
                  then 'sem_efeito_no_estoque'
             when lado = 'destino' and efeito_no_destino(efeito, interna) is null
                  then 'sem_efeito_no_estoque'
             when lado = 'destino' then 'item_sem_depara'
             else 'outro'
           end as motivo
      from parado
  )
  select motivo, count(*)::bigint, count(distinct nfe_id)::bigint,
         coalesce(sum(q_com), 0), coalesce(sum(v_prod), 0),
         case motivo
           when 'cfop_sem_classificacao' then 'classificar o CFOP'
           when 'item_sem_depara'        then 'ligar o código do fornecedor a um item seu'
           when 'nota_nao_autorizada'    then 'nada a fazer: a nota não existe para o estoque'
           else 'verificar'
         end
    from classificado
   where motivo <> 'sem_efeito_no_estoque'
   group by motivo order by 5 desc nulls last;
$$;
