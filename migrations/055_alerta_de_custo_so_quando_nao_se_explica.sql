-- 055 — O alerta de custo medio so dispara quando o salto nao se explica.
--
-- A primeira versao acusava 17 linhas no extrato de dezembro/2023. Seis eram
-- ruido da propria aritmetica: quando o item zera o saldo, o ERP imprime custo
-- medio 0,00 — e "de 10.386,77 para 0,00" nao e defeito nenhum. Uma setima era
-- entrada legitima a preco maior, que move a media ponderada como tem de mover.
--
-- Alerta que acusa o certo ensina o auditor a ignorar a tela. Agora o salto so
-- aparece quando o custo unitario do proprio movimento esta fora de escala —
-- menos de um decimo ou mais de dez vezes a media anterior. E o caso de 2.015
-- unidades lancadas a R$ 1,00, que derrubou a media de R$ 760,77 para R$ 4,88
-- e, dois dias depois, jogou para R$ 898,21. Esse custo vai para o CMV.
--
-- E a linha ja acusada por quantidade fora de escala nao repete como
-- quantidade fracionada: um problema, um alerta.

create or replace function erp_extrato_alertas(p_arquivo_id bigint)
returns table (
  tipo text, titulo text, cod_item text, descr_item text, dt date,
  doc text, detalhe text, quantidade numeric, valor numeric
)
language sql stable as $$
  with linha as (
    select l.*,
           -- Custo unitario do proprio movimento: e ele que explica, ou nao,
           -- a mudanca da media.
           case when coalesce(l.qtd_entrada, 0) > 0 then l.custo_entrada / l.qtd_entrada
                when coalesce(l.qtd_saida, 0) > 0 then l.custo_saida / l.qtd_saida
           end unitario,
           ant.custo_medio custo_medio_ant, ant.qtd_saldo saldo_ant
      from erp_extrato_linha l
      left join lateral (
        select p.custo_medio, p.qtd_saldo from erp_extrato_linha p
         where p.arquivo_id = l.arquivo_id and p.cod_item = l.cod_item and p.seq < l.seq
         order by p.seq desc limit 1) ant on true
     where l.arquivo_id = p_arquivo_id
  ), fora_de_escala as (
    select l.* from linha l
     where not l.abertura
       and greatest(coalesce(l.qtd_entrada, 0), coalesce(l.qtd_saida, 0))
           > greatest(abs(coalesce(l.saldo_ant, 0)), 1) * 100
  )
  select 'sem_documento', 'Movimento sem documento fiscal',
         l.cod_item, l.descr_item, l.dt, coalesce(l.ch_mov, '—'),
         coalesce(l.tipo, '') || coalesce(' · ' || l.entidade, ''),
         coalesce(l.qtd_entrada, 0) - coalesce(l.qtd_saida, 0),
         round(coalesce(l.custo_entrada, 0) - coalesce(l.custo_saida, 0), 2)
    from linha l
   where not l.abertura and coalesce(l.doc_num, '') = ''

  union all
  select 'custo_pula', 'Custo médio saltou sem que o movimento explique',
         l.cod_item, l.descr_item, l.dt, coalesce(l.doc_texto, l.ch_mov, '—'),
         'de ' || to_char(l.custo_medio_ant, 'FM999G999G990D00') ||
         ' para ' || to_char(l.custo_medio, 'FM999G999G990D00') ||
         coalesce(' · custo unitário do movimento ' ||
                  to_char(l.unitario, 'FM999G999G990D0000'), ''),
         coalesce(l.qtd_entrada, 0) - coalesce(l.qtd_saida, 0),
         round(l.custo_medio - l.custo_medio_ant, 2)
    from linha l
   where l.custo_medio_ant > 0 and l.custo_medio is not null
     -- Item zerando o saldo imprime media zero: aritmetica, nao defeito.
     and coalesce(l.qtd_saldo, 0) <> 0
     and abs(l.custo_medio - l.custo_medio_ant) > 0.5 * l.custo_medio_ant
     and (l.unitario is null
          or l.unitario < l.custo_medio_ant / 10
          or l.unitario > l.custo_medio_ant * 10)

  union all
  select 'quantidade_fora_de_escala', 'Quantidade desproporcional ao item',
         l.cod_item, l.descr_item, l.dt, coalesce(l.doc_texto, l.ch_mov, '—'),
         'saldo antes: ' || to_char(coalesce(l.saldo_ant, 0), 'FM999G999G990D000')
           || coalesce(' · ' || l.tipo, ''),
         coalesce(l.qtd_entrada, 0) - coalesce(l.qtd_saida, 0),
         round(coalesce(l.custo_entrada, 0) - coalesce(l.custo_saida, 0), 2)
    from fora_de_escala l

  union all
  select 'quantidade_fracionada', 'Quantidade fracionada em item contado por unidade',
         l.cod_item, l.descr_item, l.dt, coalesce(l.doc_texto, l.ch_mov, '—'),
         coalesce(l.tipo, '') || ' · unidade ' || coalesce(l.unid, '?'),
         coalesce(l.qtd_entrada, 0) - coalesce(l.qtd_saida, 0),
         round(coalesce(l.custo_entrada, 0) - coalesce(l.custo_saida, 0), 2)
    from linha l
   where upper(coalesce(l.unid, '')) in ('UN', 'UND', 'UNID', 'PC', 'PÇ', 'PEC')
     and (coalesce(l.qtd_entrada, 0) <> trunc(coalesce(l.qtd_entrada, 0))
          or coalesce(l.qtd_saida, 0) <> trunc(coalesce(l.qtd_saida, 0)))
     -- Um problema, um alerta: a linha ja acusada por escala nao repete aqui.
     and not exists (select 1 from fora_de_escala f where f.id = l.id)

  order by 5, 3;
$$;
comment on function erp_extrato_alertas(bigint) is
  'O que o proprio extrato denuncia sem precisar da nossa apuracao: movimento '
  'sem nota, custo medio que salta sem explicacao no movimento, quantidade '
  'fora de escala ou fracionada em item contado por unidade.';
