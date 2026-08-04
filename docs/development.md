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

Factories vivem em `support/factory.ex` e são compiladas apenas em `dev` e
`test`. Dados estruturais das seeds sempre recebem IDs e valores estáveis;
Faker fica restrito a texto de apresentação irrelevante para a regra testada.

## Roles do banco

O desenvolvimento inicia a aplicação como `clubeira_app`. Cada conexão valida
que a role é `NOSUPERUSER NOBYPASSRLS`. Migrations e seeds são executadas com
`clubeira_migrator` pelos aliases abaixo:

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

Tokens bearer crus nunca entram em fixtures, logs ou banco. Testes criam a
senha via `Clubeira.Accounts.set_password/2`, autenticam pela API e verificam
revogação/expiração em vez de fabricar um token persistido.

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
