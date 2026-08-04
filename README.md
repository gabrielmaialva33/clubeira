# Clubeira

Fundação backend de um SaaS multi-tenant para clubes de vouchers por assinatura.
Um único produto atende vários polos independentes — cidades, regiões ou
franquias — e o mesmo usuário pode manter contratos, ciclos e benefícios
separados em cada um deles.

O estado atual já inclui a base de domínio e persistência, catálogo público por
polo, autenticação por sessão bearer revogável, descoberta de assinaturas
multi-polo, carteira de vouchers, isolamento por RLS, seeds/factories e o
núcleo transacional de resgate. Cobrança integrada e o protocolo de QR entram
nas próximas fatias verticais.

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
```

O primeiro comando devolve `data.access_token`; atribua-o a `TOKEN` apenas na
sessão do shell. `DELETE /api/v1/auth/session` revoga a sessão atual.

## Banco e multi-tenancy

O banco usa um schema PostgreSQL compartilhado e normalizado. Dados tenant
carregam `polo_id`; chaves estrangeiras compostas impedem referências entre
polos e todas as tabelas com `polo_id` são protegidas por RLS forçado.

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
opaco. Para a tela cross-polo, `user_contract_polo_routes` revela ao ator apenas
os IDs dos polos onde ele já contratou. Isso é um índice de roteamento, não uma
autorização: contrato, ciclo e saldo são relidos dentro da RLS de cada polo.

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

## Documentação

- [Arquitetura](docs/architecture.md)
- [Desenvolvimento](docs/development.md)

O limite de segurança do resgate também está documentado em
`Clubeira.Redemptions`: `confirm/2` recebe apenas uma confirmação já
autenticada. Token, QR e autenticação do ponto de validação pertencem à borda
de entrada e não podem confiar em IDs enviados pelo cliente.
