-- 019 — Exposicao soma so o que e distorcao de valor.
--
-- v_achado_resumo somava o valor de todos os tipos. Isso contava duas vezes a
-- mesma coisa (a ressalva registrada E a divergencia de valoracao) e incluia a
-- mercadoria em poder de terceiros, que nao e distorcao: e valor a confirmar
-- junto ao depositario. O numero saia R$ 6,1 milhoes num estoque de R$ 4,8.
--
-- Exposicao = potencial distorcao do valor do estoque. Sao dois tipos:
--   valoracao      item inventariado por custo diferente do documentado
--   item_pendente  entrada que ainda nao chegou ao Kardex

create or replace function achado_e_exposicao(p_tipo text)
returns boolean language sql immutable as $$
  select p_tipo in ('valoracao', 'item_pendente');
$$;

comment on function achado_e_exposicao(text) is
  'Diz se o valor do achado representa potencial distorcao do estoque. '
  'Ressalva duplica a valoracao; terceiros e valor a confirmar, nao distorcao.';

-- Coluna nova no meio da lista: create or replace nao renomeia coluna de view.
drop view if exists v_achado_resumo;

create view v_achado_resumo as
select
  count(*) filter (where status = 'aberto')      as aberto,
  count(*) filter (where status = 'em_analise')  as em_analise,
  count(*) filter (where status = 'respondido')  as respondido,
  count(*) filter (where status = 'aceito')      as aceito,
  count(*) filter (where status = 'refutado')    as refutado,
  count(*) filter (where status = 'resolvido')   as resolvido,
  count(*)                                       as total,
  count(*) filter (where status <> 'resolvido'
                     and severidade = 'critico') as criticos_abertos,
  coalesce(sum(valor) filter (
      where status not in ('resolvido','refutado')
        and achado_e_exposicao(tipo) and valor > 0), 0) as exposicao_aberta,
  coalesce(sum(valor) filter (
      where tipo = 'terceiros' and status not in ('resolvido','refutado')), 0)
                                                 as valor_em_terceiros,
  count(*) filter (where prazo is not null and prazo < current_date
                     and status in ('aberto','em_analise'))  as atrasados
from achado;
