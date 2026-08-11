-- 006 — Posicao de estoque em qualquer data.
--
-- Percorre os movimentos em ordem cronologica e aplica CUSTO MEDIO PONDERADO
-- MOVEL. Nao da para simplesmente somar valores: numa venda o vl_unit e o
-- PRECO DE VENDA, nao o custo. Somar isso subtrairia do estoque um valor que
-- nunca entrou nele, e o saldo ficaria errado (normalmente negativo).
--
-- Regras por efeito:
--   soma            entra quantidade e custo; recalcula a media
--   baixa           sai quantidade; baixa pelo custo medio vigente
--   para_terceiros  so muda de maos: quantidade migra, custo nao se altera
--   de_terceiros    idem, no sentido inverso
--   simbolico       nao gera movimento (nem chega aqui)

create or replace function estoque_em(p_data date)
returns table (
  cnpj           text,
  cod_item       text,
  qtd            numeric,
  qtd_proprio    numeric,
  qtd_terceiros  numeric,
  custo_medio    numeric,
  valor          numeric,
  ultima_mov     date,
  movimentos     bigint
)
language plpgsql
stable
as $$
declare
  m            record;
  k_cnpj       text := null;
  k_item       text := null;
  s_qtd        numeric := 0;   -- quantidade total (proprio + terceiros)
  s_val        numeric := 0;   -- valor acumulado, base do custo medio
  s_p0         numeric := 0;   -- em seu poder
  s_p1         numeric := 0;   -- em poder de terceiros
  n_mov        bigint := 0;
  ult          date;
  custo        numeric;
begin
  for m in
    select mv.cnpj, mv.cod_item, mv.ind_prop, mv.dt, mv.qtd, mv.vl_unit, mv.efeito
    from movimento mv
    where mv.dt <= p_data
    order by mv.cnpj, mv.cod_item, mv.dt, mv.id
  loop
    if k_cnpj is distinct from m.cnpj or k_item is distinct from m.cod_item then
      if k_cnpj is not null and (s_qtd <> 0 or s_val <> 0) then
        cnpj := k_cnpj; cod_item := k_item;
        qtd := s_qtd; qtd_proprio := s_p0; qtd_terceiros := s_p1;
        valor := s_val;
        custo_medio := case when s_qtd > 0 then s_val / s_qtd else 0 end;
        ultima_mov := ult; movimentos := n_mov;
        return next;
      end if;
      k_cnpj := m.cnpj; k_item := m.cod_item;
      s_qtd := 0; s_val := 0; s_p0 := 0; s_p1 := 0; n_mov := 0;
    end if;

    n_mov := n_mov + 1;
    ult := m.dt;

    -- quantidade por posse: sempre acompanha o sinal do movimento
    if m.ind_prop = '1' then
      s_p1 := s_p1 + m.qtd;
    else
      s_p0 := s_p0 + m.qtd;
    end if;

    if m.efeito = 'soma' then
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + m.qtd * coalesce(m.vl_unit, 0);

    elsif m.efeito = 'baixa' then
      custo := case when s_qtd > 0 then s_val / s_qtd else 0 end;
      s_qtd := s_qtd + m.qtd;              -- m.qtd e negativo
      s_val := s_val + m.qtd * custo;      -- baixa pelo custo, nao pela venda

    -- para_terceiros e de_terceiros apenas trocam a posse: a quantidade total
    -- e o custo nao mudam, porque a mercadoria continua sendo da empresa.
    end if;
  end loop;

  if k_cnpj is not null and (s_qtd <> 0 or s_val <> 0) then
    cnpj := k_cnpj; cod_item := k_item;
    qtd := s_qtd; qtd_proprio := s_p0; qtd_terceiros := s_p1;
    valor := s_val;
    custo_medio := case when s_qtd > 0 then s_val / s_qtd else 0 end;
    ultima_mov := ult; movimentos := n_mov;
    return next;
  end if;
end $$;

comment on function estoque_em(date) is
  'Posicao do estoque em uma data, por custo medio ponderado movel. Baixa pelo '
  'custo vigente, nunca pelo valor da nota de saida.';


-- Versao com cadastro resolvido, para a tela.
create or replace function estoque_em_detalhe(p_data date)
returns table (
  uf             text,
  cnpj           text,
  cod_item       text,
  descr_item     text,
  ncm            text,
  unid           text,
  qtd            numeric,
  qtd_proprio    numeric,
  qtd_terceiros  numeric,
  custo_medio    numeric,
  valor          numeric,
  ultima_mov     date,
  movimentos     bigint,
  busca          text
)
language sql
stable
as $$
  select
    e.uf,
    s.cnpj,
    s.cod_item,
    coalesce(i.descr_item, sa.descr_item)          as descr_item,
    i.ncm,
    coalesce(sa.unid, i.unid_inv)                  as unid,
    s.qtd, s.qtd_proprio, s.qtd_terceiros,
    round(s.custo_medio, 6)                        as custo_medio,
    round(s.valor, 2)                              as valor,
    s.ultima_mov, s.movimentos,
    upper(coalesce(i.descr_item, sa.descr_item, '') || ' ' || s.cod_item || ' '
          || coalesce(i.ncm, ''))                  as busca
  from estoque_em(p_data) s
  left join estabelecimento e on e.cnpj = s.cnpj
  left join lateral (
    select si.descr_item, si.ncm, si.unid_inv
    from sped_item si
    join sped_arquivo a on a.id = si.arquivo_id and a.vigente
    where si.cnpj_estab = s.cnpj and si.cod_item = s.cod_item
    limit 1
  ) i on true
  left join lateral (
    select descr_item, unid from saldo_abertura
    where cnpj = s.cnpj and cod_item = s.cod_item limit 1
  ) sa on true;
$$;

comment on function estoque_em_detalhe(date) is
  'estoque_em com descricao, NCM e unidade resolvidos. Consumida pela tela.';


-- Totais da data, para os indicadores do topo.
create or replace function estoque_resumo(p_data date)
returns table (
  itens          bigint,
  unidades       numeric,
  valor          numeric,
  em_terceiros   numeric,
  negativos      bigint,
  filiais        bigint,
  ultima_mov     date
)
language sql
stable
as $$
  select count(*)::bigint,
         coalesce(sum(qtd), 0),
         coalesce(sum(valor), 0),
         coalesce(sum(qtd_terceiros), 0),
         count(*) filter (where qtd < 0)::bigint,
         count(distinct cnpj)::bigint,
         max(ultima_mov)
  from estoque_em(p_data)
  where qtd <> 0 or valor <> 0;
$$;

-- Datas em que houve movimento, para a tela sugerir onde ha o que ver.
create or replace view v_datas_movimento as
select dt, count(*) as movimentos, count(distinct cnpj) as filiais
from movimento group by dt order by dt;
