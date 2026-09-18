-- 040 — Faturamento do periodo, a partir dos XML.
--
-- Pergunta do auditor: quanto a filial faturou no mes, contando venda e
-- locacao. A resposta precisa separar o que e receita do que so parece:
--
--   · VENDA de mercadoria conta. Inclui venda com ST, a nao contribuinte,
--     combustivel e exportacao.
--   · DEVOLUCAO de venda subtrai — emitida por nos (entrada 1202/2202...) ou
--     pelo cliente contribuinte (5202/6202... com a filial como destinataria).
--   · VENDA PARA ENTREGA FUTURA aparece em duas notas: o faturamento (5922) e a
--     remessa (5117). Somar as duas conta a venda duas vezes. Conta a remessa:
--     e quando a mercadoria sai e a propriedade passa ao cliente (CPC 47), e e a
--     nota em que o ICMS e destacado. O faturamento antecipado aparece a parte,
--     informativo. Quem preferir o outro criterio troca o sinal na tabela.
--   · REMESSA EM LOCACAO OU COMODATO (5908/6908) NAO e receita: a nota leva o
--     valor do equipamento, nao o do aluguel. Somar seria contar patrimonio
--     como faturamento. Aparece a parte, informativa.
--   · Transferencia entre filiais, remessa, retorno, conserto: nao sao receita e
--     nao estao na tabela.
--
-- A receita do aluguel propriamente dito nao esta em NF-e. Se existir em
-- documento fiscal, e NFS-e — que o sistema ainda nao le.
--
-- Valor: mercadoria liquida de desconto (vProd - vDesc) de cada linha, porque
-- o CFOP e por item e uma nota pode misturar venda com outra operacao. O total
-- das notas (vNF, com IPI, ST e frete) vem ao lado, para conferencia.
--
-- So nota autorizada: cancelada nao fatura.

create table if not exists cfop_faturamento (
  cfop        text not null,
  lado        text not null check (lado in ('emitente', 'destino')),
  grupo       text not null check (grupo in ('venda', 'devolucao_venda',
                'entrega_futura_faturamento', 'remessa_locacao_comodato')),
  sinal       int  not null check (sinal in (1, -1, 0)),
  descricao   text not null,
  observacao  text,
  primary key (cfop, lado)
);
comment on table cfop_faturamento is
  'Quais CFOPs compoem o faturamento e com que sinal. 0 = aparece a parte, '
  'informativo, sem somar. lado = a filial emitiu ou recebeu a nota.';

insert into cfop_faturamento (cfop, lado, grupo, sinal, descricao)
select c, 'emitente', 'venda', 1, d from (values
  ('5101','Venda de producao propria'), ('5102','Venda de mercadoria adquirida'),
  ('5103','Venda de producao, efetuada fora do estabelecimento'),
  ('5104','Venda de mercadoria adquirida, efetuada fora do estabelecimento'),
  ('5105','Venda de producao que nao deva transitar'),
  ('5106','Venda de mercadoria adquirida que nao deva transitar'),
  ('5109','Venda de producao a Zona Franca'), ('5110','Venda de mercadoria a Zona Franca'),
  ('5111','Venda de producao remetida em consignacao'),
  ('5112','Venda de mercadoria remetida em consignacao'),
  ('5113','Venda de producao remetida em consignacao mercantil'),
  ('5114','Venda de mercadoria remetida em consignacao mercantil'),
  ('5115','Venda de mercadoria recebida em consignacao mercantil'),
  ('5116','Venda de producao, entrega futura (remessa)'),
  ('5117','Venda de mercadoria, entrega futura (remessa)'),
  ('5118','Venda de producao entregue a destinatario por conta e ordem'),
  ('5119','Venda de mercadoria entregue a destinatario por conta e ordem'),
  ('5120','Venda de mercadoria entregue pelo vendedor remetente'),
  ('5122','Venda de producao remetida para industrializacao'),
  ('5123','Venda de mercadoria remetida para industrializacao'),
  ('5124','Industrializacao efetuada para outra empresa'),
  ('5125','Industrializacao efetuada para outra empresa, insumo de terceiro'),
  ('5401','Venda de producao com ST, substituto'), ('5402','Venda de producao com ST, substituto'),
  ('5403','Venda de mercadoria com ST, substituto'), ('5405','Venda de mercadoria com ST, substituido'),
  ('5501','Remessa com fim especifico de exportacao, producao'),
  ('5502','Remessa com fim especifico de exportacao, mercadoria'),
  ('5651','Venda de combustivel de producao'), ('5652','Venda de combustivel de producao'),
  ('5653','Venda de combustivel a consumidor final'), ('5654','Venda de combustivel adquirido'),
  ('5655','Venda de combustivel adquirido'), ('5656','Venda de combustivel a consumidor final'),
  ('5667','Venda de combustivel a consumidor de outra UF'),
  ('6101','Venda de producao propria, outro estado'), ('6102','Venda de mercadoria adquirida, outro estado'),
  ('6103','Venda de producao fora do estabelecimento, outro estado'),
  ('6104','Venda de mercadoria fora do estabelecimento, outro estado'),
  ('6105','Venda de producao que nao deva transitar, outro estado'),
  ('6106','Venda de mercadoria que nao deva transitar, outro estado'),
  ('6107','Venda de producao a nao contribuinte, outro estado'),
  ('6108','Venda de mercadoria a nao contribuinte, outro estado'),
  ('6109','Venda de producao a Zona Franca'), ('6110','Venda de mercadoria a Zona Franca'),
  ('6111','Venda de producao em consignacao, outro estado'),
  ('6112','Venda de mercadoria em consignacao, outro estado'),
  ('6113','Venda de producao em consignacao mercantil, outro estado'),
  ('6114','Venda de mercadoria em consignacao mercantil, outro estado'),
  ('6115','Venda de mercadoria recebida em consignacao mercantil, outro estado'),
  ('6116','Venda de producao, entrega futura (remessa), outro estado'),
  ('6117','Venda de mercadoria, entrega futura (remessa), outro estado'),
  ('6118','Venda de producao por conta e ordem, outro estado'),
  ('6119','Venda de mercadoria por conta e ordem, outro estado'),
  ('6120','Venda de mercadoria entregue pelo vendedor remetente, outro estado'),
  ('6122','Venda de producao para industrializacao, outro estado'),
  ('6123','Venda de mercadoria para industrializacao, outro estado'),
  ('6124','Industrializacao para outra empresa, outro estado'),
  ('6125','Industrializacao para outra empresa, insumo de terceiro, outro estado'),
  ('6401','Venda de producao com ST, outro estado'), ('6402','Venda de producao com ST, outro estado'),
  ('6403','Venda de mercadoria com ST, outro estado'), ('6404','Venda de mercadoria com ST ja retida, outro estado'),
  ('6501','Remessa com fim especifico de exportacao, producao, outro estado'),
  ('6502','Remessa com fim especifico de exportacao, mercadoria, outro estado'),
  ('6651','Venda de combustivel de producao, outro estado'), ('6652','Venda de combustivel de producao, outro estado'),
  ('6653','Venda de combustivel a consumidor final, outro estado'),
  ('6654','Venda de combustivel adquirido, outro estado'), ('6655','Venda de combustivel adquirido, outro estado'),
  ('6656','Venda de combustivel a consumidor final, outro estado'),
  ('6667','Venda de combustivel a consumidor de outra UF'),
  ('7101','Exportacao de producao'), ('7102','Exportacao de mercadoria'),
  ('7105','Exportacao de producao via ZPE'), ('7106','Exportacao de mercadoria via ZPE'),
  ('7127','Exportacao de producao sob drawback'), ('7501','Exportacao de mercadoria recebida para exportacao'),
  ('7651','Exportacao de combustivel de producao'), ('7654','Exportacao de combustivel adquirido'),
  ('7667','Exportacao de combustivel a consumidor final')
) as v(c, d)
on conflict (cfop, lado) do nothing;

insert into cfop_faturamento (cfop, lado, grupo, sinal, descricao, observacao)
select c, l, 'devolucao_venda', -1, d, o from (values
  ('1201','emitente','Devolucao de venda de producao','Nota de entrada emitida pela filial'),
  ('1202','emitente','Devolucao de venda de mercadoria','Nota de entrada emitida pela filial'),
  ('1410','emitente','Devolucao de venda de producao com ST','Nota de entrada emitida pela filial'),
  ('1411','emitente','Devolucao de venda de mercadoria com ST','Nota de entrada emitida pela filial'),
  ('2201','emitente','Devolucao de venda de producao, outro estado','Nota de entrada emitida pela filial'),
  ('2202','emitente','Devolucao de venda de mercadoria, outro estado','Nota de entrada emitida pela filial'),
  ('2410','emitente','Devolucao de venda de producao com ST, outro estado','Nota de entrada emitida pela filial'),
  ('2411','emitente','Devolucao de venda de mercadoria com ST, outro estado','Nota de entrada emitida pela filial'),
  ('3201','emitente','Devolucao de exportacao de producao','Nota de entrada emitida pela filial'),
  ('3202','emitente','Devolucao de exportacao de mercadoria','Nota de entrada emitida pela filial'),
  ('5201','destino','Devolucao de compra (o cliente devolve)','Nota emitida pelo cliente contribuinte'),
  ('5202','destino','Devolucao de compra (o cliente devolve)','Nota emitida pelo cliente contribuinte'),
  ('5410','destino','Devolucao de compra com ST (o cliente devolve)','Nota emitida pelo cliente contribuinte'),
  ('5411','destino','Devolucao de compra com ST (o cliente devolve)','Nota emitida pelo cliente contribuinte'),
  ('6201','destino','Devolucao de compra (o cliente devolve), outro estado','Nota emitida pelo cliente contribuinte'),
  ('6202','destino','Devolucao de compra (o cliente devolve), outro estado','Nota emitida pelo cliente contribuinte'),
  ('6410','destino','Devolucao de compra com ST (o cliente devolve), outro estado','Nota emitida pelo cliente contribuinte'),
  ('6411','destino','Devolucao de compra com ST (o cliente devolve), outro estado','Nota emitida pelo cliente contribuinte')
) as v(c, l, d, o)
on conflict (cfop, lado) do nothing;

insert into cfop_faturamento (cfop, lado, grupo, sinal, descricao, observacao) values
 ('5922','emitente','entrega_futura_faturamento',0,'Faturamento antecipado de entrega futura',
  'Nao soma: a venda conta na remessa (5117). Somar as duas contaria duas vezes'),
 ('6922','emitente','entrega_futura_faturamento',0,'Faturamento antecipado de entrega futura, outro estado',
  'Nao soma: a venda conta na remessa (6117). Somar as duas contaria duas vezes'),
 ('5908','emitente','remessa_locacao_comodato',0,'Remessa de bem em locacao ou comodato',
  'Nao soma: o valor e o do equipamento, nao o do aluguel'),
 ('6908','emitente','remessa_locacao_comodato',0,'Remessa de bem em locacao ou comodato, outro estado',
  'Nao soma: o valor e o do equipamento, nao o do aluguel')
on conflict (cfop, lado) do nothing;


-- ============================================================ composicao
-- p_cnpj nulo = grupo consolidado. No consolidado, nota entre filiais do
-- proprio grupo fica fora: o grupo nao fatura para si mesmo.
create or replace function faturamento_linhas(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  nfe_id bigint, num_nf text, dt_emi date, cnpj text, contraparte text,
  cfop text, grupo text, sinal int, descricao text,
  valor numeric, vl_nf numeric
)
language sql stable as $$
  select n.id, n.num_nf, n.dt_emi,
         case f.lado when 'emitente' then n.emit_cnpj else n.dest_doc end,
         case f.lado when 'emitente' then n.dest_nome else n.emit_nome end,
         i.cfop, f.grupo, f.sinal, f.descricao,
         coalesce(i.v_prod, 0) - coalesce(i.v_desc, 0),
         n.vl_nf
    from nfe n
    join nfe_item i on i.nfe_id = n.id
    join cfop_faturamento f on f.cfop = i.cfop
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
comment on function faturamento_linhas(date, date, text) is
  'Cada linha de nota que compoe o faturamento, com o sinal. Base de '
  'faturamento_periodo e da lista de notas na tela.';


create or replace function faturamento_periodo(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  grupo text, sinal int, cfop text, descricao text,
  notas bigint, linhas bigint, valor numeric, vl_notas numeric
)
language sql stable as $$
  select grupo, sinal, cfop, min(descricao),
         count(distinct nfe_id)::bigint, count(*)::bigint,
         round(sum(valor), 2),
         round((select sum(x.vl_nf) from (select distinct l2.nfe_id, l2.vl_nf
                  from faturamento_linhas(p_ini, p_fim, p_cnpj) l2
                 where l2.cfop = l.cfop and l2.grupo = l.grupo) x), 2)
    from faturamento_linhas(p_ini, p_fim, p_cnpj) l
   group by grupo, sinal, cfop
   order by case grupo when 'venda' then 1 when 'devolucao_venda' then 2
                       when 'entrega_futura_faturamento' then 3 else 4 end,
            7 desc;
$$;


create or replace function faturamento_notas(p_ini date, p_fim date, p_cnpj text default null)
returns table (
  nfe_id bigint, num_nf text, dt_emi date, contraparte text, cfops text,
  grupo text, sinal int, valor numeric, vl_nf numeric
)
language sql stable as $$
  select nfe_id, num_nf, dt_emi, min(contraparte),
         string_agg(distinct cfop, ', '), grupo, sinal,
         round(sum(valor), 2), max(vl_nf)
    from faturamento_linhas(p_ini, p_fim, p_cnpj)
   group by nfe_id, num_nf, dt_emi, grupo, sinal
   order by dt_emi, num_nf;
$$;
