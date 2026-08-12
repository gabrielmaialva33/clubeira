# Desenvolvimento

## Toolchain

As versões ficam fixadas em `mise.toml`:

```sh
mise install
elixir --version
node --version
```

Docker Compose fornece PostgreSQL 18. A porta padrão é `55432` para não
disputar com uma instalação local. `.env.example` documenta os overrides; se
copiá-lo, exporte as variáveis antes de chamar Mix, pois apenas o Compose lê
`.env` automaticamente:

```sh
cp .env.example .env
set -a
source .env
set +a
```

## Primeiro setup

```sh
mix setup
mix phx.server
```

O alias executa, nesta ordem: dependências, container saudável, criação do
banco, migrations, seeds, instalação e validação do Redocly e build dos assets. As seeds são
determinísticas e idempotentes: representam Sobral, Londrina, uma franquia nos
dois polos, um parceiro local apenas em Sobral e um membro com assinatura e
ciclo independentes nos dois polos. Os três estabelecimentos já saem publicados
no diretório com categorias globais curadas, contato público, semana completa e
exceções de Natal e Réveillon. IDs de perfil e período são estáveis; cada rerun
substitui os filhos desse cenário dentro da transação tenant, sem acumular
horários ou categorias. A senha local padrão é
`clubeira-demo-local`; use `CLUBEIRA_DEMO_PASSWORD` para substituí-la.
As assinaturas demo passam pelos comandos reais `Billing.place_order/2` e
`Billing.settle_payment/2`: pedido, intent, pagamento, evento do provedor,
contrato, ciclo, alocações, auditoria, eventos e outbox nascem pela mesma
fronteira transacional usada pela aplicação, em vez de serem montados à mão.
As ofertas comerciais demo continuam com `renewal_policy = none` para não abrir
uma assinatura externa durante `mix setup`. O backoffice já pode publicar uma
oferta `automatic`; a jornada autenticada cria o `preapproval` e liquida cada
cobrança aprovada pelo webhook relido no PSP.
O backoffice usa `moderador.demo@clubeira.local` com a senha local
`clubeira-moderador-local`; substitua por `CLUBEIRA_DEMO_MODERATOR_EMAIL` e
`CLUBEIRA_DEMO_MODERATOR_PASSWORD` em ambientes compartilhados. Esse usuário
recebe o papel `review_moderator` nos dois polos sem qualquer bypass de RLS.
O cadastro de parceiros usa uma identidade separada:
`admin.demo@clubeira.local` com `clubeira-admin-local`, configuráveis por
`CLUBEIRA_DEMO_ADMIN_EMAIL` e `CLUBEIRA_DEMO_ADMIN_PASSWORD`. Ela recebe apenas
o role key `admin` nos mesmos polos e pode exercitar tanto o onboarding quanto a
publicação `PUT` do perfil. O acesso self-service usa
`parceiro.demo@clubeira.local` com `clubeira-parceiro-local`, configuráveis por
`CLUBEIRA_DEMO_PARTNER_EMAIL` e `CLUBEIRA_DEMO_PARTNER_PASSWORD`. Essa conta
possui role `partner_manager` somente em Sobral e vínculos vigentes com a
organização e o estabelecimento Sabores do Acaraú Demo. As organizações demo
têm CNPJs fictícios válidos e cifrados; nenhum documento real pertence às
fixtures.
As seeds também criam o provedor `mercado_pago`, uma conta global
`mercado-pago-demo` e vínculos primários com os dois polos. A saída da seed
mostra o UUID usado na URL do webhook. Sobral recebe ainda um ponto de
validação de API. Sua chave é lida de `CLUBEIRA_DEMO_VALIDATION_SECRET` e deve
ser base64url sem padding de exatamente 32 bytes; o default documentado é
somente para uso local.

Factories vivem em `support/factory.ex` e são compiladas apenas em `dev` e
`test`. Dados estruturais das seeds sempre recebem IDs e valores estáveis;
Faker fica restrito a texto de apresentação irrelevante para a regra testada.

## Painel administrativo

O painel começa em <http://localhost:4000/admin>. No cenário local, use
`admin.demo@clubeira.local` / `clubeira-admin-local` para enxergar todas as
áreas operacionais ou `moderador.demo@clubeira.local` /
`clubeira-moderador-local` para validar a navegação restrita à moderação.

O login reutiliza `Clubeira.Accounts`: o bearer opaco fica somente em cookie
cifrado, `HttpOnly`, `SameSite=Lax` e marcado como `Secure` em produção. Cada
mount autenticado relê a sessão e o acesso atual do ator; o polo selecionado na
URL precisa pertencer à projeção autorizada. A navegação usa capabilities como
hints, enquanto cada context continua reautorizando a operação sob RLS.

O dashboard é uma borda fina sobre os read models existentes de diretório,
cobrança e assinaturas. Ele não replica regra de negócio nem usa a sessão do
navegador como prova de autorização. Respostas privadas recebem
`Cache-Control: private, no-store` e a troca de polo nunca aceita um
`polo_id` arbitrário enviado pelo cliente.

O inventário em <http://localhost:4000/admin/places> exige
`manage_partners`, consulta `Directory.list_backoffice_places/2` sob RLS e
mantém polo, filtros de participação/perfil e cursor keyset na URL. O stream da
LiveView contém somente a página corrente; nenhuma query operacional fica no
módulo web.

Cada linha abre `/admin/places/:polo_place_id`, que relê a participação exata e
permite suspender, reativar ou encerrar conforme o estado. A LiveView revalida
sessão e usuário antes do submit; o context reautoriza a membership e compara a
identidade e revisão esperadas antes de gravar.

## Contrato HTTP e Redocly

O contrato editável parte de `openapi/openapi.yaml`, separa operações por
superfície e capability em `openapi/paths/` e mantém parâmetros, schemas e
respostas reutilizáveis com a mesma taxonomia em `openapi/components/`. Os
arquivos `paths/{member,backoffice}.yaml` e
`components/{schemas,responses}.yaml` são índices pequenos; a definição fica no
fragmento da capability. O artefato servido aos clientes é
`priv/static/openapi/v1.json`; a interface navegável em `/api/docs` carrega esse
mesmo bundle, portanto não existe uma segunda cópia embutida da especificação.

A borda Phoenix segue a mesma divisão. Controllers ficam em
`lib/clubeira_web/controllers/<superfície>/<capability>/`, os testes espelham
essa árvore em `test/clubeira_web/controllers/` e as declarações ficam em
`lib/clubeira_web/router/*_routes.ex`. `ClubeiraWeb.Router` concentra apenas os
pipelines, a composição ordenada dessas superfícies e as rotas de
desenvolvimento.

Nos contexts maiores, `lib/clubeira/<context>.ex` continua sendo a fronteira
pública e os módulos internos ficam agrupados por capability, como
`billing/payments/`, `subscriptions/contracts/` e `reviews/moderation/`. Essa
organização é física: ela melhora descoberta e navegação sem criar namespaces
ou APIs públicas adicionais. Os testes de domínio espelham essas capabilities;
testes de RLS, concorrência e contrato do banco permanecem no nível do context.

```sh
npm run api:lint
npm run api:bundle
npm run api:check
```

Depois de alterar uma rota ou contrato, atualize a fonte e rode
`npm run api:bundle`. O check gera outro bundle em diretório temporário e falha
se o JSON publicado estiver obsoleto. O teste
`test/clubeira_web/open_api_contract_test.exs` também compara método e caminho
de todas as operações `/api/v1` com `ClubeiraWeb.Router.__routes__/0`; rota sem
documentação e documentação sem rota quebram o gate. A CI fixa a mesma versão
Node do `mise.toml`, instala pelo `package-lock.json` e executa esse check dentro
de `mix quality`.

## Inventário administrativo de lugares

O admin pode reencontrar uma participação mesmo antes de publicar seu perfil:

```text
GET /api/v1/polos/:slug/backoffice/places?profile_status=missing&status=active&limit=20
Authorization: Bearer <admin-token>
```

O endpoint também aceita `place_id`, `profile_status=published` e cursor
`after`. A resposta separa identidade global, status e vigência da participação
local, revisão e perfil público opcional. CNPJ não integra esse read model, e
IDs de outro polo produzem uma página vazia sob a role restrita.

## Acesso operacional do parceiro

O admin atribui uma conta já verificada ao operador vigente de um
estabelecimento. Organização, polo e papéis são derivados no servidor:

```text
POST /api/v1/polos/:slug/backoffice/places/:place_id/partner-accesses
Authorization: Bearer <admin-token>
Idempotency-Key: <8-a-128-caracteres>

{"email":"parceiro.demo@clubeira.local"}
```

A resposta `201` traz o `id` do acesso. A operação cria na mesma transação a
membership dedicada `partner_manager`, a afiliação `manager` da organização e
a atribuição `manager` do estabelecimento. Conta inexistente ou sem e-mail
verificado retorna `422`; uma membership corrente no mesmo polo retorna `409`,
evitando misturar o acesso revogável do parceiro com papéis administrativos.

Com o bearer do parceiro, as únicas participações visíveis são aquelas que
continuam provadas por todos esses vínculos:

```text
GET /api/v1/polos/:slug/partner/places?limit=20
Authorization: Bearer <partner-token>

PUT /api/v1/polos/:slug/partner/places/:place_id/profile
Authorization: Bearer <partner-token>
Idempotency-Key: <8-a-128-caracteres>
```

O `PUT` usa o mesmo contrato de perfil completo do backoffice. Um lugar não
atribuído retorna `404`, inclusive quando o UUID é válido. A revogação exige
motivo, encerra somente a vigência tenant-aware e preserva afiliação global e
acessos independentes em outros polos:

```text
POST /api/v1/polos/:slug/backoffice/partner-accesses/:access_id/revocations
Authorization: Bearer <admin-token>
Idempotency-Key: <8-a-128-caracteres>

{"reason":"Responsável removido do estabelecimento"}
```

Grant, edição e revogação têm replay exato e gravam idempotência, auditoria,
evento e outbox na mesma transação. O motivo livre fica somente na auditoria.

A participação corrente pode ser pausada, retomada ou encerrada sem alterar o
ponto de validação ou sua credencial:

```text
POST /api/v1/polos/:slug/backoffice/places/:place_id/lifecycle-actions
Authorization: Bearer <admin-token>
Idempotency-Key: <8-a-128-caracteres>

{
  "action":"suspend",
  "reason":"Interrupção operacional preventiva",
  "expected_polo_place_id":"<polo_place_id retornado pelo inventário>",
  "expected_revision":1
}
```

As ações suportadas são `suspend`, `reactivate` e `retire`. Retry exato devolve
o mesmo `200`; chave igual com payload diferente e transição incompatível
retornam `409` estável. Identidade ou revisão obsoleta retorna
`409 stale_place_participation`, sem evento ou outbox. Reativação exige a
participação ainda vigente e o lugar global ativo. `retire` encerra a vigência
no relógio transacional e torna a participação terminal; pontos e credenciais
preservam seu próprio lifecycle.

## Denúncias de avaliações

Um membro autenticado diferente do autor pode denunciar uma avaliação já
publicada:

```text
POST /api/v1/polos/:slug/places/:place_id/reviews/:review_id/reports
Authorization: Bearer <member-token>
Idempotency-Key: <8-a-128-caracteres>

{"reason_code":"offensive_content","details":"Contexto privado para a moderação"}
```

`reason_code` aceita `spam`, `offensive_content`, `personal_data`, `fraud` ou
`other`; neste último caso, `details` é obrigatório. O detalhe livre nunca sai
na resposta nem em audit/evento/outbox. A fila e a resolução exigem
`review_moderator` ou `admin`:

```text
GET /api/v1/polos/:slug/backoffice/review-reports?status=open&limit=20
Authorization: Bearer <moderator-token>

POST /api/v1/polos/:slug/backoffice/review-reports/:report_id/moderation-actions
Authorization: Bearer <moderator-token>
Idempotency-Key: <8-a-128-caracteres>

{"action":"hide","reason":"Violação confirmada pelas diretrizes"}
```

As ações são `dismiss`, `hide` e `remove`. A primeira mantém o review
publicado; as demais aceitam a denúncia e retiram a publicação do feed. A fila
aceita `open`, `accepted`, `rejected` ou `closed`, usa cursor opaco e expõe o
motivo completo somente nessa fronteira autorizada.

## Publicação administrativa de benefícios

Um admin do polo pode publicar uma oferta inicial sem acessar SQL:

```text
POST /api/v1/polos/:slug/backoffice/places/:place_id/benefit-offers
Authorization: Bearer <admin-token>
Idempotency-Key: <8-a-128-caracteres>
```

O corpo separa os campos estáveis em `offer` e o conteúdo imutável em
`version`. `effective_during.starts_at` é obrigatório e
`effective_during.ends_at` pode ser `null`; o intervalo é `[starts_at, ends_at)`.
Use strings decimais para preservar escala: percentual admite quatro casas e
valor em moeda, duas. `discount_percentage` aceita somente `percentage_value`,
`discount_amount` exige `amount_value + currency`, e benefícios não monetários
não aceitam esses campos.

O endpoint devolve `201`, persiste a resposta para replay exato e a oferta
aparece no catálogo público quando o período informado já está vigente. Código
já usado retorna `409` com `benefit_offer_code_conflict`; reutilizar a mesma
chave com outro corpo retorna `idempotency_conflict`. Lugar inativo ou de outro
polo falha como `404`, sem reservar a chave nem criar dados parciais. Header
`Idempotency-Key` ausente ou ambíguo retorna `400` com
`invalid_idempotency_key`; payload ou chave malformados retornam `422` antes da
reserva.

O inventário autenticado devolve as identidades e a versão imutável mais
recente sem depender da resposta original da publicação:

```text
GET /api/v1/polos/:slug/backoffice/benefit-offers?status=active&place_id=<uuid>&limit=20
Authorization: Bearer <admin-token>
```

Também aceita código exato e cursor `after`. A página é fechada antes de buscar
versão e lugares, então vínculos N:N não cortam filhos nem tornam o cursor
instável. O filtro de lugar considera a versão mais recente e permanece
tenant-aware; um UUID pertencente a outro polo produz uma página vazia.

## Publicação administrativa de produtos comerciais

Depois de publicar os benefícios, um admin pode montar uma configuração
vendável completa:

```text
POST /api/v1/polos/:slug/backoffice/product-offerings
Authorization: Bearer <admin-token>
Idempotency-Key: <8-a-128-caracteres>
```

O corpo contém `offering`, `price` e uma lista não vazia de `benefits`.
`offering.cycle` aceita `calendar` ou `anniversary`, intervalos em `day`,
`month` ou `year`, e `effective_during` usa o intervalo semiaberto habitual.
Preço usa string decimal positiva com até duas casas e moeda alfabética de três
letras. Cada benefício informa uma versão publicada, unidades por ciclo e
`consumption_unit` igual a `per_place` ou `shared_scope`; IDs duplicados são
rejeitados.

O endpoint devolve `201` com todas as identidades necessárias ao checkout. Ele
deriva lugares, escopo, políticas, versões e prioridades no servidor. ID
inexistente ou de outro polo retorna `404`; identidade visível cuja oferta,
versão ou participação não cobre toda a vigência retorna `409` com
`benefit_configuration_unavailable`. Código comercial já usado retorna `409`
com `product_offering_code_conflict`; retries exatos, inclusive com preço
decimal ou ordem dos benefícios equivalentes, devolvem o DTO original.
Reutilizar a chave com conteúdo diferente retorna `idempotency_conflict`, e
validação de payload ocorre antes da reserva.

O inventário autenticado permite recuperar a identidade mesmo depois que ela
sai da vitrine pública:

```text
GET /api/v1/polos/:slug/backoffice/product-offerings?status=paused&limit=20
Authorization: Bearer <admin-token>
```

Ele aceita `status`, código exato, `limit` e cursor `after`, e devolve a versão
mais recente com todos os seus preços. Assim o operador consegue pausar,
reativar ou aposentar sem guardar UUID fora do sistema nem consultar SQL.

## Lifecycle administrativo de produtos comerciais

Uma oferta publicada pode sair de novas vendas sem alterar pedidos, contratos
ou versões históricas:

```text
POST /api/v1/polos/:slug/backoffice/product-offerings/:product_offering_id/lifecycle-actions
Authorization: Bearer <admin-token>
Idempotency-Key: <8-a-128-caracteres>
```

O corpo exige `action` (`pause`, `reactivate` ou `retire`) e `reason` com 3 a
500 caracteres. `pause` aceita somente uma oferta ativa; `reactivate`, somente
uma pausada; `retire`, uma ativa ou pausada. A aposentadoria é terminal. Polo e
ator são derivados da rota e da sessão, e um ID de outro polo permanece `404`.

O retorno `200` informa estado anterior, estado atual, revisão monotônica e
timestamp do banco. Retry exato reproduz o mesmo DTO; reutilizar a chave com
outro comando retorna `idempotency_conflict`. Uma transição inválida retorna
`409` e também é reproduzível. Motivo fica somente na auditoria, nunca no evento
ou na outbox. A trava da identidade serializa transições e novos checkouts:
depois da pausa, `checkout-options` deixa de anunciá-la e novas ordens falham,
enquanto uma ordem criada antes do corte continua liquidável.

## Chaves de identificadores

O runtime cifra CNPJ e futuros identificadores com uma chave AES-256-GCM
versionada e deriva a busca exata com uma segunda chave HMAC. Em produção,
gere dois segredos independentes de 32 bytes e exporte-os como base64url sem
padding:

```sh
export IDENTIFIER_ENCRYPTION_KEY_VERSION=1
export IDENTIFIER_ENCRYPTION_KEY_BASE64="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
export IDENTIFIER_LOOKUP_KEY_BASE64="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
```

Guarde os valores num secret manager e restaure-os junto de qualquer dump do
banco. O writer atual carrega somente a chave de cifra ativa: não incremente a
versão nem troque o segredo mantendo a mesma versão antes de existir a rotina
de leitura e recifragem que carregará também a chave anterior. A chave de lookup
é permanente: regenerá-la permite duplicar identificadores porque muda o token
de unicidade global. A role migrator não precisa dessas chaves; elas são
obrigatórias apenas no runtime de produção.

## Mercado Pago: Pix, recorrência e chargeback

Configure as credenciais por conta em um único JSON. A chave externa precisa
ser igual a `merchant_accounts.provider_account_reference`; no cenário demo é
`mercado-pago-demo`:

```sh
export MERCADO_PAGO_ACCOUNTS_JSON='{
  "mercado-pago-demo": {
    "access_token": "APP_USR_REPLACE_ME",
    "webhook_secret": "REPLACE_WITH_THE_ORDER_WEBHOOK_SECRET"
  }
}'
export MERCADO_PAGO_SUBSCRIPTION_BACK_URL='https://app.example.com/assinaturas/retorno'
```

O registry de adapters fica em `config/config.exs`. Depois que outro adapter,
como Stripe, implementar `Clubeira.Billing.Gateways.Adapter` e for registrado
por código, a seleção não exige mudança no core:

```sh
export CLUBEIRA_PIX_PROVIDER='stripe'
export CLUBEIRA_SUBSCRIPTION_PROVIDER='stripe'
```

O boot aceita somente códigos minúsculos e o registry rejeita módulos que não
implementem o contrato completo. A URL neutra do webhook é
`/api/v1/webhooks/<provider_code>/<merchant_account_id>`; o adapter recebe o
body bruto exato para verificar assinaturas que dependem dos bytes originais.

Configuração vazia, JSON inválido, token curto ou segredo menor que 32 bytes
fazem o boot falhar sem imprimir a credencial. O mapa aceita várias contas e
nenhuma delas é persistida no PostgreSQL.

No sandbox, crie um usuário de teste no Mercado Pago e use seu e-mail antes de
reaplicar as seeds, pois a API rejeita pagador de teste fora de `@testuser.com`:

```sh
export CLUBEIRA_DEMO_EMAIL='<payer_test_user>@testuser.com'
mix db.reset
```

Na aplicação do Mercado Pago, selecione **Order (Mercado Pago)**,
**Subscription authorized payment** e **Chargebacks** e configure a mesma URL
HTTPS com o UUID exibido pelas seeds:

```text
https://<host>/api/v1/webhooks/mercado-pago/<merchant_account_id>
```

A integração segue a [Orders API](https://www.mercadopago.com.br/developers/pt/reference/online-payments/checkout-api/overview),
o recurso oficial de assinaturas e a validação de notificações do provedor.
Todos os tópicos passam pela mesma autenticação HMAC, conferem a identidade
entre URL e payload e releem o recurso remoto antes do core.
Use o simulador do painel para provar `200`; uma captura real de sandbox ainda
deve ser validada com credenciais próprias antes do deploy.

O estorno operacional é integral e parte de um `payment_id` interno já
capturado. Descubra esse ID no feed tenant-aware; `status` aceita os estados de
`payments`, `order_number` faz busca exata e `after` continua a paginação:

```sh
curl -sS \
  "http://localhost:4000/api/v1/polos/sobral/backoffice/payments?status=captured&limit=20" \
  -H "authorization: Bearer $ADMIN_TOKEN"
```

O feed não retorna motivo, chave idempotente ou referências externas.

O mesmo admin pode acompanhar o contrato criado pela captura sem consultar SQL:

```sh
curl -sS \
  "http://localhost:4000/api/v1/polos/sobral/backoffice/subscriptions?status=active&limit=20" \
  -H "authorization: Bearer $ADMIN_TOKEN"
```

O feed aceita `status`, `order_number`, `purchaser_user_id`,
`product_offering_version_id`, `limit` e `after`. O cursor é opaco e ordena por
`access_contracts.inserted_at + id`. A resposta inclui o snapshot comercial, o
ciclo corrente e o saldo agregado; não inclui e-mail, documento, billing
agreement, idempotência ou referências do provedor. Depois de um reembolso
integral, o mesmo contrato continua consultável como `cancelled`, com pedido
`refunded`, ciclo corrente ausente e saldo operacional zerado.

Com o `payment_id` e o mesmo bearer de `admin` do polo:

```sh
curl -sS -X POST \
  "http://localhost:4000/api/v1/polos/sobral/backoffice/payments/<payment_uuid>/refunds" \
  -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'idempotency-key: refund-sandbox-001' \
  -H 'content-type: application/json' \
  -d '{"reason":"Validação de estorno no sandbox"}'
```

Não envie valor ou referência do Mercado Pago: a aplicação deriva ambos do
banco. Em timeout, repita exatamente a mesma chave e motivo. A reserva local
reutiliza o mesmo UUID no `X-Idempotency-Key` do PSP, e uma notificação Order
assinada também reconcilia o resultado. Uma chave igual com motivo diferente
retorna conflito; uma rejeição definitiva fica estável e não altera a venda.
Para validar a jornada completa, confirme no banco que `payments` e `orders`
ficaram `refunded`, contrato/ciclo ficaram `cancelled` e somente o saldo
remanescente recebeu lançamentos `refund_revocation`.

Para uma oferta publicada com `renewal_policy=automatic`, crie primeiro o
pedido e depois chame `POST .../orders/:order_id/billing-agreements` com
`Idempotency-Key`. O retorno contém apenas o redirect hospedado pelo PSP. A
notificação de `authorized_payment` cria a nota do consumidor e o ciclo; falha,
inadimplência, cancelamento remoto e troca de meio ainda não têm transição
operacional. Chargeback aberto suspende o acesso, ganho o restaura e perdido
revoga somente o saldo ainda disponível.

## Storage de mídia de avaliações

O cliente envia apenas uma `storage_key` previamente carregada. O runtime exige
um control plane que confirme metadados imutáveis antes do registro e uma base
pública separada para a entrega:

```sh
export REVIEW_MEDIA_VERIFICATION_URL='https://storage.example.com/internal/media/verify'
export REVIEW_MEDIA_PUBLIC_BASE_URL='https://cdn.example.com/reviews'
export REVIEW_MEDIA_VERIFICATION_BEARER_TOKEN='<secret-opcional>'
```

As duas URLs precisam ser HTTPS e são configuradas em conjunto. O endpoint de
verificação recebe `?key=...` e deve retornar `immutable=true`, `content_type`,
`sha256` base64url, `size_bytes` e dimensões/duração coerentes. O bearer nunca
entra no banco, resposta, auditoria ou URL pública.

## Cobrança SaaS do polo

Planos e features são globais e exigem uma membership vigente numa organização
`kind=platform` com role `platform_billing_admin` ou `platform_admin`. A
assinatura e suas notas continuam tenant-aware e exigem `manage_billing` no
polo. Configure a conta global usada pela Clubeira para cobrar os polos:

```sh
export PLATFORM_BILLING_MERCHANT_ACCOUNT_ID='<merchant-account-uuid>'
```

O UUID precisa existir em `merchant_accounts` e ter credenciais no mesmo
`MERCADO_PAGO_ACCOUNTS_JSON`. A criação do plano é um `PUT` versionado e
repetível; preço futuro pode ser publicado sem entrar no catálogo corrente. A
assinatura usa o mesmo `MERCADO_PAGO_SUBSCRIPTION_BACK_URL` e o webhook só
liquida `platform_invoice`, itens e pagamento depois de reler a cobrança.

## Resgate online autenticado

O cliente gera e conserva localmente 32 bytes aleatórios para identificar sua
instalação. A API recebe a forma base64url sem padding, mas o PostgreSQL guarda
somente SHA-256. O fluxo operacional é:

1. o operador consulta
   `GET /api/v1/polos/:slug/backoffice/validation-points` para redescobrir pontos
   e a versão corrente de cada credencial, com filtros opcionais `status`,
   `place_id`, `limit` e `after`; a resposta nunca contém chave ou digest;
2. quando ainda não existe um ponto, gera outra chave de 32 bytes e registra
   somente seu SHA-256 em
   `POST /api/v1/polos/:slug/backoffice/places/:place_id/validation-points`, com
   bearer de admin e `Idempotency-Key`;
3. pausa, retoma ou aposenta o ponto em
   `POST /api/v1/polos/:slug/backoffice/validation-points/:validation_point_id/lifecycle-actions`,
   enviando `action`, `reason` e `Idempotency-Key`;
4. quando necessário, troca a chave em
   `POST /api/v1/polos/:slug/backoffice/validation-credentials/:credential_id/rotations`,
   enviando o digest novo e mirando o ID da versão corrente;
5. em incidente ou desativação, encerra a chave sem substituí-la em
   `POST /api/v1/polos/:slug/backoffice/validation-credentials/:credential_id/revocations`,
   também com o ID corrente e `Idempotency-Key`;
6. `POST /api/v1/polos/:slug/me/redemption-devices`, com bearer do membro;
7. `POST /api/v1/polos/:slug/me/redemption-grants`, com alocação e o mesmo
   segredo de instalação;
8. transporte de `data.grant` para o app do estabelecimento;
9. `POST /api/v1/polos/:slug/redemptions`, com
   `Authorization: Validation <chave>` e `Idempotency-Key`.

Grant e chave de validação são credenciais e não entram em log, audit, evento
ou fixture persistida. O provisionamento recebe o SHA-256 base64url, não a chave,
e exige expiração futura de no máximo 365 dias. O cliente deve gerar a chave com
CSPRNG, guardá-la em secret storage e calcular o digest sobre os 32 bytes crus.
A rotação exige o ID devolvido pela criação ou pela rotação anterior, fecha a
vigência da versão corrente e cria `version + 1`; não substitui hash histórico.
Instale a nova chave somente depois de receber `201`: o corte é imediato e a
anterior deixa de autenticar. Um retry exato devolve o mesmo DTO; alvo stale ou
digest duplicado retornam `409` sem alterar a chave vencedora. A revogação
encerra a versão corrente mesmo se o ponto já estiver suspenso e responde
`200`; retry exato é seguro, enquanto alvo stale ou já revogado retorna `409`
auditado. Rotação e revogação são serializadas pela mesma trava, e uma
revogação explícita nunca pode ser renovada. O grant expira em 120 segundos por
padrão. O endpoint final rejeita polo
divergente, assinatura alterada, chave revogada/expirada e replay de nonce antes
de qualquer segundo consumo.

O lifecycle exige um motivo de 3 a 500 caracteres. `suspend` preserva a
credencial, mas corta sua autenticação imediatamente; `reactivate` só retorna o
ponto a `active` se lugar, participação e credencial corrente ainda estiverem
ativos; `retire` é terminal e revoga a credencial corrente atomicamente. Retry
exato devolve o mesmo DTO e transições inválidas retornam um único `409`
auditado. Motivos operacionais ficam apenas na auditoria tenant. Lifecycle,
rotação e revogação usam a mesma trava por ponto e uma revisão monotônica para
ordenar os eventos concorrentes.

A rotação aceita ponto API ativo ou suspenso. Isso permite substituir uma chave
expirada durante manutenção sem reabrir o terminal antes da hora; somente
`reactivate` volta a autorizar resgates. Ponto aposentado e credencial
explicitamente revogada continuam terminais.

## Publicador da outbox

Em produção, habilite uma única integração HTTPS por configuração de runtime:

```sh
export OUTBOX_PUBLISHER_ENABLED=true
export OUTBOX_WEBHOOK_URL='https://events.example.com/clubeira'
export OUTBOX_WEBHOOK_SECRET='<pelo-menos-32-bytes-aleatorios>'
```

Os defaults são lote `50`, ciclo de `1s`, timeout HTTP de `10s`, lease de
`60s`, máximo de `10` tentativas e backoff entre `1s` e `1h`. Todos podem ser
ajustados por `OUTBOX_BATCH_SIZE`, `OUTBOX_INTERVAL_MS`,
`OUTBOX_HTTP_TIMEOUT_MS`, `OUTBOX_LOCK_TIMEOUT_MS`, `OUTBOX_MAX_ATTEMPTS`,
`OUTBOX_RETRY_BASE_MS` e `OUTBOX_RETRY_MAX_MS`; valores inválidos abortam o
boot.

Cada instância pode executar o worker: claims PostgreSQL com `SKIP LOCKED`
coordenam réplicas sem eleição de líder. A requisição usa `Content-Type:
application/json` e envia `x-clubeira-event-id`, `x-clubeira-topic`,
`x-clubeira-message-key`, `x-clubeira-timestamp` e
`x-clubeira-signature`. A assinatura é `v1=` seguida do HMAC-SHA256 hexadecimal
de `timestamp <> "." <> body`.

O consumer precisa validar a assinatura em tempo constante, recusar timestamps
fora de sua janela e persistir `event_id` como chave idempotente antes do `2xx`.
Qualquer outro status ou erro de transporte agenda retry exponencial; depois de
`OUTBOX_MAX_ATTEMPTS`, a mensagem permanece em `dead_letter` para inspeção e
reprocessamento operacional. O corpo de erro do consumer e o segredo nunca são
persistidos em `last_error`.

O admin do polo consulta `backoffice/outbox-messages` por estado e tópico e usa
`POST .../outbox-messages/:id/retries` com `Idempotency-Key` para devolver uma
`dead_letter` a `pending`. A resposta nunca inclui payload, `last_error`,
`message_key` ou `locked_by`; a mesma transação zera tentativas, limpa o lease e
o erro sanitizado, agenda disponibilidade imediata e grava
`outbox.message_requeued` na auditoria tenant. `backoffice/audit-events` permite
confirmar o fato por ação e tipo de recurso sem expor metadata privada.

## Roles do banco

O desenvolvimento inicia a aplicação como `clubeira_app`. Cada conexão valida
que a role é `NOSUPERUSER NOBYPASSRLS`, não cria objetos no schema `public` e
não é dona nem membro de roles donas de tabelas da aplicação. Migrations e
seeds são executadas com `clubeira_migrator` pelos aliases abaixo:

```sh
mix db.migrate
mix db.reset
```

Para chamar uma task Ecto manualmente com a role correta:

```sh
CLUBEIRA_DATABASE_ROLE_MODE=migrator mix ecto.migrate
```

Não inicie o servidor nesse modo. A role migrator é dona das tabelas e existe
somente para evolução do schema e bootstrap controlado.

Em produção, runtime usa `DATABASE_URL`; migration usa
`MIGRATOR_DATABASE_URL` junto de
`CLUBEIRA_DATABASE_ROLE_MODE=migrator`. As duas credenciais devem ser distintas.
O job migrator não recebe `PHX_SERVER`, `SECRET_KEY_BASE`, material de cifra nem
segredos do mailer. A aplicação, por sua vez, nunca recebe
`MIGRATOR_DATABASE_URL`.

O provisionamento de uma base vazia segue uma ordem única:

```sh
psql "$ADMIN_DATABASE_URL" --file docker/postgres/provision-production.sql

CLUBEIRA_DATABASE_ROLE_MODE=migrator \
MIGRATOR_DATABASE_URL="$MIGRATOR_DATABASE_URL" \
_build/prod/rel/clubeira/bin/migrate

psql "$ADMIN_DATABASE_URL" --file docker/postgres/provision-production.sql
psql "$RUNTIME_DATABASE_URL" --file docker/postgres/verify-runtime-role.sql
```

O primeiro provisionamento cria as roles sem credencial embutida e instala
default privileges antes de qualquer tabela. A segunda execução reconcilia
grants dos objetos existentes e mantém `schema_migrations` somente leitura
para `clubeira_app`. Password, certificado ou IAM são configurados fora do
repositório. O script não cria nem escolhe o database: a conexão administrativa
já deve apontar para o alvo correto.

Depois das migrations e da reconciliação de grants, aplique a configuração
estrutural do primeiro polo pela mesma release:

```sh
cp config/bootstrap.example.json /run/config/clubeira-bootstrap.json
# Edite IDs UUIDv7, cidade, URLs, referência da conta PSP e caminhos montados.

CLUBEIRA_DATABASE_ROLE_MODE=migrator \
MIGRATOR_DATABASE_URL="$MIGRATOR_DATABASE_URL" \
CLUBEIRA_BOOTSTRAP_FILE=/run/config/clubeira-bootstrap.json \
_build/prod/rel/clubeira/bin/bootstrap
```

O arquivo é estrito e sem segredos. `legal.content_file` precisa ser absoluto,
regular e legível; `legal.content_uri` precisa ser HTTPS. A operação cria a
fundação inteira atomicamente, usa advisory lock transacional e falha fechada
se uma identidade natural já existir com atributos diferentes. O conteúdo dos
termos vira SHA-256 e uma versão publicada imutável. Não altere o manifesto
mantendo o mesmo `operation_id`; gere uma nova operação para outra fundação.

O bootstrap nunca fabrica credencial. Com `admin_email` presente, faça a
primeira execução, consulte `GET /api/v1/legal/registration`, cadastre o usuário
por `POST /api/v1/auth/registrations`, conclua a verificação de e-mail e repita
o mesmo `bin/bootstrap`. Os estados esperados são `pending_registration`,
`pending_verification`, `granted` e depois `already_granted`. Membership,
atribuição da role e auditoria tenant nascem na mesma transação sob o polo.

A CI cria o cenário local por `docker/postgres/init.sql`, aplica também o
provisionamento de produção, executa as migrations como `clubeira_migrator` e roda
`docker/postgres/verify-runtime-role.sql` autenticada como `clubeira_app`. O
contrato prova flags da role, privilégio de schema, DML e isolamento RLS com e
sem escopo, além de impedir escrita da web em `schema_migrations`; não
substitua esse passo por uma conexão `postgres` privilegiada.
A ida e volta de migrations também mantém um polo propositalmente sem rota para
provar o rollback e verifica que slugs legados inválidos falham com diagnóstico
antes de qualquer backfill.

## Release e probes

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
docker build --tag clubeira:release .
```

`rel/overlays/bin/migrate` chama `Clubeira.Release.migrate/0` como job único;
`rel/overlays/bin/bootstrap` aplica o manifesto explícito. Nenhum dos dois
integra a supervision tree. `rel/overlays/bin/server` habilita o Bandit e recusa
modo migrator. O container final executa como `nobody`, com `tini`, sem Mix ou
toolchain de compilação.

`GET /health` é liveness e não consulta dependência externa. `GET /ready` usa a
role runtime real, valida flags e grants, lê `schema_migrations` sem lock ou DDL
e responde `503` se houver migration pendente ou banco indisponível. Ambos ficam
fora do redirect de HTTPS para permitir probes internos; tráfego público ainda
recebe HSTS no proxy confiável.

PostgreSQL usa TLS com verificação de peer e hostname por default.
`DATABASE_CA_CERT_FILE` aponta para uma CA privada legível por caminho absoluto.
Somente desenvolvimento, CI ou rede local isolada declaram
`DATABASE_SSL=false`. `PHX_HOST`, `PORT` e `POOL_SIZE` falham cedo com o nome da
variável inválida.

Mensagens humanas da pipeline API negociam `Accept-Language` (`pt-BR` e `en`),
respeitam pesos `q`, devolvem `Content-Language` e usam inglês como fallback.
IDs, estados, enums e códigos de domínio permanecem invariantes.

## Migrations

Cada mudança estrutural fica em uma migration própria e segue o gerador
Phoenix/Ecto:

```sh
mix ecto.gen.migration nome_da_migration_em_snake_case
mix db.migrate
```

Mantenha `up/down` reversível quando SQL manual impedir `change/0`. Constraint
e índice devem nascer com a invariável ou query que justificam sua existência.
Em tabelas tenant-aware, referências para outras tabelas tenant precisam
incluir `polo_id` na FK composta.

Antes de entregar uma alteração de banco, valide uma ida e volta em banco de
teste vazio:

```sh
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix ecto.rollback --all
MIX_ENV=test mix ecto.migrate
```

## Testes e gates

```sh
mix test
mix quality
mix dialyzer
mix precommit
```

`mix quality` roda formatação em check, lint Redocly com verificação do bundle
OpenAPI, compilação com warnings como erro, dependências não usadas, Credo
strict, auditoria de dependências, auditoria Hex, Sobelow e a suíte com cobertura
backend mínima de 90%. Enquanto o produto não
possui frontend, somente o scaffold `ClubeiraWeb.CoreComponents` fica fora do
denominador; controllers, JSON, domínio, workers e demais módulos continuam no
gate. `mix precommit` formata antes de repetir o gate completo.

Testes de banco usam SQL Sandbox. O setup cria e assume uma role PostgreSQL
temporária sem bypass de RLS dentro da transação, para que a suíte não ganhe
falso positivo por conectar como administrador.

Testes de concorrência usam `Clubeira.ConcurrencyCase`, fora do SQL Sandbox.
Cada suíte de capability recebe um banco migrado e uma role runtime restrita
próprios; `run_concurrently/2` sincroniza os workers por barreira antes de
disparar os comandos. Mantenha os cenários junto da capability que protegem e
deixe no case compartilhado somente o ciclo de vida PostgreSQL e a sincronização.

`test/e2e/member_checkout_test.exs` sobe um Bandit supervisionado em porta
efêmera e usa `Req` sobre TCP contra o endpoint real. O cenário atravessa health,
cadastro, confirmação de e-mail, perfil cifrado, consentimento, pedido LGPD,
checkout idempotente, criação Pix, webhook HMAC, liquidação, assinatura, chave
Ed25519 do dispositivo, carteira, resgate, review, moderação e reembolso com
PostgreSQL real. Somente a API remota do PSP termina em `Req.Test`; a borda HTTP
da aplicação não é substituída. Ele roda dentro de `mix test` e não substitui os
testes isolados de contrato nem uma validação futura contra o PSP em sandbox.

## Multi-tenancy no código

Uma operação de domínio por polo deve receber o `Scope` já autorizado e manter
todas as queries na mesma transação:

```elixir
scope = Clubeira.Tenancy.Scope.new!(polo_id, actor_user_id: user_id)

Clubeira.Repo.transact_in_polo(scope, fn ->
  {:ok, resultado}
end)
```

Não aceite `polo_id` arbitrário como autorização, não use queries tenant fora
dessa fronteira e não coloque `SET ROLE` ou `set_config` espalhado em contexts.

Uma leitura autenticada que precisa apenas descobrir polos começa com o escopo
global do ator e entra em cada tenant sem trocar ator/request:

```elixir
actor_scope = Clubeira.Tenancy.ActorScope.new!(user_id, request_id)

Clubeira.Repo.transact_as_actor(actor_scope, fn ->
  # leia apenas projeções ou relações cobertas por policies actor-owned e use
  # transact_in_polo/3 para consultar contratos, ciclos e alocações
  {:ok, resultado}
end)
```

Para validar o bootstrap que será consumido pelo web/app:

```sh
curl -sS 'http://localhost:4000/api/v1/polos?limit=20'
curl -sS http://localhost:4000/api/v1/me/access \
  -H "authorization: Bearer $TOKEN"
```

O primeiro endpoint mostra somente polos ativos e pagina pelo slug com cursor
opaco. O segundo deriva roles e capabilities atuais da plataforma e dos polos;
ele é um read model de navegação. Testes e controllers não podem usar essa
resposta como autorização em lugar das verificações transacionais existentes.

Tokens bearer crus nunca entram em fixtures, logs ou banco. Testes de cadastro
usam `Clubeira.Accounts.register/1`; fixtures que já possuem usuário criam a
senha via `Clubeira.Accounts.set_password/2`. Em ambos os casos, autentique pela
API e verifique revogação/expiração em vez de fabricar um token persistido.

## Controles de autenticação em produção

Os defaults são conservadores e todos os valores abaixo são validados no boot:

| Variável | Default | Finalidade |
| --- | ---: | --- |
| `ARGON2_T_COST` | `3` | iterações do Argon2id |
| `ARGON2_M_COST` | `16` | expoente de memória do Argon2id |
| `ARGON2_PARALLELISM` | `4` | lanes por derivação |
| `ARGON2_MAX_CONCURRENCY` | `8` | hashes/verificações simultâneos por instância |
| `LOGIN_RATE_GLOBAL_PER_SECOND` | `40` | admissões por instância e segundo |
| `LOGIN_RATE_IP_PER_MINUTE` | `20` | admissões por peer IPv4 `/32` ou IPv6 `/64` e minuto |
| `LOGIN_RATE_IDENTITY_PER_15_MINUTES` | `10` | admissões por identidade e 15 minutos |
| `REGISTRATION_RATE_GLOBAL_PER_SECOND` | `10` | cadastros admitidos por instância e segundo |
| `REGISTRATION_RATE_IP_PER_MINUTE` | `5` | cadastros por peer e minuto |
| `REGISTRATION_RATE_IDENTITY_PER_15_MINUTES` | `3` | cadastros por identidade e 15 minutos |
| `EMAIL_VERIFICATION_RATE_GLOBAL_PER_SECOND` | `20` | reenvios autenticados por instância e segundo |
| `EMAIL_VERIFICATION_RATE_IP_PER_MINUTE` | `10` | reenvios por peer e minuto |
| `EMAIL_VERIFICATION_RATE_IDENTITY_PER_15_MINUTES` | `3` | reenvios por conta e 15 minutos |
| `EMAIL_VERIFICATION_CONFIRM_RATE_GLOBAL_PER_SECOND` | `40` | confirmações por instância e segundo |
| `EMAIL_VERIFICATION_CONFIRM_RATE_IP_PER_MINUTE` | `20` | confirmações por peer e minuto |
| `EMAIL_VERIFICATION_CONFIRM_RATE_TOKEN_PER_15_MINUTES` | `10` | confirmações por fingerprint de token e 15 minutos |
| `EMAIL_VERIFICATION_TOKEN_TTL_HOURS` | `24` | validade da prova, entre 1 e 168 horas |
| `EMAIL_VERIFICATION_URL` | obrigatória | URL HTTPS da tela que recebe `?token=...` |
| `PASSWORD_RESET_RATE_GLOBAL_PER_SECOND` | `20` | solicitações de recuperação por instância e segundo |
| `PASSWORD_RESET_RATE_IP_PER_MINUTE` | `10` | solicitações por peer e minuto |
| `PASSWORD_RESET_RATE_IDENTITY_PER_15_MINUTES` | `3` | solicitações por identidade e 15 minutos |
| `PASSWORD_RESET_CONFIRM_RATE_GLOBAL_PER_SECOND` | `40` | consumos de token por instância e segundo |
| `PASSWORD_RESET_CONFIRM_RATE_IP_PER_MINUTE` | `20` | consumos por peer e minuto |
| `PASSWORD_RESET_CONFIRM_RATE_TOKEN_PER_15_MINUTES` | `10` | tentativas por fingerprint de token e 15 minutos |
| `PASSWORD_RESET_TOKEN_TTL_MINUTES` | `30` | validade do token, entre 5 e 120 minutos |
| `PASSWORD_RESET_URL` | obrigatória | URL HTTPS da tela que recebe `?token=...` |
| `MAILER_PROVIDER` | obrigatória (`resend`) | adapter de produção aceito no boot |
| `MAILER_FROM_EMAIL` | obrigatória | remetente verificado usado pelo Clubeira |
| `RESEND_API_KEY` | obrigatória | credencial do provider, nunca persistida |
| `REDEMPTION_GRANT_MAX_AGE_SECONDS` | `120` | validade do grant assinado, entre 30 e 600 segundos |
| `SESSION_RETENTION_DAYS` | `30` | retenção de sessões e tokens temporários terminais |

Os buckets em ETS e o gate de senha são locais à instância. Em múltiplas
réplicas, configure também o rate limit no load balancer/API gateway e calibre
Argon2 com a CPU e memória reais antes do deploy. `429` inclui `Retry-After`.
Não derive IP de `x-forwarded-for` sem uma cadeia de proxies confiável.

Em desenvolvimento, confirmações de e-mail e solicitações de recuperação aparecem em
`http://localhost:4000/dev/mailbox`. Em produção, configure
`MAILER_PROVIDER=resend`, um remetente já verificado e a chave via secret
manager; ausência ou valor inválido impede o boot. A resposta pública continua
`202` mesmo se a entrega falhar, enquanto a credencial é revogada e a falha
vira telemetria sem email ou token. Jobs com
`CLUBEIRA_DATABASE_ROLE_MODE=migrator` não precisam receber os segredos do
mailer.

## Operação local

```sh
docker compose ps
docker compose logs postgres
docker compose stop
docker compose down
```

O volume `clubeira_postgres_data` sobrevive a `stop` e `down`. `mix db.reset`
faz rollback e reaplica todo o schema sem remover esse volume. Somente
`docker compose down -v` destrói os dados locais; use-o de forma intencional e
depois rode `mix setup` para reconstruir tudo.
