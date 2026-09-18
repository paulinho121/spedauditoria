-- 032 — Reconstrução de um período começando do zero.
--
-- A reconstrução normal parte do saldo de abertura e acumula tudo até a data.
-- Aqui a pergunta e outra: o que ESTE mes fez com o estoque? Todo item comeca
-- em zero, entram so as notas do periodo, e o que sobra no fim e o saldo.
--
-- Serve quando nao ha inventario confiavel para ancorar — ou quando ele existe
-- e justamente se quer conferi-lo contra o movimento, sem que o proprio
-- inventario entre na conta.
--
-- DUAS LEITURAS QUE MUDAM COM O ZERO INICIAL, e que a tela precisa dizer:
--
--   · saldo negativo aqui e ESPERADO, nao achado. Item vendido no mes e
--     comprado antes dele comeca em zero e fica negativo — isso e o que a
--     visao revela (quanto o mes consumiu de estoque anterior), nao um erro.
--     Por isso nada daqui alimenta o motor de achados;
--   · saida sem entrada no periodo nao tem custo em que se apoiar. O custo nao
--     e zero: e desconhecido. A coluna sem_custo marca esses itens, para que a
--     valoracao nao seja lida como se fosse completa.
--
-- O custeio e o mesmo do resto do sistema — media ponderada movel, saida
-- baixando pelo custo vigente. Trocar de metodo so nesta tela criaria dois
-- numeros diferentes para a mesma mercadoria.

create or replace function estoque_periodo(
  p_ini date, p_fim date, p_origem text default 'nfe')
returns table (
  cnpj            text,
  cod_item        text,
  qtd_entrada     numeric,
  vl_entrada      numeric,
  qtd_saida       numeric,
  vl_saida        numeric,   -- pelo valor da nota de saida (preco)
  vl_saida_custo  numeric,   -- pelo custo com que a mercadoria foi baixada
  saldo_qtd       numeric,
  saldo_proprio   numeric,
  saldo_terceiros numeric,
  custo_medio     numeric,
  valor           numeric,
  sem_custo       boolean,
  movimentos      bigint,
  primeira_mov    date,
  ultima_mov      date
)
language plpgsql stable as $$
declare
  m        record;
  k_cnpj   text := null;
  k_item   text := null;
  s_qtd    numeric := 0;   -- quantidade total (proprio + terceiros)
  s_val    numeric := 0;   -- valor acumulado, base do custo medio
  s_p0     numeric := 0;
  s_p1     numeric := 0;
  e_qtd    numeric := 0;   -- entradas brutas do periodo
  e_val    numeric := 0;
  x_qtd    numeric := 0;   -- saidas brutas do periodo
  x_val    numeric := 0;   -- pelo preco da nota
  x_cst    numeric := 0;   -- pelo custo
  n_mov    bigint  := 0;
  d_ini    date;
  d_fim    date;
  furou    boolean := false;
  custo    numeric;
begin
  for m in
    select mv.cnpj, mv.cod_item, mv.ind_prop, mv.dt, mv.qtd, mv.vl_unit, mv.efeito
    from movimento mv
    where mv.dt between p_ini and p_fim
      and (p_origem is null or p_origem = '' or mv.origem = p_origem)
    order by mv.cnpj, mv.cod_item, mv.dt, mv.id
  loop
    if k_cnpj is distinct from m.cnpj or k_item is distinct from m.cod_item then
      if k_cnpj is not null then
        cnpj := k_cnpj; cod_item := k_item;
        qtd_entrada := e_qtd; vl_entrada := round(e_val, 2);
        qtd_saida := x_qtd; vl_saida := round(x_val, 2);
        vl_saida_custo := round(x_cst, 2);
        saldo_qtd := s_qtd; saldo_proprio := s_p0; saldo_terceiros := s_p1;
        custo_medio := case when s_qtd > 0 then round(s_val / s_qtd, 6) else 0 end;
        valor := round(s_val, 2);
        sem_custo := furou; movimentos := n_mov;
        primeira_mov := d_ini; ultima_mov := d_fim;
        return next;
      end if;
      k_cnpj := m.cnpj; k_item := m.cod_item;
      s_qtd := 0; s_val := 0; s_p0 := 0; s_p1 := 0;
      e_qtd := 0; e_val := 0; x_qtd := 0; x_val := 0; x_cst := 0;
      n_mov := 0; furou := false; d_ini := m.dt;
    end if;

    n_mov := n_mov + 1;
    d_fim := m.dt;

    if m.ind_prop = '1' then
      s_p1 := s_p1 + m.qtd;
    else
      s_p0 := s_p0 + m.qtd;
    end if;

    if m.efeito = 'soma' then
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + m.qtd * coalesce(m.vl_unit, 0);
      e_qtd := e_qtd + m.qtd;
      e_val := e_val + m.qtd * coalesce(m.vl_unit, 0);

    elsif m.efeito = 'baixa' then
      -- Sem entrada no periodo nao ha custo: a baixa sai por zero e o item
      -- fica marcado. Zerar calado seria pior do que marcar.
      if s_qtd <= 0 then
        furou := true;
        custo := 0;
      else
        custo := s_val / s_qtd;
      end if;
      s_qtd := s_qtd + m.qtd;              -- m.qtd e negativo
      s_val := s_val + m.qtd * custo;
      x_qtd := x_qtd - m.qtd;              -- positivo, para leitura
      x_val := x_val - m.qtd * coalesce(m.vl_unit, 0);
      x_cst := x_cst - m.qtd * custo;

    -- para_terceiros e de_terceiros so trocam a posse: quantidade total e
    -- custo nao mudam, porque a mercadoria continua sendo da empresa.
    end if;
  end loop;

  if k_cnpj is not null then
    cnpj := k_cnpj; cod_item := k_item;
    qtd_entrada := e_qtd; vl_entrada := round(e_val, 2);
    qtd_saida := x_qtd; vl_saida := round(x_val, 2);
    vl_saida_custo := round(x_cst, 2);
    saldo_qtd := s_qtd; saldo_proprio := s_p0; saldo_terceiros := s_p1;
    custo_medio := case when s_qtd > 0 then round(s_val / s_qtd, 6) else 0 end;
    valor := round(s_val, 2);
    sem_custo := furou; movimentos := n_mov;
    primeira_mov := d_ini; ultima_mov := d_fim;
    return next;
  end if;
end $$;

comment on function estoque_periodo(date, date, text) is
  'Movimentacao de um periodo com todo item comecando em zero. Saldo negativo '
  'aqui e esperado: significa que o mes consumiu estoque anterior. Nao alimenta '
  'o motor de achados.';


-- Versao com cadastro resolvido, para a tela. Mesma cascata da posicao
-- acumulada: cadastro 0200, saldo de abertura, NF-e.
create or replace function estoque_periodo_detalhe(
  p_ini date, p_fim date, p_origem text default 'nfe')
returns table (
  uf text, cnpj text, cod_item text, descr_item text, ncm text, unid text,
  qtd_entrada numeric, vl_entrada numeric,
  qtd_saida numeric, vl_saida numeric, vl_saida_custo numeric,
  saldo_qtd numeric, saldo_proprio numeric, saldo_terceiros numeric,
  custo_medio numeric, valor numeric, sem_custo boolean,
  movimentos bigint, primeira_mov date, ultima_mov date,
  origem_cadastro text, busca text
)
language sql stable as $$
  select
    e.uf, s.cnpj, s.cod_item,
    coalesce(i.descr_item, sa.descr_item, nf.x_prod)          as descr_item,
    coalesce(i.ncm, nf.ncm)                                   as ncm,
    coalesce(sa.unid, i.unid_inv, nf.u_com)                   as unid,
    s.qtd_entrada, s.vl_entrada,
    s.qtd_saida, s.vl_saida, s.vl_saida_custo,
    s.saldo_qtd, s.saldo_proprio, s.saldo_terceiros,
    s.custo_medio, s.valor, s.sem_custo,
    s.movimentos, s.primeira_mov, s.ultima_mov,
    case
      when i.descr_item  is not null then 'cadastro 0200'
      when sa.descr_item is not null then 'saldo de abertura'
      when nf.x_prod     is not null then 'NF-e'
      else 'sem cadastro'
    end                                                       as origem_cadastro,
    upper(coalesce(i.descr_item, sa.descr_item, nf.x_prod, '') || ' ' ||
          s.cod_item || ' ' || coalesce(i.ncm, nf.ncm, ''))   as busca
  from estoque_periodo(p_ini, p_fim, p_origem) s
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
  ) sa on true
  -- Só nota que NOS emitimos: ali o cProd e o nosso codigo. Em nota recebida
  -- o cProd e do fornecedor e casaria produto errado.
  left join lateral (
    select ni.x_prod, ni.ncm, ni.u_com
    from nfe_item ni
    join nfe n on n.id = ni.nfe_id
    where ni.c_prod = s.cod_item and n.emit_cnpj = s.cnpj
    order by n.dt_emi desc, ni.id desc
    limit 1
  ) nf on true;
$$;


-- Totais do periodo, para os indicadores do topo.
create or replace function estoque_periodo_resumo(
  p_ini date, p_fim date, p_origem text default 'nfe')
returns table (
  itens           bigint,
  movimentos      bigint,
  qtd_entrada     numeric,
  vl_entrada      numeric,
  qtd_saida       numeric,
  vl_saida        numeric,
  vl_saida_custo  numeric,
  saldo_qtd       numeric,
  saldo_valor     numeric,
  negativos       bigint,
  sem_custo       bigint,
  zerados         bigint,
  filiais         bigint,
  primeira_mov    date,
  ultima_mov      date
)
language sql stable as $$
  select count(*)::bigint,
         coalesce(sum(movimentos), 0)::bigint,
         coalesce(sum(qtd_entrada), 0),
         coalesce(sum(vl_entrada), 0),
         coalesce(sum(qtd_saida), 0),
         coalesce(sum(vl_saida), 0),
         coalesce(sum(vl_saida_custo), 0),
         coalesce(sum(saldo_qtd), 0),
         coalesce(sum(valor), 0),
         count(*) filter (where saldo_qtd < 0)::bigint,
         count(*) filter (where sem_custo)::bigint,
         count(*) filter (where saldo_qtd = 0)::bigint,
         count(distinct cnpj)::bigint,
         min(primeira_mov), max(ultima_mov)
  from estoque_periodo(p_ini, p_fim, p_origem);
$$;


-- Meses com movimento, para a tela oferecer o que existe em vez de pedir que o
-- usuario adivinhe a data.
create or replace view v_meses_movimento as
select to_char(dt, 'YYYY-MM')                      as mes,
       min(dt)                                     as primeiro_dia,
       max(dt)                                     as ultimo_dia,
       count(*)                                    as movimentos,
       count(*) filter (where origem = 'nfe')      as movimentos_nfe,
       count(distinct cnpj)                        as filiais,
       count(distinct cod_item)                    as itens
from movimento
group by 1
order by 1;

comment on view v_meses_movimento is
  'Meses em que ha movimento, para o seletor da tela de periodo.';
