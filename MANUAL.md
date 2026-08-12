# Manual do usuário — Fiscal Stock

Este manual segue a ordem de um trabalho real: acessar, carregar, definir o
ponto de partida e o critério, examinar, tratar os achados e emitir o papel de
trabalho.

---

## 1. Acessar o sistema

O sistema funciona **inteiramente pelo navegador**. Entre com seu e-mail e senha
e comece a trabalhar — não é preciso instalar nem rodar nada.

Há uma única coisa que exige a sua máquina: **importar uma pasta inteira de
arquivos**. Enviar arquivos arrastando funciona online normalmente. A diferença
aparece só quando você tem centenas ou milhares de XML de uma vez.

### Quando usar o servidor local

```bash
python C:\Users\Acer\Desktop\fiscal\app\server.py
```

Abre em `http://localhost:8777`, com as mesmas telas mais a opção de varrer uma
pasta do computador. Use nas cargas grandes — por exemplo, os XML de um ano
inteiro.

Rodando local, se a interface parecer antiga depois de uma atualização, é cache
do navegador: **Ctrl+F5**.

---

## 2. Carregar os arquivos

### Conferir antes de importar

Vale rodar primeiro. Nada é gravado:

```bash
python -m auditoria conferir "C:\caminho\*.txt"
```

Mostra CNPJ, período, perfil, quantidade de registros e os problemas
encontrados — inclusive quanto do movimento tem detalhe por item, o que
determina o que vai ser possível apurar.

### Importar

Na tela **Importar**, arraste os arquivos EFD (`.txt`) ou NF-e (`.xml`) para a
área tracejada. Vale online e local.

Pelo terminal, em qualquer volume:

```bash
python -m auditoria importar "C:\caminho\*.txt"
python -m auditoria importar "C:\caminho\*.xml"
```

**A importação é idempotente.** O sistema calcula o SHA-256 de cada arquivo;
reimportar o mesmo conteúdo não faz nada. Um arquivo retificador não sobrescreve
o anterior: entra como nova versão e marca a anterior como não vigente,
preservando o histórico.

Cada arquivo é gravado em uma única operação, dentro de uma transação. Se algo
falhar no meio, nada daquele arquivo entra.

### O que observar depois de importar

Dois cartões travam o trabalho se estiverem acima de zero:

- **CFOP não classificado** — enquanto houver, os itens dessas notas não geram
  movimento e o saldo apurado está incompleto. Clique para ver as notas e
  decidir a classificação.
- **Itens sem correspondência** — código do fornecedor ainda não ligado a um
  item seu. Clique, depois use *Buscar candidatos no cadastro*: o sistema
  procura por código, NCM e semelhança de descrição, e indica a confiança.

> **Por que a entrada precisa de de-para e a saída não.** Numa nota que vocês
> emitem, o código do produto é o de vocês. Numa nota recebida, o código é de
> quem emitiu — inclusive quando vem de outra filial sua, porque os códigos
> colidem entre estabelecimentos. O código `4061` é refletor em SP e pinça em
> SC. Por isso cada um é confirmado uma vez; depois vale para sempre.

---

## 3. Definir o saldo de abertura

O saldo de abertura é o ponto zero do Kardex, e é **imutável**.

```bash
python -m auditoria congelar 2022-12-31
```

Congela o inventário daquela data como abertura. Rodar de novo não altera nada.

Uma vez congelado, o banco passa a proteger os arquivos que o originaram: não é
possível apagá-los enquanto o saldo de abertura os referenciar.

---

## 4. Definir a materialidade

Este passo é seu, não do sistema.

```bash
python -m auditoria materialidade
```

Mostra os limiares vigentes. Os valores iniciais foram derivados do próprio
saldo de abertura e **devem ser revistos**.

```bash
python -m auditoria materialidade 60000 45000 3000
```

Na ordem: planejamento, execução e claramente trivial.

| Nível | Para que serve |
|---|---|
| **Planejamento** | Distorção a partir da qual o trabalho é afetado |
| **Execução** | Margem de segurança, tipicamente 60–75% do planejamento |
| **Claramente trivial** | Abaixo disto o achado é contado e não listado |

O corte de trivialidade só vale para achado de natureza **monetária** —
divergência de valoração e item pendente. Falha estrutural aparece sempre, por
menor que seja o valor: um saldo negativo com valor zero é dos mais graves,
porque significa que o item nunca teve entrada.

Os limiares constam do papel de trabalho.

---

## 5. Examinar o estoque

Tela **Estoque**. Escolha a data e o sistema apura a posição percorrendo os
movimentos até ali, com custo médio ponderado móvel. Saídas baixam pelo custo
vigente, nunca pelo valor da nota de venda.

**Filtros** combinam entre si: data, busca por descrição, código ou NCM, filial,
situação e ordenação. O seletor de situação separa saldo negativo, mercadoria em
poder de terceiros e mercadoria em seu poder.

O cartão **Saldo negativo** também funciona como botão: clicar filtra, clicar de
novo limpa.

**Clique em qualquer linha** para abrir a ficha do item: saldo, custo médio,
valor, entradas, saídas, e o histórico movimento a movimento com documento,
contraparte, CFOP e saldo corrido. É onde se vê em que data exata o saldo furou.

Cada filial tem cor própria — índigo para SP, teal para CE, magenta para SC.

---

## 6. Levantar e tratar os achados

Tela **Achados**, ou pelo terminal.

### Executar as regras

```bash
python -m auditoria varrer 2023-01-11
```

A varredura **concilia** com o que já existe: cria os novos, atualiza os que
persistem, marca como resolvidos os que sumiram. Nunca apaga, e nunca reabre um
achado que você já tratou.

Varrer uma data antiga não resolve achado de período posterior.

### As dez famílias de achado

| Família | Severidade | O que aponta |
|---|---|---|
| Divergência de valoração | crítico | Item inventariado por custo distante do documentado |
| Emitida e não escriturada | crítico | NF-e autorizada ausente da escrituração |
| Transferência divergente | crítico | Mesma nota com totais diferentes nas duas filiais |
| Saldo negativo | alto / médio | Saldo abaixo de zero na data |
| Em poder de terceiros | alto | Mercadoria própria com terceiro |
| CFOP sem classificação | alto | Bloqueia a geração do movimento |
| Nota sem XML | alto | Escriturada sem o documento para confrontar |
| Item sem correspondência | médio | Código do fornecedor ainda sem de-para |
| Sem detalhe por item | informativo | Escrituração sem C170 |
| Ressalva assumida | informativo | Limitação decidida por você |

### Ciclo de vida

```
aberto → em análise → respondido → aceito
                                 → refutado
```

Cada mudança pede uma nota:

| Transição | O que registrar |
|---|---|
| **Em análise** | Que foi enviado ao cliente, quando |
| **Respondido** | A justificativa do cliente, colada |
| **Aceito** | Por que a justificativa procede |
| **Refutado** | Por que não procede |

*Aceito* e *refutado* são desfecho: não voltam atrás. Tudo fica no histórico,
com quem e quando — clique em **Histórico** no achado.

### Ler um achado

Cada um traz o **motivo** em texto corrido, pronto para o papel de trabalho, e a
**prova**: o registro, a linha do arquivo e o hash do EFD.

Exemplo real:

> O inventário declara 102 UN a R$ 310,50 cada (registro H010, linha 1231 do
> arquivo). No mesmo arquivo, o registro C170 da nota de entrada de 07/02/2023
> traz o mesmo item por R$ 8.740,93 a unidade, CFOP 2152 — 28 vezes mais. Os
> dois valores vêm do próprio EFD; não há erro de importação.

### Distorção e valor a confirmar são coisas diferentes

O painel separa os dois, e a distinção importa:

- **Distorção potencial** — valoração e entradas pendentes. É o que pode estar
  errado no valor do estoque.
- **A confirmar com terceiros** — mercadoria própria em poder de outro. Não é
  distorção: é posse a comprovar junto ao depositário.

---

## 7. Emitir o papel de trabalho

Tela **Relatório**. Escolha a data, clique em **Montar**.

O documento sai com quatro seções: sumário, achados agrupados por família,
arquivos que sustentam o relatório com SHA-256, e metodologia com limitações.
No fim, linha para assinatura.

**Imprimir / Salvar PDF** usa o diálogo do navegador. O CSS de impressão esconde
a navegação e evita quebrar um achado no meio da página.

**Baixar CSV** exporta com BOM e ponto e vírgula — o Excel brasileiro abre
direto, sem remontar colunas.

---

## 8. Perguntas frequentes

**Preciso instalar alguma coisa?**
Não, para o uso normal. Só para importar uma pasta inteira de arquivos, que
exige o servidor local.

**O saldo mudou de uma consulta para outra.**
Confira a data selecionada. A posição é apurada até aquela data; qualquer
movimento posterior não entra.

**Aparecem itens sem descrição.**
São produtos criados depois do saldo de abertura, que não existem no cadastro
`0200` do EFD carregado. O sistema busca a descrição na própria NF-e e marca a
origem na coluna *Cadastro*. Se aparecer "sem cadastro", o item não existe em
nenhuma fonte.

**Um item aparece negativo mas eu sei que tem estoque.**
Saldo negativo quase sempre é entrada faltando, não estoque inexistente: a saída
foi escriturada e a compra correspondente não. Confira se as notas de entrada do
período foram importadas e se algum CFOP ficou sem classificação.

**Importei um arquivo e nada mudou.**
Provavelmente já estava importado. O sistema identifica pelo conteúdo, não pelo
nome: um arquivo renomeado continua sendo o mesmo. A tela mostra *já estava*.

**"Importar pasta" não funciona no site publicado.**
Correto. Aquele servidor não tem acesso ao seu disco. Arraste os arquivos, ou
use o servidor local para lotes grandes.

**O painel diz que não consegue ler o banco.**
No plano gratuito, o projeto Supabase pausa por inatividade. Abra o painel do
Supabase para religá-lo e recarregue. O serviço também apresenta instabilidade
ocasional — se a mensagem falar em *bad gateway*, tente de novo em um minuto.

**Mudei um arquivo do sistema e nada mudou.**
Rodando local, o servidor recarrega sozinho, mas o navegador guarda CSS e
JavaScript em cache. **Ctrl+F5**.

---

## 9. O que o sistema ainda não faz

Saber o limite é parte do trabalho.

- **Custo de importação.** II, IPI, frete internacional, seguro e despesas
  aduaneiras vêm da DI/DUIMP, que ainda não são lidas. Enquanto isso, mercadoria
  importada entra pelo valor da nota — sistematicamente por baixo.
- **Conciliação item a item entre EFD e XML.** O motor existe, mas depende de as
  duas fontes cobrirem os mesmos períodos. Hoje quase não há sobreposição, e o
  sistema aponta isso como achado.
- **Bloco K.** Produção e estoque escriturado para indústria. Os arquivos atuais
  são de comércio e trazem esses registros vazios.
- **Corte de período e sequência de numeração.** Exigem escrituração contínua de
  um exercício inteiro para significar alguma coisa.
- **Amostragem estatística.** Com poucas centenas de itens você testa todos. Faz
  sentido quando o universo crescer.
