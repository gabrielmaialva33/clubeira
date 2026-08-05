# Clubeira

Backend de um SaaS multi-tenant para clubes de vouchers por assinatura. Um
único produto atende vários polos independentes — cidades, regiões ou
franquias — e o mesmo usuário pode manter contratos, ciclos e benefícios
separados em cada um deles.

O projeto segue uma arquitetura de monólito modular em Elixir/Phoenix, com
PostgreSQL, domínio normalizado e isolamento por Row-Level Security (RLS).

## O que já funciona

- catálogo público, autenticação por sessão bearer revogável, descoberta de
  assinaturas multi-polo e carteira de vouchers;
- descoberta pública paginada das opções comerciais e preços aceitos pelo
  checkout do polo;
- planos, contratos, ciclos e alocações de benefício independentes por polo;
- checkout e liquidação de pagamento transacionais, idempotentes e neutros em
  relação ao provedor;
- contas de recebimento globais vinculadas explicitamente a cada polo, com
  vigência e integridade referencial entre tenant e conta;
- resgate online atômico, com elegibilidade, proteção contra replay, ledger,
  auditoria, eventos de domínio e outbox;
- migrations, seeds, factories, RLS forçado e testes de concorrência contra
  bancos isolados reais.

O fluxo de venda implementado no domínio é:

```text
checkout autenticado
  -> pedido aguardando pagamento
  -> captura autenticada pelo adaptador do provedor
  -> pagamento e pedido liquidado
  -> contrato e ciclo de benefício
  -> alocações de vouchers
```

A liquidação persiste esse resultado de forma atômica e aceita reprocessamento
seguro. O adaptador HTTP/webhook do PSP e o protocolo de QR ainda são bordas a
serem implementadas; o core não recebe webhook bruto nem confia em prova não
autenticada.

## Subir o projeto

Pré-requisitos: Docker com Compose e `mise`.

```sh
mise install
mix setup
mix phx.server
```

`mix setup` instala as dependências, sobe PostgreSQL 18 em
`127.0.0.1:55432`, cria/migra o banco com a role de migration e carrega um
cenário determinístico com os polos Sobral e Londrina.

- aplicação: <http://localhost:4000>
- health check: <http://localhost:4000/health>
- catálogo demo: <http://localhost:4000/api/v1/polos/sobral/catalog>
- opções de checkout: <http://localhost:4000/api/v1/polos/sobral/checkout-options>
- LiveDashboard em desenvolvimento: <http://localhost:4000/dev/dashboard>
- caixa de e-mail local: <http://localhost:4000/dev/mailbox>

As seeds criam `membro.demo@clubeira.local` com a senha local
`clubeira-demo-local`. Defina `CLUBEIRA_DEMO_PASSWORD` antes de `mix setup` para
trocar esse valor. O mesmo membro possui contratos independentes em Sobral e
Londrina.

```sh
curl -sS http://localhost:4000/api/v1/auth/sessions \
  -H 'content-type: application/json' \
  -d '{"email":"membro.demo@clubeira.local","password":"clubeira-demo-local"}'

curl -sS http://localhost:4000/api/v1/me/subscriptions \
  -H "authorization: Bearer $TOKEN"

curl -sS http://localhost:4000/api/v1/polos/sobral/me/vouchers \
  -H "authorization: Bearer $TOKEN"

curl -sS http://localhost:4000/api/v1/polos/sobral/checkout-options

curl -sS -X POST http://localhost:4000/api/v1/polos/sobral/orders \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -H 'idempotency-key: checkout-mobile-001' \
  -d '{"product_offering_version_id":"<uuid>","offering_price_id":"<uuid>"}'
```

O primeiro comando devolve `data.access_token`; atribua-o a `TOKEN` apenas na
sessão do shell. `DELETE /api/v1/auth/session` revoga a sessão atual. A listagem
de assinaturas também usa cursor: `?limit=20&after=...`, com limite máximo de
`100` polos e metadados em `meta.page`. O checkout exige uma única chave
`Idempotency-Key`, aceita somente uma unidade e deriva comprador, polo, moeda e
preço novamente no servidor. `GET /api/v1/polos/:slug/checkout-options`
publica as combinações de `product_offering_version_id` e `offering_price_id`
atualmente provisionáveis, também com cursor e limite máximo de `100`. Repetir
a mesma seleção com a mesma chave devolve o pedido original; reutilizar a chave
para outra seleção retorna conflito.

## Banco e multi-tenancy

O banco usa um único schema PostgreSQL, compartilhado pelos polos e
normalizado. Dados tenant carregam `polo_id`; chaves estrangeiras compostas
impedem referências entre polos e todas as tabelas com `polo_id` são protegidas
por RLS forçado.

Existem credenciais locais diferentes para cada responsabilidade:

- `clubeira_migrator`: dona do schema, usada apenas por migrations e seeds;
- `clubeira_app`: role de runtime `NOSUPERUSER NOBYPASSRLS`, sem permissão de
  DDL;
- `postgres`: administração local e testes; cada teste assume uma role
  temporária restrita antes de acessar os dados.

Toda operação tenant-aware recebe `Clubeira.Tenancy.Scope` e executa dentro de
`Clubeira.Repo.transact_in_polo/3`. Sem escopo, as políticas não expõem linhas
de polo.

Autenticação é global: `user_password_credentials` separa o segredo da
identidade e usa Argon2id; `user_sessions` persiste somente SHA-256 do bearer
opaco. O login tem limites local por instância para tráfego global, IP e
identidade, além de um teto fail-fast para verificações Argon2 concorrentes. Um
limitador no ingress continua obrigatório para impor o teto do cluster. Sessões
expiradas ou revogadas são removidas após a retenção configurada, 30 dias por
padrão.

Cada requisição recebe um UUIDv7 interno em `x-request-id`, também usado para
correlacionar eventos globais de autenticação. Valores enviados pelo cliente
nesse header não viram identificadores da trilha forense. Para a tela cross-polo,
`user_contract_polo_routes` revela ao ator apenas os IDs dos polos onde ele já
contratou. Isso é um índice de roteamento, não uma autorização: contrato, ciclo
e saldo são relidos dentro da RLS de cada polo.

O endereço público de cada tenant fica na relação global 1:1 `polo_routes`.
Ela resolve apenas `slug -> polo_id`; depois disso, até a leitura pública do
catálogo entra numa transação com RLS e confirma que o polo está ativo. A
policy pública permite somente leitura das rotas; mutações continuam presas ao
`polo_id` ativo.

O catálogo aceita paginação por cursor com `?limit=20&after=...` (`20` por
padrão, máximo `100`) e devolve o próximo cursor em `meta.page.next_cursor`.
Ele publica o catálogo comercial vigente do polo; disponibilidade individual,
janelas e blackouts são regras da elegibilidade de resgate, não dessa vitrine
pública.

As contas de recebimento ficam em `merchant_accounts` e podem ser
compartilhadas entre polos. A relação normalizada `polo_merchant_accounts`
define quais contas cada polo pode usar, sua função e seu período de vigência.
Pagamentos, intents e eventos do provedor usam chaves compostas para impedir
que uma conta seja referenciada pelo tenant errado. O runtime lê apenas
vínculos vigentes do polo atual; mutações são reservadas à role dona do schema.

```sh
mix db.migrate  # sobe o container e migra com clubeira_migrator
mix db.reset    # recria o schema de desenvolvimento e reaplica as seeds
docker compose stop
```

`docker compose down` remove somente o container e a rede. O comando
`docker compose down -v` também apaga o volume e todos os dados locais.

## Qualidade

```sh
mix test
mix quality     # format, compile, Credo, audits, Sobelow e testes
mix dialyzer
mix precommit   # formata e executa o quality gate
```

A CI repete as migrations a partir de um banco vazio, testa o rollback total,
roda os gates de qualidade, compila em produção e constrói os assets.
Localmente, `CLUBEIRA_TEST_DB_POOL_SIZE` permite ajustar o pool da suíte sem
alterar a configuração versionada.

## Limites atuais

- `POST /api/v1/polos/:polo_slug/orders` expõe o checkout autenticado e delega
  para `Clubeira.Billing.place_order/2`;
- `GET /api/v1/polos/:polo_slug/checkout-options` expõe versões comerciais e
  preços vigentes; a escrita continua relendo preço, moeda e elegibilidade
  dentro da transação;
- `Clubeira.Billing.settle_payment/2` é uma porta interna e só aceita uma
  captura cuja autenticidade já foi verificada pelo futuro adaptador do PSP;
- `Clubeira.Redemptions.confirm/2` recebe uma confirmação já autenticada; token,
  QR e autenticação do ponto de validação pertencem à borda de entrada;
- a outbox é persistida atomicamente, mas o publicador assíncrono ainda será uma
  fatia própria;
- renovação automática, reembolso e chargeback ainda não fazem parte do fluxo
  operacional.

## Documentação

- [Arquitetura](docs/architecture.md)
- [Desenvolvimento](docs/development.md)
