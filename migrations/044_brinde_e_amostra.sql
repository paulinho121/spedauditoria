-- 044 — Brinde, bonificacao, doacao e amostra gratis movimentam o estoque.
--
-- A 039 classificou a 5910 (brinde dentro do estado) como baixa, mas a 6910 —
-- a mesma operacao para outro estado — nunca tinha sido classificada. Treze
-- linhas de nota de 2022 e 2023, 21 unidades, sairam da empresa e continuavam
-- no saldo, como se nunca tivessem saido.
--
-- A familia inteira e classificada de uma vez:
--
--   5910/6910  remessa em bonificacao, doacao ou brinde .... baixa
--   5911/6911  remessa de amostra gratis ................... baixa
--   1910/2910  entrada de bonificacao, doacao ou brinde .... soma
--   1911/2911  entrada de amostra gratis ................... soma
--
-- A mercadoria sai e nao volta: e baixa, nao remessa para terceiro. E nao e
-- receita — nenhum destes CFOPs esta em cfop_faturamento.
--
-- Classificar um CFOP nao gera sozinho o movimento das notas ja importadas;
-- reprocessar_notas() faz isso no fim.

insert into cfop_efeito (cfop, descricao, sentido, efeito, move_fisico,
                         muda_propriedade, compoe_custo, observacao) values
 ('6910','Remessa em bonificacao, doacao ou brinde, outro estado','saida','baixa',true,true,false,
  'A mercadoria sai e deixa de ser nossa'),
 ('5911','Remessa de amostra gratis','saida','baixa',true,true,false,
  'A mercadoria sai e nao volta'),
 ('6911','Remessa de amostra gratis, outro estado','saida','baixa',true,true,false,
  'A mercadoria sai e nao volta'),
 ('1910','Entrada de bonificacao, doacao ou brinde','entrada','soma',true,true,false,
  'Mercadoria recebida sem custo de aquisicao'),
 ('2910','Entrada de bonificacao, doacao ou brinde, outro estado','entrada','soma',true,true,false,
  'Mercadoria recebida sem custo de aquisicao'),
 ('1911','Entrada de amostra gratis','entrada','soma',true,true,false,
  'Mercadoria recebida sem custo de aquisicao'),
 ('2911','Entrada de amostra gratis, outro estado','entrada','soma',true,true,false,
  'Mercadoria recebida sem custo de aquisicao')
on conflict (cfop) do nothing;

select * from reprocessar_notas();
