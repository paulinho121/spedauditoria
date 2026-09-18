# Manual do usuário — Fiscal Stock

Este manual segue a ordem de um trabalho real: acessar, escolher a auditoria,
carregar, definir o ponto de partida e o critério, examinar, tratar os achados e
emitir o papel de trabalho.

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

## 2. Escolher o trabalho

No alto de toda tela, ao lado do menu, aparece o **trabalho em uso**. Um
trabalho é uma auditoria: um cliente, um exercício. Tudo o que você vê — o
estoque, os achados, o relatório — é daquele trabalho e de mais nenhum.

Clique no nome para abrir a lista. Ali você troca de auditoria, abre uma nova ou
apaga uma antiga.

### Começar uma auditoria nova

Clique no trabalho em uso, preencha **nome**, **cliente** e **exercício** e
confirme em *Criar e usar*. O sistema já leva você para a tela de importação,
com o novo trabalho vazio esperando os arquivos.

Não é preciso apagar nada para começar. O trabalho anterior fica onde está, com
os arquivos, os movimentos, os achados e o histórico de cada um. Você volta a
ele quando quiser, clicando em *Usar este*.

Isso importa mais do que parece: se o cliente contestar um achado seis meses
depois, você precisa poder abrir a auditoria daquela época exatamente como ela
estava. Prova descartada é prova que nunca existiu.

### Trocar de auditoria

Na lista, *Usar este*. A página recarrega e todos os números passam a ser do
trabalho escolhido.

Uma consequência que vale ter em mente: **o mesmo arquivo pode ser importado em
dois trabalhos diferentes**. Dentro de um trabalho o sistema continua recusando
o arquivo repetido, pelo hash. Entre trabalhos, não — são auditorias distintas.

### Apagar uma auditoria

Na lista, *Excluir*. O sistema mostra o tamanho do que vai embora — arquivos,
notas, movimentos, achados — e pede que você **digite o nome do trabalho**. Não
é implicância: um "tem certeza?" não impede o clique errado, digitar o nome
impede.

Some tudo, sem desfazer. E o último trabalho não pode ser apagado — sem trabalho
em uso, todas as telas ficariam em branco.

### Materialidade do trabalho novo

Um trabalho recém-criado nasce com os limiares **zerados**, o que significa que
nenhum achado é descartado por ser pequeno. É de propósito: sem inventário
carregado, o sistema não tem como saber o que é pequeno, e listar demais é o
erro barato. Depois de importar e congelar o saldo de abertura, defina os
limiares como descrito na seção 5.

### Pela linha de comando

```bash
python -m auditoria trabalhos                 lista, com › no que está em uso
python -m auditoria trabalho novo "ACME 2023" "ACME LTDA" 2023
python -m auditoria trabalho usar 2
python -m auditoria trabalho excluir 2
```

---

## 3. Carregar os arquivos

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

A mesma nota costuma existir em arquivos diferentes — cada sistema exporta com
um envelope ou uma formatação. O sistema compara a **nota**, campo a campo, e
não o arquivo: mesma nota em outro arquivo aparece como *já importada*. Só
**conflito** quando algum dado fiscal difere de fato (valor, quantidade, item,
CFOP) — e aí vale investigar, porque uma NF-e autorizada não muda.

**Confira o fim do log.** O navegador envia os arquivos em lotes de 40. Se um
lote falha, ele tenta de novo algumas vezes; se ainda assim não conseguir, a
última linha diz **quantos e quais arquivos não foram importados**. Nesse caso
basta enviar a mesma seleção de novo — o que já entrou é reconhecido e pulado.

Para pastas grandes, o botão *Importar pasta* (só no servidor local) é mais
seguro que arrastar: lê direto do disco, sem passar pelo navegador.

### Notas canceladas

O sistema emissor costuma exportar a nota cancelada só como **evento**, num
arquivo `-can.xml`, sem o XML original. Importe esses arquivos junto com os
demais: o sistema os reconhece.

- Se a nota já estiver no sistema, ela passa a **cancelada** e os movimentos
  dela saem do estoque.
- Se ainda não estiver, o cancelamento fica guardado, e a nota **já entra
  cancelada** quando for importada.

Vale a resposta da SEFAZ gravada no arquivo, não o pedido: um pedido de
cancelamento recusado não cancela nada. A nota e o evento continuam no sistema
como prova, com arquivo e protocolo.

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

## 4. Definir o saldo de abertura

O saldo de abertura é o ponto zero do Kardex, e é **imutável**.

```bash
python -m auditoria congelar 2022-12-31
```

Congela o inventário daquela data como abertura. Rodar de novo não altera nada.

Uma vez congelado, o banco passa a proteger os arquivos que o originaram: não é
possível apagá-los enquanto o saldo de abertura os referenciar.

---

## 5. Definir a materialidade

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

## 6. Examinar o estoque

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

### Reconstruir um mês do zero

Tela **Mês**. Responde a outra pergunta: *o que este mês fez com o estoque?*
Todo item começa em **zero**, entram apenas as notas do mês, e o que sobra no
fim é o saldo. Nenhum saldo de abertura participa.

Serve quando não há inventário confiável para ancorar a reconstrução — ou
quando ele existe e você quer justamente conferi-lo contra o movimento, sem que
o próprio inventário entre na conta.

Escolha o mês no seletor. Os botões abaixo mostram os meses que têm notas, com
a quantidade de movimentos, para você não ter de adivinhar onde há o que ver.

A tabela traz, por item: quanto **entrou**, quanto **saiu**, o **saldo no fim
do mês**, o custo médio e o valor. Clicar numa linha leva à ficha completa do
item na tela Estoque, que mostra também o que veio antes do mês — é lá que se
explica um saldo negativo.

**Duas leituras mudam por causa do zero inicial, e vale ter isto claro:**

- **Saldo negativo aqui é esperado, não é achado.** Item vendido no mês e
  comprado antes dele começa em zero e termina negativo. Isso é exatamente o
  que a tela revela: quanto o mês consumiu de estoque anterior.
- **Saída sem entrada no período não tem custo em que se apoiar.** O custo não
  é zero — é desconhecido. Esses itens vêm marcados *sem custo* e a valoração
  do mês não os inclui.

Nada desta tela alimenta o motor de achados, justamente por isso.

### Quando o mês aparece só com saídas

Quase nunca é o sistema errando: é nota que foi importada e **não chegou ao
estoque**. O painel *Notas do mês que não chegaram ao estoque* mostra quantas
linhas pararam e por quê:

| Motivo | O que significa |
|---|---|
| **Item sem correspondência** | O código do produto na nota é do fornecedor e ainda não foi ligado a um item seu |
| **CFOP sem classificação** | O sistema não sabe o efeito daquele CFOP no estoque |
| **Nota não autorizada** | Cancelada ou denegada — não existe para o estoque |

As duas primeiras dependem de uma decisão sua, e o valor delas aparece no
painel. A tela Importar lista os itens sem correspondência e sugere candidatos
do cadastro, mas **ainda não tem como confirmar o de-para** — isso está por
fazer.

### Item que não está no cadastro 0200

O cadastro 0200 do EFD só conhece os itens que existiam quando o arquivo foi
gerado. Item criado depois ganha cadastro **automaticamente, a partir do XML**:
descrição, NCM, CEST, código de barras e unidade da nota em que ele aparece.
Acontece no momento em que o item ganha o primeiro movimento, qualquer que seja
o caminho da importação.

Quando o item aparece em várias notas, vale a que a própria filial emitiu — é a
descrição dela — e, entre essas, a mais antiga. A escolha sai dos dados, não da
ordem em que os arquivos foram importados.

Esse cadastro fica **separado** do 0200 e nunca o substitui: quando o item
existe no 0200, o 0200 vence. Na tela, o item cadastrado pelo XML vem marcado
*cadastro pelo XML* (ou *XML*, na tela Estoque), para não ser confundido com
o que a empresa declarou.

### Transferência entre filiais

Uma nota de transferência gera dois lançamentos: a **saída** em quem emitiu e a
**entrada** em quem recebeu. O CFOP da nota é o do emitente (6152 é
"transferência de saída"); para quem recebe, o sistema aplica o efeito
espelhado — o que saiu de uma filial entrou na outra.

O código do produto é aceito automaticamente de uma filial para a outra, porque
o grupo usa o mesmo cadastro na maior parte dos itens. A exceção é quando o
mesmo código é **produto diferente** em cada filial — acontece: o 4083 é tubo de
LED em SC e luminária em SP. O sistema compara as descrições e, se não
conferem, manda o item para o de-para manual em vez de somar um produto na
conta do outro.

Cada casamento automático fica registrado com o motivo — "código novo no
destino" ou "descrição confere", com o grau de semelhança — para poder ser
revisto.

Remessa entre filiais (conserto, demonstração, armazém) não gera entrada no
destino: a mercadoria troca de mão sem trocar de dono, e a saída já registra a
mudança de posse.

O sistema recusa gerar o movimento nesses casos de propósito. Um Kardex com
furo visível é auditável; um com número adivinhado, não.

Há ainda um caso que nenhum painel resolve: **as notas de entrada podem
simplesmente não estar no lote**. O arquivo XML que a empresa exporta costuma
conter apenas o que ela **emitiu** — as compras são documentos de terceiros e
precisam ser obtidas à parte, na distribuição de DF-e da SEFAZ. Se o painel de
bloqueios estiver limpo e ainda assim faltarem entradas, é por aí.

O custeio é o mesmo do resto do sistema: média ponderada móvel, saída baixando
pelo custo. Um método diferente só nesta tela criaria dois números para a mesma
mercadoria.

---

## 7. Levantar e tratar os achados

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

## 8. Emitir o papel de trabalho

Tela **Relatório**. Escolha a data, clique em **Montar**.

O documento sai com quatro seções: sumário, achados agrupados por família,
arquivos que sustentam o relatório com SHA-256, e metodologia com limitações.
No fim, linha para assinatura.

**Imprimir / Salvar PDF** usa o diálogo do navegador. O CSS de impressão esconde
a navegação e evita quebrar um achado no meio da página.

**Baixar CSV** exporta com BOM e ponto e vírgula — o Excel brasileiro abre
direto, sem remontar colunas.

---

## 9. Perguntas frequentes

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

**Vou auditar outra empresa. Preciso apagar o que já está aqui?**
Não. Abra um trabalho novo (seção 2) e importe os arquivos dela ali. As duas
auditorias convivem, cada uma com os seus dados, e você alterna entre elas pelo
seletor no alto da tela. Apagar só faz sentido quando a auditoria antiga já não
tem valor nenhum como prova.

**Importei os arquivos e o trabalho continua vazio.**
Confira qual trabalho estava em uso na hora da importação — os dados entram no
trabalho ativo. Troque para ele pelo seletor no alto da tela.

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

## 10. O que o sistema ainda não faz

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
