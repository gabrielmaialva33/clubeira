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
banco, migrations, seeds, instalação e build dos assets. As seeds são
determinísticas e idempotentes: representam Sobral, Londrina, uma franquia nos
dois polos, um parceiro local apenas em Sobral e um membro com assinatura e
ciclo independentes nos dois polos. A senha local padrão é
`clubeira-demo-local`; use `CLUBEIRA_DEMO_PASSWORD` para substituí-la.
As assinaturas demo passam pelos comandos reais `Billing.place_order/2` e
`Billing.settle_payment/2`: pedido, intent, pagamento, evento do provedor,
contrato, ciclo, alocações, auditoria, eventos e outbox nascem pela mesma
fronteira transacional usada pela aplicação, em vez de serem montados à mão.
O backoffice usa `moderador.demo@clubeira.local` com a senha local
`clubeira-moderador-local`; substitua por `CLUBEIRA_DEMO_MODERATOR_EMAIL` e
`CLUBEIRA_DEMO_MODERATOR_PASSWORD` em ambientes compartilhados. Esse usuário
recebe o papel `review_moderator` nos dois polos sem qualquer bypass de RLS.
As seeds também criam o provedor `mercado_pago`, uma conta global
`mercado-pago-demo` e vínculos primários com os dois polos. A saída da seed
mostra o UUID usado na URL do webhook. Sobral recebe ainda um ponto de
validação de API. Sua chave é lida de `CLUBEIRA_DEMO_VALIDATION_SECRET` e deve
ser base64url sem padding de exatamente 32 bytes; o default documentado é
somente para uso local.

Factories vivem em `support/factory.ex` e são compiladas apenas em `dev` e
`test`. Dados estruturais das seeds sempre recebem IDs e valores estáveis;
Faker fica restrito a texto de apresentação irrelevante para a regra testada.

## Mercado Pago Pix

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
```

Configuração vazia, JSON inválido, token curto ou segredo menor que 32 bytes
fazem o boot falhar sem imprimir a credencial. O mapa aceita várias contas e
nenhuma delas é persistida no PostgreSQL.

No sandbox, crie um usuário de teste no Mercado Pago e use seu e-mail antes de
reaplicar as seeds, pois a API rejeita pagador de teste fora de `@testuser.com`:

```sh
export CLUBEIRA_DEMO_EMAIL='<payer_test_user>@testuser.com'
mix db.reset
```

Na aplicação do Mercado Pago, selecione o tópico **Order (Mercado Pago)** e
configure a URL HTTPS abaixo com o UUID exibido pelas seeds:

```text
https://<host>/api/v1/webhooks/mercado-pago/<merchant_account_id>
```

A integração segue a [Orders API](https://www.mercadopago.com.br/developers/pt/reference/online-payments/checkout-api/overview)
e a validação oficial de [notificações Order](https://www.mercadopago.com.br/developers/pt/docs/checkout-api-orders/notifications).
Use o simulador do painel para provar `200`; uma captura real de sandbox ainda
deve ser validada com credenciais próprias antes do deploy.

## Resgate online autenticado

O cliente gera e conserva localmente 32 bytes aleatórios para identificar sua
instalação. A API recebe a forma base64url sem padding, mas o PostgreSQL guarda
somente SHA-256. O fluxo operacional é:

1. `POST /api/v1/polos/:slug/me/redemption-devices`, com bearer do membro;
2. `POST /api/v1/polos/:slug/me/redemption-grants`, com alocação e o mesmo
   segredo de instalação;
3. transporte de `data.grant` para o app do estabelecimento;
4. `POST /api/v1/polos/:slug/redemptions`, com
   `Authorization: Validation <chave>` e `Idempotency-Key`.

Grant e chave de validação são credenciais e não entram em log, audit, evento
ou fixture persistida. A chave de produção deve ser provisionada por versão e
rotacionada criando nova `validation_credential`; não substitua o hash de uma
versão histórica. O grant expira em 120 segundos por padrão. O endpoint final
rejeita polo divergente, assinatura alterada, chave revogada/expirada e replay
de nonce antes de qualquer segundo consumo.

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

A CI provisiona as duas roles pelo mesmo `docker/postgres/init.sql`, executa
as migrations como `clubeira_migrator` e roda
`docker/postgres/verify-runtime-role.sql` autenticada como `clubeira_app`. O
contrato prova flags da role, privilégio de schema, DML e isolamento RLS com e
sem escopo; não substitua esse passo por uma conexão `postgres` privilegiada.
A ida e volta de migrations também mantém um polo propositalmente sem rota para
provar o rollback e verifica que slugs legados inválidos falham com diagnóstico
antes de qualquer backfill.

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

`mix quality` roda formatação em check, compilação com warnings como erro,
dependências não usadas, Credo strict, auditoria de dependências, auditoria Hex,
Sobelow e testes. `mix precommit` formata antes de repetir o gate completo.

Testes de banco usam SQL Sandbox. O setup cria e assume uma role PostgreSQL
temporária sem bypass de RLS dentro da transação, para que a suíte não ganhe
falso positivo por conectar como administrador.

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
  # leia apenas a projeção global autorizada e use transact_in_polo/3
  # para consultar contratos, ciclos e alocações
  {:ok, resultado}
end)
```

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
| `PASSWORD_RESET_RATE_GLOBAL_PER_SECOND` | `20` | solicitações de recuperação por instância e segundo |
| `PASSWORD_RESET_RATE_IP_PER_MINUTE` | `10` | solicitações por peer e minuto |
| `PASSWORD_RESET_RATE_IDENTITY_PER_15_MINUTES` | `3` | solicitações por identidade e 15 minutos |
| `PASSWORD_RESET_CONFIRM_RATE_GLOBAL_PER_SECOND` | `40` | consumos de token por instância e segundo |
| `PASSWORD_RESET_CONFIRM_RATE_IP_PER_MINUTE` | `20` | consumos por peer e minuto |
| `PASSWORD_RESET_CONFIRM_RATE_TOKEN_PER_15_MINUTES` | `10` | tentativas por fingerprint de token e 15 minutos |
| `PASSWORD_RESET_TOKEN_TTL_MINUTES` | `30` | validade do token, entre 5 e 120 minutos |
| `PASSWORD_RESET_URL` | obrigatória | URL HTTPS da tela que recebe `?token=...` |
| `MAILER_PROVIDER` | `resend` obrigatório | adapter de produção aceito no boot |
| `MAILER_FROM_EMAIL` | obrigatória | remetente verificado usado pelo Clubeira |
| `RESEND_API_KEY` | obrigatória | credencial do provider, nunca persistida |
| `REDEMPTION_GRANT_MAX_AGE_SECONDS` | `120` | validade do grant assinado, entre 30 e 600 segundos |
| `SESSION_RETENTION_DAYS` | `30` | retenção de sessões e tokens de recuperação terminais |

Os buckets em ETS e o gate de senha são locais à instância. Em múltiplas
réplicas, configure também o rate limit no load balancer/API gateway e calibre
Argon2 com a CPU e memória reais antes do deploy. `429` inclui `Retry-After`.
Não derive IP de `x-forwarded-for` sem uma cadeia de proxies confiável.

Em desenvolvimento, solicitações de recuperação aparecem em
`http://localhost:4000/dev/mailbox`. Em produção, configure
`MAILER_PROVIDER=resend`, um remetente já verificado e a chave via secret
manager; ausência ou valor inválido impede o boot. A resposta pública continua
`202` mesmo se a entrega falhar, enquanto a credencial é revogada e a falha
vira telemetria sem email ou token.

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
