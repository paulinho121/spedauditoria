-- 033 — Por que uma linha de nota do período não virou movimento.
--
-- A tela do mes avisava "quase nao ha entradas" comparando entrada com saida.
-- O aviso acertava o sintoma e nao dizia a causa, e a causa e o que o auditor
-- precisa para agir: o sistema recusa gerar movimento em tres situacoes, de
-- proposito, e cada uma se resolve num lugar diferente.
--
--   nota nao autorizada .... cancelada ou denegada: nao existe para o estoque
--   fora do grupo .......... nenhum CNPJ auditado e parte da nota
--   CFOP sem classificacao . nao se sabe o efeito no estoque — tela Importar
--   item sem de-para ....... o cProd do fornecedor nao foi ligado a um item
--                            seu. So acontece em ENTRADA: em nota que nos
--                            emitimos o cProd ja e o nosso codigo.
--
-- Sem isto, um mes so de saidas parece erro do sistema. Com isto, aparece o
-- que e: N linhas paradas, aqui, por este motivo.

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
  with item as (
    select v.id as nfe_id, i.id as item_id, i.q_com, i.v_prod,
           case
             when v.situacao <> 'autorizada' then 'nota_nao_autorizada'
             when not exists (select 1 from estabelecimento e
                               where e.cnpj = v.emit_cnpj or e.cnpj = v.dest_doc)
                  then 'fora_do_grupo'
             when not exists (select 1 from cfop_efeito c where c.cfop = i.cfop)
                  then 'cfop_sem_classificacao'
             else 'item_sem_depara'
           end as motivo
      from nfe v
      join nfe_item i on i.nfe_id = v.id
     where v.dt_emi between p_ini and p_fim
       and not exists (select 1 from movimento m where m.nfe_item_id = i.id)
  )
  select motivo,
         count(*)::bigint,
         count(distinct nfe_id)::bigint,
         coalesce(sum(q_com), 0),
         coalesce(sum(v_prod), 0),
         case motivo
           when 'cfop_sem_classificacao' then 'Importar · CFOP não classificado'
           when 'item_sem_depara'        then 'Importar · Itens sem correspondência'
           when 'nota_nao_autorizada'    then 'nada a fazer: a nota não existe para o estoque'
           else 'nenhum estabelecimento auditado é parte desta nota'
         end
    from item
   group by motivo
   order by 5 desc nulls last;
$$;

comment on function periodo_bloqueios(date, date) is
  'Linhas de nota do periodo que NAO viraram movimento, por motivo. Diz onde '
  'cada uma se resolve.';
