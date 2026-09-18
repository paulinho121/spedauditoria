-- 045 — Bem de terceiro em nosso poder: o conserto movimenta a posse, nao o
-- estoque proprio.
--
-- A 039 classificou 2915 e 6916 como fora de escopo. O auditor apontou que a
-- 6916 tem de movimentar estoque, e tem razao — mas o estoque do CLIENTE em
-- poder da empresa, nao o da empresa. As notas de julho/2026 mostram o fluxo:
--
--   cliente pessoa fisica ... SP emite a entrada 2915 (NF 2461, cod 4338, 2 un)
--                             e devolve na 6916 (NF 2463, mesmo item e valor)
--   cliente empresa ......... o cliente emite a 6915 (NF 122, Apture 300D)
--                             e SP devolve na 6916 (NF 2438)
--
-- O equipamento e do cliente o tempo todo. Se a 6916 baixasse o estoque
-- proprio, o retorno da Equipacine (NF 2457/2458, entradas nao importadas)
-- baixaria R$ 19.488 de mercadoria que nunca foi da empresa, e o saldo ficaria
-- negativo; enquanto o conserto estivesse em curso, o valor do estoque proprio
-- incharia com bem alheio.
--
-- O Bloco H preve exatamente isto: IND_PROP 2, "de terceiros em poder do
-- informante". Os movimentos passam a usar ind_prop '2':
--
--   terceiro_entra  +qtd em ind_prop 2   2915/1915 (entrada que a empresa emite)
--                                        e a 5915/6915 recebida do cliente
--   terceiro_sai    -qtd em ind_prop 2   6916/5916 (retorno ao dono)
--
-- Nada disso toca quantidade, valor ou custo medio do estoque proprio. A ficha
-- do item mostra as linhas como "bem de terceiro", sem mexer no saldo.
--
-- E o espelho no destino: a 6916 que um prestador emite para NOS devolvendo o
-- que mandamos para conserto e o nosso bem voltando (de_terceiros); a 6915 que
-- um cliente emite para nos e o bem dele entrando (terceiro_entra). Entre as
-- filiais do grupo nao ha terceiro, e nada muda.

alter table cfop_efeito drop constraint if exists cfop_efeito_efeito_check;
alter table cfop_efeito add constraint cfop_efeito_efeito_check check (efeito in
  ('soma','baixa','para_terceiros','de_terceiros','simbolico','fora_escopo',
   'terceiro_entra','terceiro_sai'));

update cfop_efeito set efeito = 'terceiro_entra', move_fisico = true,
       observacao = 'Bem do cliente entra em nosso poder (IND_PROP 2). Nao e estoque proprio'
 where cfop in ('1915','2915');
update cfop_efeito set efeito = 'terceiro_sai', move_fisico = true,
       observacao = 'Bem do cliente volta ao dono (IND_PROP 2). Nao e estoque proprio'
 where cfop in ('5916','6916');


-- ================================================ efeito visto por quem recebe
create or replace function efeito_no_destino(p_efeito text, p_interna boolean)
returns text language sql immutable as $$
  select case
           when p_efeito = 'baixa' then 'soma'
           when p_efeito = 'soma'  then 'baixa'
           -- o cliente manda o bem dele para conserto
           when p_efeito = 'para_terceiros' and not p_interna then 'terceiro_entra'
           -- o prestador devolve o NOSSO bem que estava com ele
           when p_efeito = 'terceiro_sai'   and not p_interna then 'de_terceiros'
         end;
$$;
comment on function efeito_no_destino(text, boolean) is
  'Efeito do CFOP do emitente visto por quem recebe. p_interna: a nota e entre '
  'filiais do grupo — ai remessa e retorno nao criam posse de terceiro.';

-- A versao de um argumento continua existindo para quem ja a chamava; supoe
-- emitente externo.
create or replace function efeito_no_destino(p_efeito text)
returns text language sql immutable as $$
  select efeito_no_destino(p_efeito, false);
$$;


-- Linhas de movimento de um efeito: quantidade e indicador de propriedade.
create or replace function linhas_do_efeito(p_efeito text, p_qtd numeric)
returns table (qtd numeric, ind_prop text)
language sql immutable as $$
  select * from (values
    (case p_efeito when 'soma' then p_qtd when 'baixa' then -p_qtd
                   when 'para_terceiros' then -p_qtd when 'de_terceiros' then p_qtd end, '0'),
    (case p_efeito when 'para_terceiros' then p_qtd when 'de_terceiros' then -p_qtd end, '1'),
    (case p_efeito when 'terceiro_entra' then p_qtd when 'terceiro_sai' then -p_qtd end, '2')
  ) as v(q, p)
  where q is not null;
$$;
comment on function linhas_do_efeito(text, numeric) is
  'Convencao de sinal num lugar so: 0 = proprio em nosso poder, 1 = proprio com '
  'terceiro, 2 = de terceiro em nosso poder.';


-- ================================================ movimento de quem emite
create or replace function gerar_movimento_emitente(p_nfe_id bigint)
returns int language plpgsql as $$
declare
  n record; it record; v_ef record; v_vu numeric; v_movs int := 0; k int;
begin
  select * into n from nfe where id = p_nfe_id;
  if n.id is null or n.situacao <> 'autorizada'
     or not exists (select 1 from estabelecimento where cnpj = n.emit_cnpj) then
    return 0;
  end if;
  for it in select * from nfe_item where nfe_id = p_nfe_id order by n_item loop
    if exists (select 1 from movimento m
                where m.nfe_item_id = it.id and m.cnpj = n.emit_cnpj) then
      continue;
    end if;
    select * into v_ef from cfop_efeito where cfop = it.cfop;
    if v_ef.cfop is null then continue; end if;
    if it.q_com is null or it.q_com <= 0 then continue; end if;
    v_vu := it.v_prod / it.q_com;
    insert into movimento (cnpj, dt, cod_item, origem, nfe_id, nfe_item_id,
           chave, n_item, cfop, efeito, qtd, vl_unit, vl_total, ind_prop, observacao)
    select n.emit_cnpj, n.dt_emi, it.c_prod, 'nfe', n.id, it.id, n.chave,
           it.n_item, it.cfop, v_ef.efeito, l.qtd, v_vu, abs(l.qtd) * v_vu, l.ind_prop,
           'saida · ' || v_ef.descricao
      from linhas_do_efeito(v_ef.efeito, it.q_com) l;
    get diagnostics k = row_count;
    v_movs := v_movs + k;
  end loop;
  return v_movs;
end $$;


-- ================================================ movimento de quem recebe
create or replace function gerar_movimento_destino(
  p_nfe_id bigint, p_registra_pendencia boolean default true)
returns table (movimentos int, pendencias int, automaticos int)
language plpgsql as $$
declare
  n record; it record; v_ef text; v_desc text; v_ef_dest text;
  v_cod text; v_fator numeric; v_qtd numeric; v_vu numeric; v_auto boolean;
  v_interna boolean; k int;
begin
  movimentos := 0; pendencias := 0; automaticos := 0;

  select * into n from nfe where id = p_nfe_id;
  if n.id is null or n.situacao <> 'autorizada'
     or n.emit_cnpj = n.dest_doc
     or not exists (select 1 from estabelecimento where cnpj = n.dest_doc) then
    return next; return;
  end if;
  v_interna := exists (select 1 from estabelecimento where cnpj = n.emit_cnpj);

  for it in select * from nfe_item where nfe_id = p_nfe_id order by n_item loop
    if exists (select 1 from movimento m
                where m.nfe_item_id = it.id and m.cnpj = n.dest_doc) then
      continue;
    end if;

    select c.efeito, c.descricao into v_ef, v_desc
      from cfop_efeito c where c.cfop = it.cfop;
    if v_ef is null then continue; end if;
    v_ef_dest := efeito_no_destino(v_ef, v_interna);
    if v_ef_dest is null then continue; end if;

    v_cod := null; v_fator := null; v_auto := false;
    select d.cod_item, d.fator_unidade into v_cod, v_fator
      from item_depara d
     where d.cnpj = n.dest_doc and d.c_prod_externo = it.c_prod
       and (d.parceiro_doc = n.emit_cnpj or d.parceiro_doc is null)
     order by d.parceiro_doc nulls last limit 1;

    if v_cod is null then
      v_cod := depara_transferencia(n.dest_doc, n.emit_cnpj, it.c_prod, it.x_prod);
      v_fator := 1;
      v_auto := v_cod is not null;
    end if;

    if v_cod is null then
      if p_registra_pendencia then
        insert into item_pendente_todos (cnpj, parceiro_doc, parceiro_nome,
               c_prod_externo, x_prod, ncm, u_com, ocorrencias, qtd_total,
               vl_total, primeira_chave)
        values (n.dest_doc, n.emit_cnpj, n.emit_nome, it.c_prod, it.x_prod,
                it.ncm, it.u_com, 1, it.q_com, it.v_prod, n.chave)
        on conflict (trabalho_id, cnpj, coalesce(parceiro_doc, ''), c_prod_externo)
        do update set
          ocorrencias = item_pendente_todos.ocorrencias + 1,
          qtd_total = coalesce(item_pendente_todos.qtd_total, 0) + excluded.qtd_total,
          vl_total  = coalesce(item_pendente_todos.vl_total, 0) + excluded.vl_total;
      end if;
      pendencias := pendencias + 1;
      continue;
    end if;

    v_qtd := it.q_com * coalesce(v_fator, 1);
    if v_qtd is null or v_qtd <= 0 then continue; end if;
    v_vu := it.v_prod / v_qtd;

    insert into movimento (cnpj, dt, cod_item, origem, nfe_id, nfe_item_id,
           chave, n_item, cfop, efeito, qtd, vl_unit, vl_total, ind_prop, observacao)
    select n.dest_doc, n.dt_emi, v_cod, 'nfe', n.id, it.id, n.chave, it.n_item,
           it.cfop, v_ef_dest, l.qtd, v_vu, abs(l.qtd) * v_vu, l.ind_prop,
           'entrada · ' || coalesce(v_desc, '')
             || case when v_auto then ' · de-para automatico' else '' end
      from linhas_do_efeito(v_ef_dest, v_qtd) l;
    get diagnostics k = row_count;
    if k > 0 then movimentos := movimentos + 1; end if;
    if v_auto then automaticos := automaticos + 1; end if;
  end loop;
  return next;
end $$;


-- ============================ estoque proprio: bem de terceiro fica de fora
-- Um movimento com ind_prop 2 cairia no "else" da posse (em seu poder) e
-- inflaria o estoque proprio. As duas reconstrucoes passam a ignora-lo.
-- Definicoes identicas as da 006 e da 032, com o filtro a mais.

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
      and coalesce(mv.ind_prop, '0') <> '2'   -- bem de terceiro nao e estoque proprio
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
      and coalesce(mv.ind_prop, '0') <> '2'   -- bem de terceiro nao e estoque proprio
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


-- ================================== ficha do item: mostra, sem mexer no saldo
create or replace function kardex_item(p_cnpj text, p_cod_item text, p_ate date default null)
returns table(seq bigint, dt date, origem text, chave character, num_nf text, serie text,
  natureza text, cfop text, cfop_descr text, efeito text, contraparte text,
  contraparte_doc text, contraparte_uf text, interna boolean, natureza_mov text,
  entrada numeric, saida numeric, vl_unit_mov numeric, vl_total_mov numeric,
  saldo_qtd numeric, saldo_proprio numeric, saldo_terceiros numeric,
  custo_medio numeric, saldo_valor numeric, observacao text)
language plpgsql stable as $$
declare
  m record; s_qtd numeric := 0; s_val numeric := 0; s_p0 numeric := 0;
  s_p1 numeric := 0; i bigint := 0; custo numeric; entrou numeric; v_doc text;
begin
  for m in
    select mv.id, mv.dt, mv.origem, mv.chave, mv.cfop, mv.efeito, mv.qtd,
           mv.vl_unit, mv.vl_total, mv.ind_prop, mv.observacao,
           n.num_nf, n.serie, n.nat_op, n.emit_cnpj, n.emit_nome,
           n.dest_doc, n.dest_nome, ce.descricao as cfop_descr
      from movimento mv
      left join nfe n on n.id = mv.nfe_id
      left join cfop_efeito ce on ce.cfop = mv.cfop
     where mv.cnpj = p_cnpj and mv.cod_item = p_cod_item
       and (p_ate is null or mv.dt <= p_ate)
     order by mv.dt, mv.id
  loop
    i := i + 1;
    -- ind_prop 2 e bem de terceiro: aparece na ficha, nao entra em saldo nenhum
    if m.ind_prop = '1' then s_p1 := s_p1 + m.qtd;
    elsif coalesce(m.ind_prop, '0') = '0' then s_p0 := s_p0 + m.qtd;
    end if;

    if m.efeito = 'soma' then
      entrou := coalesce(m.vl_total, m.qtd * coalesce(m.vl_unit, 0));
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + abs(entrou) * sign(m.qtd);
    elsif m.efeito = 'baixa' then
      custo := case when s_qtd > 0 then s_val / s_qtd else 0 end;
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + m.qtd * custo;
    end if;

    seq := i; dt := m.dt; origem := m.origem; chave := m.chave;
    num_nf := m.num_nf; serie := m.serie;
    natureza := coalesce(m.nat_op, m.observacao);
    cfop := m.cfop; cfop_descr := m.cfop_descr; efeito := m.efeito;
    contraparte := case when m.emit_cnpj is null then null
                        when m.emit_cnpj = p_cnpj then m.dest_nome else m.emit_nome end;
    v_doc := case when m.emit_cnpj is null then null
                  when m.emit_cnpj = p_cnpj then m.dest_doc else m.emit_cnpj end;
    contraparte_doc := v_doc;
    select e.uf into contraparte_uf from estabelecimento e where e.cnpj = v_doc;
    interna := contraparte_uf is not null;

    natureza_mov := case
      when m.origem = 'abertura'                           then 'abertura'
      when m.ind_prop = '2'                                then 'terceiro'
      when interna                                         then 'transferencia'
      when m.efeito in ('para_terceiros','de_terceiros')   then 'posse'
      when m.efeito = 'simbolico'                          then 'simbolico'
      when m.qtd > 0                                       then 'entrada'
      else 'saida' end;

    entrada := case when m.qtd > 0 then m.qtd else null end;
    saida   := case when m.qtd < 0 then -m.qtd else null end;
    vl_unit_mov := m.vl_unit; vl_total_mov := m.vl_total;
    saldo_qtd := s_qtd; saldo_proprio := s_p0; saldo_terceiros := s_p1;
    custo_medio := case when s_qtd > 0 then round(s_val / s_qtd, 6) else 0 end;
    saldo_valor := round(s_val, 2);
    observacao := m.observacao;
    return next;
  end loop;
end $$;


-- ================================ a posicao de bens de terceiros em nosso poder
create or replace function estoque_de_terceiros(p_data date)
returns table (cnpj text, uf text, cod_item text, descr_item text,
               dono_doc text, dono_nome text, qtd numeric, valor_nota numeric,
               ultima_mov date, ultima_nf text)
language sql stable as $$
  with mv as (
    select m.cnpj, m.cod_item, m.qtd, m.vl_unit, m.dt, n.num_nf,
           case when n.emit_cnpj = m.cnpj then n.dest_doc  else n.emit_cnpj end dono_doc,
           case when n.emit_cnpj = m.cnpj then n.dest_nome else n.emit_nome end dono_nome
      from movimento m join nfe n on n.id = m.nfe_id
     where m.ind_prop = '2' and m.dt <= p_data
  )
  select mv.cnpj, e.uf, mv.cod_item,
         coalesce((select c.descr_item from item_cadastro_nfe c
                    where c.cnpj = mv.cnpj and c.cod_item = mv.cod_item limit 1),
                  (select s.descr_item from sped_item s
                    where s.cnpj_estab = mv.cnpj and s.cod_item = mv.cod_item limit 1)),
         mv.dono_doc, min(mv.dono_nome),
         sum(mv.qtd), round(sum(mv.qtd * mv.vl_unit), 2),
         max(mv.dt), (array_agg(mv.num_nf order by mv.dt desc))[1]
    from mv left join estabelecimento e on e.cnpj = mv.cnpj
   group by mv.cnpj, e.uf, mv.cod_item, mv.dono_doc
  having sum(mv.qtd) <> 0
   order by 8 desc;
$$;
comment on function estoque_de_terceiros(date) is
  'Bens de terceiros em poder da empresa na data (IND_PROP 2 do Bloco H): o que '
  'entrou para conserto e ainda nao voltou ao dono. Negativo = devolveu o que '
  'nao consta ter entrado — falta a nota de entrada.';


-- Bloqueios: a remessa entre filiais nao cria posse de terceiro no destino.
create or replace function periodo_bloqueios(p_ini date, p_fim date)
returns table (motivo text, linhas bigint, notas bigint, quantidade numeric,
               valor numeric, onde_tratar text)
language sql stable as $$
  with lado as (
    select v.id as nfe_id, v.situacao, i.id as item_id, i.cfop, i.q_com, i.v_prod,
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

select * from reprocessar_notas();
