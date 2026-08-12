# Fiscal Stock — Auditoria de Estoque

Ferramenta de auditoria de estoque a partir de arquivos SPED EFD ICMS/IPI e XML
de NF-e. Reconstitui o inventário, monta o Kardex item a item, aponta
divergências com trilha até a linha do arquivo de origem e produz papel de
trabalho.

## O que o sistema faz

**Reconstitui o estoque em qualquer data.** Percorre os movimentos em ordem
cronológica desde um saldo de abertura congelado, aplicando custo médio
ponderado móvel. Saídas baixam pelo custo vigente — nunca pelo valor da nota de
venda, que é preço e não custo.

**Monta a ficha de cada item.** Um registro por movimento, com documento,
contraparte, CFOP, entrada, saída e saldo corrido. Responde de onde veio o
saldo, quem levou a mercadoria e em que momento o saldo furou.

**Confronta as fontes.** O EFD é o que a empresa declarou; o XML é o documento
que ela emitiu. O sistema concilia os dois por chave de acesso, item a item, e
concilia também a mesma nota escriturada por duas filiais do grupo.

**Levanta achados com ciclo de vida.** Cada achado tem identidade estável,
severidade, responsável, prazo, resposta do cliente e desfecho. Reexecutar as
regras concilia com o que já existe: cria os novos, mantém os que persistem,
marca como resolvidos os que sumiram. Nunca apaga.

**Emite papel de trabalho.** Sumário, achados com motivo e prova, lista dos
arquivos-fonte com SHA-256, metodologia e limitações. Imprime em PDF e exporta
em CSV.

### Famílias de achado

| Tipo | Severidade | O que aponta |
|---|---|---|
| `valoracao` | crítico | Item inventariado por custo distante do documentado por nota |
| `nao_escriturada` | crítico | NF-e autorizada e ausente da escrituração |
| `transferencia_divergente` | crítico | Mesma nota com totais diferentes nas duas filiais |
| `saldo_negativo` | alto / médio | Saldo abaixo de zero na data da posição |
| `terceiros` | alto | Mercadoria própria em poder de terceiro |
| `cfop_aberto` | alto | CFOP sem efeito definido — bloqueia o movimento |
| `sem_documento` | alto | Nota escriturada sem o XML correspondente |
| `item_pendente` | médio | Código do fornecedor ainda sem correspondência |
| `cobertura_item` | informativo | Movimento sem detalhe por item na escrituração |
| `ressalva` | informativo | Limitação assumida pelo auditor |

## Princípios

**Na dúvida, não inventa.** CFOP não classificado bloqueia o movimento; item que
não casou vai para uma fila de resolução. Um Kardex com furo visível é
auditável; um com número adivinhado, não.

**A prova é imutável e atribuível.** Nada é apagado. Toda linha guarda o arquivo
de origem, seu hash SHA-256 e a linha física de onde veio.

**A materialidade é decisão do auditor.** Os limiares vivem no banco, em três
níveis, e constam do papel de trabalho. Falha estrutural nunca é descartada por
trivialidade — só achado de natureza monetária.

**Reprodutível.** Migrações versionadas com detecção de alteração, versão do
motor registrada em cada importação e varredura, testes golden sobre arquivos
reais.

## Instalação

```bash
git clone https://github.com/paulinho121/spedauditoria
cd spedauditoria
pip install "psycopg[binary,pool]"
cp .env.example .env      # preencha DATABASE_URL
python -m auditoria migrar
```

## Comandos

```
python -m auditoria config                    diagnóstico da configuração
python -m auditoria migrar                    aplica migrações pendentes
python -m auditoria status                    o que está no banco
python -m auditoria conferir <arquivos>       valida sem gravar
python -m auditoria importar <arquivos>       importa EFD ou NF-e (idempotente)
python -m auditoria congelar <data>           define o saldo de abertura
python -m auditoria materialidade [p e t]     mostra ou define os limiares
python -m auditoria varrer [data]             executa as regras e concilia achados
python -m auditoria achados [filtro]          lista os achados em aberto
python -m auditoria ressalvas                 limitações assumidas
```

Painel web:

```bash
python app/server.py
```

Cinco telas em `http://localhost:8777` — dashboard, estoque por data,
importação, achados e papel de trabalho. O manual de uso está em
[MANUAL.md](MANUAL.md).

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
auditoria/       pacote principal
  config.py      carrega o .env
  db.py          Postgres via psycopg, com fallback pela Management API
  auth.py        sessão contra o Supabase Auth
  sped.py        parser de EFD — funções puras, sem I/O de banco
  nfe.py         parser de NF-e — XML com namespace
  carga.py       importação idempotente de EFD
  carga_nfe.py   importação de NF-e e geração de movimento
  migra.py       aplicador de migrações com detecção de alteração
  cli.py         linha de comando
migrations/      SQL numerado, aplicado uma vez, hash conferido
app/             painel local (servidor stdlib + HTML/CSS/JS sem dependências)
api/             função serverless do Vercel — somente leitura
tests/           testes do parser e golden files
```

O painel publicado no Vercel **não importa arquivos**: importação exige disco e
minutos de execução, que serverless não oferece. Ela roda localmente, pelo CLI
ou pela tela de importação do servidor local.

## Segurança

- `.env` nunca vai para o repositório.
- Arquivos EFD, XML e planilhas com dados de cliente são ignorados pelo git.
- O token de sessão fica em cookie `HttpOnly`; o JavaScript da página nunca o vê.
- A chave `service_role` só existe no servidor e nunca chega ao navegador.
- O painel local escuta apenas em `127.0.0.1`.

## Limitações conhecidas

- Perfil B não obriga o registro `C170`, e **nenhuma saída** o traz mesmo em
  perfil A: a escrituração de saída usa o analítico `C190`. O Kardex de saída
  depende do XML. A importação avisa a cobertura encontrada.
- O saldo de abertura em 31/12/2022 foi congelado como declarado, com ressalva
  registrada de divergência de valoração não ajustada.
- Custo de importação (II, IPI, frete, seguro, despesas aduaneiras) vem da
  DI/DUIMP, ainda não implementadas.
- Bloco K (produção e estoque para indústria) não é lido — os arquivos atuais
  são de comércio e trazem os registros vazios.
