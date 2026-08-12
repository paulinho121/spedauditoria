# Manual do usuário — Fiscal Stock

Este manual segue a ordem de um trabalho real: preparar, carregar, definir o
critério, examinar, tratar os achados e emitir o papel de trabalho.

---

## 1. Antes de começar

### Ligar o sistema

```bash
python C:\Users\Acer\Desktop\fiscal\app\server.py
```

Abre em `http://localhost:8777`. Entre com seu e-mail e senha do Supabase Auth.

O servidor recarrega sozinho quando o código muda. Se a interface parecer
antiga, é cache do navegador — **Ctrl+F5** resolve.

### Conferir a configuração

```bash
python -m auditoria config
```

Se aparecer `backend: Management API (degradado)`, o sistema está funcionando
mas devagar (cerca de 1,4 s por consulta). Preencha `DATABASE_URL` no `.env`
para cair para milissegundos.

---

## 2. Carregar os arquivos

### Conferir antes de importar

Sempre vale rodar primeiro. Nada é gravado:

```bash
python -m auditoria conferir "C:\caminho\*.txt"
```

Mostra CNPJ, período, perfil, quantidade de registros e os problemas
encontrados — inclusive quanto do movimento tem detalhe por item, que determina
o que vai ser possível apurar.

### Importar

```bash
python -m auditoria importar "C:\caminho\*.txt"      # EFD
python -m auditoria importar "C:\caminho\*.xml"      # NF-e
```

Ou pela tela **Importar**: arraste os arquivos, ou informe uma pasta e o
servidor varre recursivamente. Para lotes grandes prefira a pasta — o navegador
engasga com milhares de arquivos.

**A importação é idempotente.** O sistema calcula o SHA-256 de cada arquivo;
reimportar o mesmo conteúdo não faz nada. Um arquivo retificador não sobrescreve
o anterior: entra como nova versão e marca a anterior como não vigente,
preservando o histórico.

### O que observar depois de importar

Na tela **Importar**, dois cartões travam o trabalho se estiverem acima de zero:

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

Congela o inventário daquela data como abertura. Rodar de novo não altera nada —
se precisar refazer, é decisão consciente e exige limpar a tabela.

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

O corte de trivialidade só vale para achado de natureza monetária. Falha
estrutural — saldo negativo, CFOP aberto, nota sem documento — aparece sempre,
por menor que seja o valor. Um saldo negativo com valor zero é dos mais graves:
significa que o item nunca teve entrada.

Os limiares constam do papel de trabalho.

---

## 5. Examinar o estoque

Tela **Estoque**. Escolha a data e o sistema apura a posição percorrendo os
movimentos até ali.

**Filtros** combinam entre si: data, busca por descrição, código ou NCM, filial,
situação e ordenação.

O seletor de situação tem quatro opções:

- Todos os itens
- Somente saldo negativo
- Somente em poder de terceiros
- Somente em seu poder

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

**A tela publicada não deixa importar.**
Correto. A versão no Vercel só consulta — importação exige ler arquivos do seu
computador e leva minutos, o que serverless não permite. Use o servidor local.

**O painel diz que não consegue ler o banco.**
No plano gratuito, o projeto Supabase pausa por inatividade. Abra o painel do
Supabase para religá-lo e recarregue.

**Mudei um arquivo `.py` e nada mudou.**
O servidor local recarrega sozinho, mas o navegador guarda CSS e JavaScript em
cache. **Ctrl+F5**.

---

## 9. O que o sistema ainda não faz

Saber o limite é parte do trabalho.

- **Custo de importação.** II, IPI, frete internacional, seguro e despesas
  aduaneiras vêm da DI/DUIMP, que ainda não são lidas. Enquanto isso, mercadoria
  importada entra pelo valor da nota — sistematicamente por baixo.
- **Bloco K.** Produção e estoque escriturado para indústria. Os arquivos atuais
  são de comércio e trazem esses registros vazios.
- **Corte de período e sequência de numeração.** Exigem escrituração contínua de
  um exercício inteiro para significar alguma coisa.
- **Amostragem estatística.** Com poucas centenas de itens você testa todos. Faz
  sentido quando o universo crescer.
