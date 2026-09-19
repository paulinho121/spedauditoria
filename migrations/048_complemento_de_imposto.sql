-- 048 — Complemento de imposto nao e receita.
--
-- Nota complementar (finNFe 2) serve a duas coisas diferentes:
--
--   complemento de PRECO   mercadoria cobrada a menor. E receita.
--                          Ex.: NF 562706 de SC, vProd 60,07 com ICMS de 2,40.
--   complemento de IMPOSTO ICMS (ou IPI) destacado a menor. NAO e receita: e
--                          o imposto que faltou.
--                          Ex.: NF 10533 e 10534 de CE, "referente a ICMS
--                          complementar", com vICMS igual ao vNF (1.703,04 e
--                          2.342,63), complementando as NF 10487 e 10503.
--
-- A 043 tratava as duas como receita, e o faturamento de CE de julho/2026
-- carregava R$ 4.045,67 de imposto como se fosse venda — inclusive na base de
-- PIS e COFINS.
--
-- Criterio: nota complementar em que os impostos destacados (ICMS, IPI, ST e
-- FCP-ST) cobrem o valor inteiro da nota e complemento de imposto. A receita
-- dela e zero. O total faturado continua o da nota, que e o que o ERP lista, e
-- o ICMS dela continua debito na apuracao — la ele pertence.

create or replace function nfe_complemento_de_imposto(p_nfe_id bigint)
returns boolean language sql stable as $$
  select n.fin_nfe = '2'
     and coalesce((select sum(coalesce(t.icms_v,0) + coalesce(t.ipi_v,0)
                              + coalesce(t.st_v,0) + coalesce(t.fcpst_v,0))
                     from nfe_item i join nfe_item_imposto t on t.nfe_item_id = i.id
                    where i.nfe_id = n.id), 0) >= n.vl_nf - 0.01
    from nfe n where n.id = p_nfe_id;
$$;
comment on function nfe_complemento_de_imposto(bigint) is
  'Nota complementar cujo valor e so imposto: nao e receita.';

create or replace function faturamento_linhas(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  nfe_id bigint, num_nf text, dt_emi date, cnpj text, contraparte text,
  cfop text, grupo text, sinal int, descricao text,
  valor numeric, valor_total numeric, ipi numeric, st numeric, vl_nf numeric
)
language sql stable as $$
  select n.id, n.num_nf, n.dt_emi,
         case f.lado when 'emitente' then n.emit_cnpj else n.dest_doc end,
         case f.lado when 'emitente' then n.dest_nome else n.emit_nome end,
         i.cfop, f.grupo, f.sinal, f.descricao,
         case when nfe_complemento_de_imposto(n.id) then 0
              else coalesce(i.v_prod,0) - coalesce(i.v_desc,0)
                   + coalesce(i.v_frete,0) + coalesce(i.v_seg,0) + coalesce(i.v_outro,0)
         end,
         coalesce(i.v_prod,0) - coalesce(i.v_desc,0)
           + coalesce(i.v_frete,0) + coalesce(i.v_seg,0) + coalesce(i.v_outro,0)
           + coalesce(t.ipi_v,0) + coalesce(t.st_v,0) + coalesce(t.fcpst_v,0),
         coalesce(t.ipi_v,0), coalesce(t.st_v,0) + coalesce(t.fcpst_v,0),
         n.vl_nf
    from nfe n
    join nfe_item i on i.nfe_id = n.id
    join cfop_faturamento f on f.cfop = i.cfop
    left join nfe_item_imposto t on t.nfe_item_id = i.id
   where n.situacao = 'autorizada'
     and n.dt_emi between p_ini and p_fim
     and ( (f.lado = 'emitente'
            and n.emit_cnpj in (select e.cnpj from estabelecimento e)
            and (p_cnpj is null or n.emit_cnpj = p_cnpj))
        or (f.lado = 'destino'
            and n.dest_doc in (select e.cnpj from estabelecimento e)
            and (p_cnpj is null or n.dest_doc = p_cnpj)) )
     and not (p_cnpj is null
              and n.emit_cnpj in (select e.cnpj from estabelecimento e)
              and n.dest_doc  in (select e.cnpj from estabelecimento e));
$$;

-- A base federal le direto do item; aplica o mesmo criterio.
do $$
declare d text;
begin
  select pg_get_functiondef('apuracao_federal_calculada(date,date)'::regprocedure) into d;
  if position('nfe_complemento_de_imposto' in d) = 0 then
    d := replace(d,
      'select f.sinal,' || chr(10) || '           coalesce(i.v_prod,0) - coalesce(i.v_desc,0) + coalesce(i.v_frete,0)'
        || chr(10) || '             + coalesce(i.v_seg,0) + coalesce(i.v_outro,0) as valor,',
      'select f.sinal,' || chr(10) || '           case when nfe_complemento_de_imposto(n.id) then 0 else'
        || chr(10) || '           coalesce(i.v_prod,0) - coalesce(i.v_desc,0) + coalesce(i.v_frete,0)'
        || chr(10) || '             + coalesce(i.v_seg,0) + coalesce(i.v_outro,0) end as valor,');
    if position('nfe_complemento_de_imposto' in d) = 0 then
      raise exception 'apuracao_federal_calculada: trecho esperado nao encontrado — nada alterado';
    end if;
    execute d;
  end if;
end $$;
