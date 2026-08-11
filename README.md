# Auditoria Fiscal de Estoque

Ferramenta de auditoria de estoque a partir de arquivos SPED EFD ICMS/IPI e XML
de NF-e. Reconstitui o inventário, monta o Kardex mês a mês e aponta divergências
com trilha de evidência até a linha do arquivo de origem.

## O que faz hoje

- Importa EFD ICMS/IPI (registros `0000`, `0150`, `0190`, `0200`, `H005`, `H010`,
  `C100`, `C170`) de forma idempotente, com SHA-256 e versionamento de
  retificadoras.
- Importa NF-e (modelo 55/65), classifica cada CFOP pelo efeito no estoque e
  gera as linhas de movimento do Kardex.
- Congela um saldo de abertura imutável (o "momento zero").
- Confronta o custo inventariado com o custo real de entrada e aponta
  divergências de valoração.
- Painel web local para consulta e importação.

## Princípios

**Na dúvida, não inventa.** CFOP não classificado bloqueia o movimento; item que
não casou vai para uma fila de resolução. Um Kardex com furo visível é auditável;
um com número adivinhado, não.

**A prova é imutável e atribuível.** Nada é apagado. Toda linha guarda o arquivo
de origem, seu hash e a linha física de onde veio.

**Reprodutível.** Migrações versionadas com detecção de alteração, versão do
motor registrada em cada importação, testes golden sobre arquivos reais.

## Instalação

```bash
git clone <este-repositorio>
cd fiscal
pip install "psycopg[binary,pool]"
cp .env.example .env      # preencha DATABASE_URL
python -m auditoria migrar
```

## Uso

```bash
python -m auditoria config                    # diagnóstico da configuração
python -m auditoria migrar                    # aplica migrações pendentes
python -m auditoria conferir <arquivos>       # valida sem gravar
python -m auditoria importar <arquivos>       # importa EFD (idempotente)
python -m auditoria congelar 2022-12-31       # define o saldo de abertura
python -m auditoria status                    # o que está no banco
python -m auditoria ressalvas                 # limitações assumidas
```

Painel web:

```bash
python app/server.py
```

Abre em `http://localhost:8777`. Três telas: dashboard, reconstrução do
inventário e importação de XML.

## Testes

```bash
python -m tests.test_sped
```

Os testes golden guardam apenas contagens, totais e hashes — nunca os dados
fiscais. Para regerar após uma mudança intencional no parser:

```bash
python -m tests.test_sped --gerar
```

## Estrutura

```
auditoria/     pacote principal
  config.py    carrega .env
  db.py        acesso ao Postgres (psycopg) com fallback pela Management API
  sped.py      parser de EFD — funções puras, sem I/O de banco
  nfe.py       parser de NF-e — XML com namespace
  carga.py     importação idempotente de EFD
  carga_nfe.py importação de NF-e e geração de movimento
  migra.py     aplicador de migrações com detecção de drift
  cli.py       linha de comando
migrations/    SQL numerado, aplicado uma vez, hash conferido
app/           painel web (servidor stdlib + HTML/CSS/JS sem dependências)
tests/         testes do parser e golden files
```

## Segurança

- `.env` nunca vai para o repositório.
- Arquivos EFD, XML e planilhas com dados de cliente são ignorados pelo git.
- O painel escuta apenas em `127.0.0.1` e não tem autenticação — **não exponha
  na internet sem colocar autenticação na frente.**
- O token de administração do Supabase dá acesso a toda a conta. Prefira
  `DATABASE_URL`, que é escopado ao banco.

## Limitações conhecidas

- Perfil B não obriga o registro `C170`. Sem ele não há Kardex por item a partir
  do EFD; é preciso recorrer aos XML. A importação avisa a cobertura encontrada.
- O saldo de abertura em 31/12/2022 foi congelado como declarado, com ressalva
  registrada de divergência de valoração não ajustada.
- Custo de importação (II, IPI, frete, seguro, despesas aduaneiras) vem da
  DI/DUIMP, ainda não implementadas.
