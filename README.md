# Clubeira

Backend de um SaaS multi-tenant para clubes de vouchers por assinatura. Um
único produto atende vários polos independentes — cidades, regiões ou
franquias — e o mesmo usuário pode manter contratos, ciclos e benefícios
separados em cada um deles.

O projeto segue uma arquitetura de monólito modular em Elixir/Phoenix, com
PostgreSQL, domínio normalizado e isolamento por Row-Level Security (RLS).

## O que já funciona

- diretório e catálogo públicos, cadastro atômico com aceite da versão legal
  vigente, autenticação por sessão bearer revogável, descoberta de assinaturas
  multi-polo e carteira de vouchers;
- descoberta pública paginada das opções comerciais e preços aceitos pelo
  checkout do polo;
- planos, contratos, ciclos e alocações de benefício independentes por polo;
- checkout, histórico paginado de pedidos e pagamento Pix via Mercado Pago,
  com criação autenticada, retry idempotente e webhook HMAC que relê a order
  no provedor antes de liquidar;
- contas de recebimento globais vinculadas explicitamente a cada polo, com
  vigência e integridade referencial entre tenant e conta;
- enrollment de instalação sem persistir o segredo, grant de resgate assinado e
  curto, autenticação do ponto de validação e resgate online atômico, com
  proteção contra replay, ledger, auditoria, eventos de domínio e outbox;
- submissão autenticada e idempotente de avaliações verificadas por resgate,
  com revisão inicial imutável e moderação pendente;
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
seguro. A primeira borda real de PSP usa a Orders API do Mercado Pago para Pix;
payload bruto termina no adaptador e o core recebe somente uma captura
normalizada depois da assinatura e do estado remoto serem verificados. Cartão,
reembolso e chargeback continuam fatias separadas. A API online de resgate já
entrega o grant que um cliente pode renderizar como QR; placard estático,
operação offline e o componente visual de leitura continuam bordas próprias.

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
- parceiros do polo: <http://localhost:4000/api/v1/polos/sobral/places>
- opções de checkout: <http://localhost:4000/api/v1/polos/sobral/checkout-options>
- LiveDashboard em desenvolvimento: <http://localhost:4000/dev/dashboard>
- caixa de e-mail local: <http://localhost:4000/dev/mailbox>

As seeds criam `membro.demo@clubeira.local` com a senha local
`clubeira-demo-local`. Defina `CLUBEIRA_DEMO_PASSWORD` antes de `mix setup` para
trocar esse valor. Sobral também recebe um ponto de validação cuja chave local
de demonstração é `M-bCcLGupP8XuBxzemHd-4JumJf6trsiQpinEl30xwg`; substitua-a
por 32 bytes aleatórios em base64url sem padding via
`CLUBEIRA_DEMO_VALIDATION_SECRET` em qualquer ambiente compartilhado. Para
testar o sandbox Pix, defina também
`CLUBEIRA_DEMO_EMAIL` com o e-mail do usuário de teste do Mercado Pago antes de
rodar as seeds. O mesmo membro possui contratos independentes em Sobral e
Londrina.

```sh
curl -sS 'http://localhost:4000/api/v1/legal/registration?locale=pt-BR'

curl -sS -X POST http://localhost:4000/api/v1/auth/registrations \
  -H 'content-type: application/json' \
  -d '{"email":"novo@example.test","password":"uma-senha-com-15-chars","legal_document_version_ids":["<legal_version_uuid>"]}'

curl -sS http://localhost:4000/api/v1/auth/sessions \
  -H 'content-type: application/json' \
  -d '{"email":"membro.demo@clubeira.local","password":"clubeira-demo-local"}'

curl -sS http://localhost:4000/api/v1/me/subscriptions \
  -H "authorization: Bearer $TOKEN"

curl -sS http://localhost:4000/api/v1/polos/sobral/me/vouchers \
  -H "authorization: Bearer $TOKEN"

INSTALLATION_TOKEN="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"

curl -sS -X POST http://localhost:4000/api/v1/polos/sobral/me/redemption-devices \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"access_contract_id\":\"<contract_uuid>\",\"installation_token\":\"$INSTALLATION_TOKEN\",\"platform\":\"web\"}"

curl -sS -X POST http://localhost:4000/api/v1/polos/sobral/me/redemption-grants \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"entitlement_allocation_id\":\"<allocation_uuid>\",\"installation_token\":\"$INSTALLATION_TOKEN\"}"

curl -sS -X POST http://localhost:4000/api/v1/polos/sobral/redemptions \
  -H 'authorization: Validation M-bCcLGupP8XuBxzemHd-4JumJf6trsiQpinEl30xwg' \
  -H 'idempotency-key: merchant-redemption-001' \
  -H 'content-type: application/json' \
  -d '{"grant":"<signed_grant>"}'

curl -sS http://localhost:4000/api/v1/polos/sobral/checkout-options

curl -sS http://localhost:4000/api/v1/polos/sobral/places

curl -sS -X POST http://localhost:4000/api/v1/polos/sobral/orders \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -H 'idempotency-key: checkout-mobile-001' \
  -d '{"product_offering_version_id":"<uuid>","offering_price_id":"<uuid>"}'

curl -sS -X POST \
  http://localhost:4000/api/v1/polos/sobral/orders/<order_uuid>/payment-intents \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -H 'idempotency-key: payment-mobile-001' \
  -d '{"payment_method":"pix"}'

curl -sS http://localhost:4000/api/v1/polos/sobral/me/orders \
  -H "authorization: Bearer $TOKEN"

curl -sS http://localhost:4000/api/v1/polos/sobral/me/redemptions \
  -H "authorization: Bearer $TOKEN"

curl -sS -X POST http://localhost:4000/api/v1/polos/sobral/places/<place_uuid>/reviews \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -H 'idempotency-key: review-mobile-001' \
  -d '{"source_redemption_id":"<redemption_uuid>","rating":5,"title":"Muito bom","body":"Benefício entregue como anunciado."}'
```

O comando de login devolve `data.access_token`; atribua-o a `TOKEN` apenas na
sessão do shell. `DELETE /api/v1/auth/session` revoga a sessão atual. A listagem
de assinaturas também usa cursor: `?limit=20&after=...`, com limite máximo de
`100` polos e metadados em `meta.page`. O checkout exige uma única chave
`Idempotency-Key`, aceita somente uma unidade e deriva comprador, polo, moeda e
preço novamente no servidor. `GET /api/v1/polos/:slug/checkout-options`
publica as combinações de `product_offering_version_id` e `offering_price_id`
atualmente provisionáveis, também com cursor e limite máximo de `100`. Repetir
a mesma seleção com a mesma chave devolve o pedido original; reutilizar a chave
para outra seleção retorna conflito.

O enrollment aceita apenas um segredo de instalação gerado com 32 bytes
aleatórios e persiste seu SHA-256. Usuário, polo e contrato são relidos da
sessão e do banco; o limite de dispositivos vem da versão de policy congelada
no contrato. O grant dura 120 segundos por padrão, vincula polo, ator,
alocação, instalação e nonce, e não aceita IDs de ponto de validação do
cliente. A confirmação deriva esse ponto de uma credencial ativa, executa a
autenticação e `Clubeira.Redemptions.confirm/2` na mesma transação e mantém o
replay idempotente.

O início do pagamento aceita hoje somente `pix`. A resposta contém uma ação
normalizada com `redirect_url` e `copy_paste_code`; repetir a mesma chave
devolve o mesmo intent sem criar outra order no PSP. Timeout ambíguo reutiliza
o UUID interno do intent como `X-Idempotency-Key` no Mercado Pago. O webhook
assinado relê `GET /v1/orders/:id`, provisiona contrato, ciclo e vouchers apenas
para uma captura `processed/accredited`, fecha intents expirados e reconcilia
notificações repetidas sem duplicar pagamento ou direito.

O histórico de pedidos retorna somente os pedidos do ator naquele polo, do
mais novo para o mais antigo, com os itens e valores históricos; ele usa
`?limit=20&after=...` e limita cada página a `100` pedidos. O diretório público
usa a mesma paginação para listar somente
participações, lugares, marcas e operadores ativos, incluindo endereço e
coordenadas quando cadastradas. Após um resgate confirmado, o membro pode
enviar uma avaliação de `1` a `5` estrelas com texto não vazio. A API prova no
banco que o resgate pertence ao ator, polo e lugar da rota, cria a avaliação
como `pending` e exige `Idempotency-Key`; título é opcional e mídia fica para
uma fatia posterior. O histórico autenticado de resgates retorna o `id` usado
como `source_redemption_id`, a identidade do lugar e a versão histórica do
benefício; quando o lugar já foi avaliado, inclui também o aggregate de review.

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

Autenticação é global: `POST /api/v1/auth/registrations` valida e normaliza o
email, exige todas as versões de termos vigentes publicadas por
`GET /api/v1/legal/registration`, e cria usuário ativo, aceite imutável, hash
Argon2id, sessão e auditoria na mesma transação.
`user_password_credentials` separa o segredo da identidade e `user_sessions`
persiste somente SHA-256 do bearer opaco. Cadastro e login têm limites locais
por instância para tráfego global, IP e identidade, além de um teto fail-fast
para operações Argon2 concorrentes. Um limitador no ingress continua
obrigatório para impor o teto do cluster. Sessões expiradas ou revogadas são
removidas após a retenção configurada, 30 dias por padrão.

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

- `POST /api/v1/auth/registrations` cria atomicamente a conta e uma sessão
  utilizável no checkout depois do aceite legal exato; verificação de email,
  recuperação de senha e blocklist local de senhas comprometidas ainda são
  bordas próprias;
- `POST /api/v1/polos/:polo_slug/orders` expõe o checkout autenticado e delega
  para `Clubeira.Billing.place_order/2`;
- `POST /api/v1/polos/:polo_slug/orders/:order_id/payment-intents` inicia Pix
  somente para o comprador autenticado e exige `Idempotency-Key`;
- `POST /api/v1/webhooks/mercado-pago/:merchant_account_id` autentica a
  assinatura do tópico Order e confirma o estado pela API do provedor;
- `GET /api/v1/polos/:polo_slug/me/orders` lista somente os pedidos do membro
  autenticado no polo, com paginação keyset e itens históricos;
- `GET /api/v1/polos/:polo_slug/checkout-options` expõe versões comerciais e
  preços vigentes; a escrita continua relendo preço, moeda e elegibilidade
  dentro da transação;
- `GET /api/v1/polos/:polo_slug/places` lista a identidade comercial pública
  dos parceiros ativos do polo; desativação os remove da descoberta sem apagar
  referências históricas;
- `POST /api/v1/polos/:polo_slug/places/:place_id/reviews` cria uma avaliação
  verificada para o membro autenticado; o resgate informado é somente evidência
  e sua autoria, polo e lugar são revalidados sob RLS;
- `GET /api/v1/polos/:polo_slug/me/redemptions` pagina somente os resgates
  bem-sucedidos do membro no polo e expõe o vínculo com sua avaliação do lugar;
- `POST /api/v1/polos/:polo_slug/me/redemption-devices` autoriza uma instalação
  para o contrato sem confiar em `device_id` externo;
- `POST /api/v1/polos/:polo_slug/me/redemption-grants` emite a autorização
  assinada e curta do membro; `POST /api/v1/polos/:polo_slug/redemptions`
  autentica o ponto de validação e consome o nonce sob idempotência;
- `Clubeira.Billing.settle_payment/2` continua sendo a porta interna e só
  aceita a captura normalizada pelo adaptador autenticado;
- `Clubeira.Redemptions.confirm/2` permanece a porta interna já autenticada; a
  borda HTTP acima verifica grant e credencial antes de montar esse comando;
- a outbox é persistida atomicamente, mas o publicador assíncrono ainda será uma
  fatia própria;
- publicação/moderação, edição, mídia, respostas e denúncias de avaliações
  continuam como fatias próprias;
- renovação automática, reembolso e chargeback ainda não fazem parte do fluxo
  operacional.

## Documentação

- [Arquitetura](docs/architecture.md)
- [Desenvolvimento](docs/development.md)
