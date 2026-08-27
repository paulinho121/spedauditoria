-- 031 — A materialidade do trabalho novo nasce zerada, não nula.
--
-- A 030 criava a linha com os limiares em branco e esbarrava no NOT NULL de
-- planejamento. Zero e o valor certo, nao um numero inventado: trivial zero
-- significa que nenhum achado e descartado por ser pequeno. Um trabalho que
-- ainda nao tem inventario nao tem como saber o que e pequeno, e listar demais
-- e o erro barato — o caro e a ferramenta engolir um achado em silencio.
--
-- Os limiares reais saem do saldo de abertura, como na 017, e so podem ser
-- calculados depois que o inventario entrar. A observacao na linha diz isso a
-- quem abrir a tela.

create or replace function trabalho_novo(
  p_nome text, p_cliente text default null, p_exercicio text default null,
  p_descricao text default null, p_quem text default null, p_usar boolean default true)
returns trabalho language plpgsql as $$
declare v trabalho;
begin
  insert into trabalho (nome, cliente, exercicio, descricao, criado_por)
  values (p_nome, p_cliente, p_exercicio, p_descricao, coalesce(p_quem,'sistema'))
  returning * into v;

  insert into materialidade_todos (trabalho_id, escopo, planejamento, execucao,
                                   trivial, definido_por, observacao)
  values (v.id, 'padrao', 0, 0, 0, coalesce(p_quem,'sistema'),
          'Trabalho recem-criado, ainda sem saldo de abertura. Com trivial zero '
          'nenhum achado e descartado. Recalcule os limiares depois de importar '
          'o inventario: 1% de planejamento, 0,75% de execucao e 0,05% de '
          'trivial sobre o saldo de abertura.');

  if p_usar then perform trabalho_usar(v.id, p_quem); end if;
  return v;
end $$;

comment on function trabalho_novo(text, text, text, text, text, boolean) is
  'Abre uma auditoria nova e passa a usa-la. Os dados de um trabalho nao se '
  'misturam com os de outro, e excluir um trabalho leva os seus dados junto.';
