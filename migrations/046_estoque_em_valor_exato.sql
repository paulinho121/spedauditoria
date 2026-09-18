-- 046 — estoque_em volta a usar o valor exato da linha.
--
-- A 045 recriou estoque_em para deixar de fora o bem de terceiro (ind_prop 2),
-- mas partiu da definicao da 006. A 007 ja a tinha trocado: o valor de entrada
-- passou a ser o vl_total declarado, e nao qtd x vl_unit, que errava por um
-- centavo. A 045 reintroduziu a versao antiga, e 106 itens da posicao
-- acumulada mudaram de valor em centavos — nenhuma quantidade mudou.
--
-- Esta e a definicao da 007, com o filtro da 045. A foto do estoque proprio
-- tirada antes da 045 tem de voltar a bater item a item.

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
      and coalesce(mv.ind_prop, '0') <> '2'   -- bem de terceiro nao e estoque proprio
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
