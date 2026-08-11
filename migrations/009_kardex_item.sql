-- 009 — Ficha do item: cada movimento com saldo corrido.
--
-- Mesma logica de custo medio ponderado movel de estoque_em, mas emitindo uma
-- linha por movimento em vez de so o saldo final. E o que permite responder
-- "entrou pela nota tal, saiu para o cliente tal, o saldo ficou tal".

create or replace function kardex_item(p_cnpj text, p_cod_item text,
                                       p_ate date default null)
returns table (
  seq             bigint,
  dt              date,
  origem          text,
  chave           char(44),
  num_nf          text,
  serie           text,
  natureza        text,
  cfop            text,
  cfop_descr      text,
  efeito          text,
  contraparte     text,
  contraparte_doc text,
  entrada         numeric,
  saida           numeric,
  vl_unit_mov     numeric,
  vl_total_mov    numeric,
  saldo_qtd       numeric,
  saldo_proprio   numeric,
  saldo_terceiros numeric,
  custo_medio     numeric,
  saldo_valor     numeric,
  observacao      text
)
language plpgsql stable as $$
declare
  m       record;
  s_qtd   numeric := 0;
  s_val   numeric := 0;
  s_p0    numeric := 0;
  s_p1    numeric := 0;
  i       bigint := 0;
  custo   numeric;
  entrou  numeric;
begin
  for m in
    select mv.id, mv.dt, mv.origem, mv.chave, mv.cfop, mv.efeito, mv.qtd,
           mv.vl_unit, mv.vl_total, mv.ind_prop, mv.observacao,
           n.num_nf, n.serie, n.nat_op, n.emit_cnpj, n.emit_nome,
           n.dest_doc, n.dest_nome,
           ce.descricao as cfop_descr
    from movimento mv
    left join nfe n on n.id = mv.nfe_id
    left join cfop_efeito ce on ce.cfop = mv.cfop
    where mv.cnpj = p_cnpj
      and mv.cod_item = p_cod_item
      and (p_ate is null or mv.dt <= p_ate)
    order by mv.dt, mv.id
  loop
    i := i + 1;

    if m.ind_prop = '1' then s_p1 := s_p1 + m.qtd; else s_p0 := s_p0 + m.qtd; end if;

    if m.efeito = 'soma' then
      entrou := coalesce(m.vl_total, m.qtd * coalesce(m.vl_unit, 0));
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + abs(entrou) * sign(m.qtd);
    elsif m.efeito = 'baixa' then
      custo := case when s_qtd > 0 then s_val / s_qtd else 0 end;
      s_qtd := s_qtd + m.qtd;
      s_val := s_val + m.qtd * custo;
    end if;

    seq := i;
    dt := m.dt;
    origem := m.origem;
    chave := m.chave;
    num_nf := m.num_nf;
    serie := m.serie;
    natureza := coalesce(m.nat_op, m.observacao);
    cfop := m.cfop;
    cfop_descr := m.cfop_descr;
    efeito := m.efeito;
    -- A contraparte e sempre o outro lado: se nos emitimos, e o destinatario.
    contraparte := case
      when m.emit_cnpj is null then null
      when m.emit_cnpj = p_cnpj then m.dest_nome
      else m.emit_nome end;
    contraparte_doc := case
      when m.emit_cnpj is null then null
      when m.emit_cnpj = p_cnpj then m.dest_doc
      else m.emit_cnpj end;
    entrada := case when m.qtd > 0 then m.qtd else null end;
    saida := case when m.qtd < 0 then -m.qtd else null end;
    vl_unit_mov := m.vl_unit;
    vl_total_mov := m.vl_total;
    saldo_qtd := s_qtd;
    saldo_proprio := s_p0;
    saldo_terceiros := s_p1;
    custo_medio := case when s_qtd > 0 then round(s_val / s_qtd, 6) else 0 end;
    saldo_valor := round(s_val, 2);
    observacao := m.observacao;
    return next;
  end loop;
end $$;

comment on function kardex_item(text, text, date) is
  'Ficha do item: um registro por movimento, com saldo e custo medio corridos. '
  'Sem p_ate, devolve o historico completo.';
