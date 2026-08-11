-- 007 — O valor do movimento manda, nao a recomputacao.
--
-- estoque_em recalculava o valor como qtd * vl_unit. No inventario declarado
-- ha 33 itens em que QTD x VL_UNIT difere do VL_ITEM por arredondamento do
-- custo unitario na origem. Recomputar devolvia R$ 4.854.519,22 contra os
-- R$ 4.854.519,21 congelados no momento zero.
--
-- Saldo de abertura e imutavel: tem que sair exatamente como entrou. Agora usa
-- vl_total, que e o valor declarado, e so cai para qtd * vl_unit se faltar.

create or replace function estoque_em(p_data date)
returns table (
  cnpj text, cod_item text, qtd numeric, qtd_proprio numeric,
  qtd_terceiros numeric, custo_medio numeric, valor numeric,
  ultima_mov date, movimentos bigint
)
language plpgsql stable as $$
declare
  m record;
  k_cnpj text := null; k_item text := null;
  s_qtd numeric := 0; s_val numeric := 0;
  s_p0 numeric := 0; s_p1 numeric := 0;
  n_mov bigint := 0; ult date; custo numeric; entrada numeric;
begin
  for m in
    select mv.cnpj, mv.cod_item, mv.ind_prop, mv.dt, mv.qtd, mv.vl_unit,
           mv.vl_total, mv.efeito
    from movimento mv where mv.dt <= p_data
    order by mv.cnpj, mv.cod_item, mv.dt, mv.id
  loop
    if k_cnpj is distinct from m.cnpj or k_item is distinct from m.cod_item then
      if k_cnpj is not null and (s_qtd <> 0 or s_val <> 0) then
        cnpj := k_cnpj; cod_item := k_item;
        qtd := s_qtd; qtd_proprio := s_p0; qtd_terceiros := s_p1; valor := s_val;
        custo_medio := case when s_qtd > 0 then s_val / s_qtd else 0 end;
        ultima_mov := ult; movimentos := n_mov;
        return next;
      end if;
      k_cnpj := m.cnpj; k_item := m.cod_item;
      s_qtd := 0; s_val := 0; s_p0 := 0; s_p1 := 0; n_mov := 0;
    end if;

    n_mov := n_mov + 1;
    ult := m.dt;

    if m.ind_prop = '1' then s_p1 := s_p1 + m.qtd; else s_p0 := s_p0 + m.qtd; end if;

    if m.efeito = 'soma' then
      entrada := coalesce(m.vl_total, m.qtd * coalesce(m.vl_unit, 0));
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + abs(entrada) * sign(m.qtd);
    elsif m.efeito = 'baixa' then
      custo := case when s_qtd > 0 then s_val / s_qtd else 0 end;
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + m.qtd * custo;
    end if;
  end loop;

  if k_cnpj is not null and (s_qtd <> 0 or s_val <> 0) then
    cnpj := k_cnpj; cod_item := k_item;
    qtd := s_qtd; qtd_proprio := s_p0; qtd_terceiros := s_p1; valor := s_val;
    custo_medio := case when s_qtd > 0 then s_val / s_qtd else 0 end;
    ultima_mov := ult; movimentos := n_mov;
    return next;
  end if;
end $$;
