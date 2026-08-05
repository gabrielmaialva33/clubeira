# Contributing to Clubeira

Thanks for taking the time to contribute. Clubeira is a multi-tenant SaaS
backend for subscription voucher clubs, built as a modular Elixir/Phoenix
monolith on PostgreSQL. Correctness of tenant isolation, transactional
boundaries, and auditability matters more here than raw feature velocity.

This document is the practical guide. The architectural contract lives in
[`AGENTS.md`](AGENTS.md), [`docs/architecture.md`](docs/architecture.md), and
[`docs/development.md`](docs/development.md) — read those before changing
structural behavior.

By participating, you agree to abide by our
[Code of Conduct](CODE_OF_CONDUCT.md).

---

## Table of contents

- [Ways to contribute](#ways-to-contribute)
- [Local setup](#local-setup)
- [Development workflow](#development-workflow)
- [Non-negotiable invariants](#non-negotiable-invariants)
- [Database changes](#database-changes)
- [Testing](#testing)
- [Coding style](#coding-style)
- [Commit messages](#commit-messages)
- [Pull requests](#pull-requests)
- [Reporting security issues](#reporting-security-issues)

---

## Ways to contribute

| Type | Start here |
|:--|:--|
| 🐛 Bug report | [Open a bug issue](https://github.com/gabrielmaialva33/clubeira/issues/new?template=bug_report.yml) with a reproducible case |
| ✨ Feature or slice proposal | [Open a feature issue](https://github.com/gabrielmaialva33/clubeira/issues/new?template=feature_request.yml) describing the invariant it must preserve |
| 📚 Documentation | README, `docs/`, or inline module docs — same PR process |
| 🔐 Vulnerability | **Do not open an issue.** Follow [SECURITY.md](SECURITY.md) |

For anything larger than a bug fix, open an issue first. A slice that crosses a
transactional boundary (billing, redemptions, tenancy, outbox) should be agreed
on before the code exists.

---

## Local setup

Prerequisites: [`mise`](https://mise.jdx.dev/) and Docker with Compose.

```sh
git clone git@github.com:gabrielmaialva33/clubeira.git
cd clubeira
mise install
mix setup
mix phx.server
```

`mix setup` installs dependencies, starts PostgreSQL 18 on `127.0.0.1:55432`,
creates and migrates the database with the migration role, and loads a
deterministic scenario with the `sobral` and `londrina` polos.

Toolchain versions are pinned in `mise.toml`. Do not bump them in a feature PR.

---

## Development workflow

1. **Orient.** Read the surrounding context, existing patterns, and the closest
   tests before writing anything. Look for an existing module or helper before
   introducing a new abstraction.
2. **Branch.** `feat/short-description`, `fix/short-description`,
   `docs/short-description`, `refactor/short-description`.
3. **Implement the smallest correct diff.** Do not reformat untouched files and
   do not change architecture opportunistically.
4. **Run the closest test first**, then the full gate:

   ```sh
   mix test test/clubeira/path_to_test.exs
   mix test --failed
   mix precommit
   ```

5. **Run Dialyzer** when you change public types, contexts, or complex
   boundaries:

   ```sh
   mix dialyzer
   ```

6. **Update docs** when the architectural contract changes: `README.md`,
   `docs/architecture.md`, `docs/development.md`.

`mix precommit` formats and then runs the full quality gate: formatting check,
compilation with warnings as errors, unused dependency check, Credo strict,
`hex.audit`, `deps.audit`, Sobelow, and the test suite. **A PR that does not
pass `mix precommit` is not ready for review.**

---

## Non-negotiable invariants

These are enforced by review, tests, and the database. A PR that breaks one will
be rejected regardless of how convenient the shortcut is.

### Multi-tenancy

- All polos share a single PostgreSQL schema. Never create a schema or database
  per tenant.
- Global tables have no `polo_id`. Tenant-aware tables carry it explicitly and
  use `FORCE ROW LEVEL SECURITY`.
- Tenant-aware relations use **composite foreign keys including `polo_id`**. A
  simple FK that allows a cross-polo reference is a bug.
- Every tenant-aware operation receives an already-authorized
  `Clubeira.Tenancy.Scope` and runs inside `Clubeira.Repo.transact_in_polo/3`.
- Authenticated global discovery uses `Clubeira.Tenancy.ActorScope` and
  `Clubeira.Repo.transact_as_actor/2`.
- The web role is `clubeira_app`: no superuser, no ownership, no `BYPASSRLS`.
  Migrations and seeds use `clubeira_migrator`. Never work around RLS at
  runtime.

> **RLS is defense in depth, not business authorization.** Never treat
> `polo_id`, `user_id`, `validation_point_id`, a device ID, or any other
> client-supplied identifier as proof of permission.

### Transactional boundaries

- `Clubeira.Billing.place_order/2` is the authenticated checkout command.
- `Clubeira.Billing.settle_payment/2` is an internal port. It only accepts a
  capture whose signature and authenticity were already validated by a PSP
  adapter.
- `Clubeira.Redemptions.confirm/2` only accepts a previously authenticated
  confirmation and consumes the entitlement atomically, with idempotency and
  replay protection.
- Provider timestamps are external evidence. State transitions and validity
  windows use the database transaction clock.
- Domain events and audit records carry internal IDs and the minimum amount of
  data. **Never** include bearer tokens, passwords, CPF, encrypted contacts, or
  full sensitive payloads.

### General

- Validate external input at the edge — HTTP payloads, env vars, files, network,
  database.
- No silent fallbacks that hide a bug. Failing loudly beats degrading quietly.
- Use the already-installed `Req` for HTTP. Do not add `HTTPoison`, `Tesla`, or
  direct `:httpc` calls.
- Do not add a dependency without checking for an existing alternative in the
  project.

---

## Database changes

```sh
mix ecto.gen.migration migration_name_in_snake_case
mix db.migrate
```

- One coherent structural change per migration file. Do not group unrelated
  tables.
- Prefer `change/0`. When manual SQL requires `up/0` and `down/0`, make the
  rollback real.
- Every constraint and index must map to a concrete invariant or query.
- The project is still in early development: if a migration has not shipped and
  the fix belongs to the table's original definition, adjust that file instead
  of stacking a corrective `ALTER`.

Validate a full round trip on an empty database before submitting:

```sh
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix ecto.rollback --all
MIX_ENV=test mix ecto.migrate
```

Database changes also require the affected contract and RLS tests.

> **Never** run `docker compose down -v`, `mix db.reset`, or any other
> destructive operation against data you did not intend to lose.

---

## Testing

```sh
mix test                              # full suite
mix test test/clubeira/some_test.exs  # closest behavior first
mix test --failed                     # re-run failures
```

- Factories live in `support/factory*` and must build valid data by default.
  Domain-specific fixtures live in `test/support/<domain>/`.
- Seeds use the factories, stable structural IDs, and idempotent writes. Keep
  Faker restricted to presentation text irrelevant to the rule under test.
- Tenant-aware tests **must** exercise the real restricted role. Connecting only
  as owner or `postgres` turns the suite into a false positive.
- Concurrency tests use real isolated databases and must not be replaced with
  PostgreSQL mocks.
- Raw bearer tokens never appear in fixtures, logs, or the database.
- `CLUBEIRA_TEST_DB_POOL_SIZE` tunes the local suite pool without touching
  versioned configuration.

---

## Coding style

- `mix format` is authoritative — the CI checks it.
- Credo runs in `--strict` mode.
- Follow the existing patterns in the surrounding context before inventing a new
  one. Small duplication is acceptable; a wrong abstraction is not.
- Business rules belong in contexts, never in controllers, LiveViews, or seeds.
- Predicate functions end in `?` and do not start with `is_` (reserve `is_` for
  guards).
- Never use `String.to_atom/1` on user input.
- Programmatically-set fields such as `user_id` must not appear in `cast/3` —
  set them explicitly when building the struct.

Repository documentation is written in Brazilian Portuguese (`README.md`,
`docs/`, `AGENTS.md`). Community files (`CONTRIBUTING.md`,
`CODE_OF_CONDUCT.md`, `SECURITY.md`, issue and PR templates) are in English.
Code, identifiers, and commit messages are in English.

---

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(<scope>): <short imperative summary>
```

| Type | Use for |
|:--|:--|
| `feat` | new user-visible behavior |
| `fix` | bug fix |
| `refactor` | behavior-preserving restructuring |
| `test` | tests only |
| `docs` | documentation only |
| `chore` | tooling, dependencies, CI |
| `style` | formatting with no behavior change |

Scopes follow the domain or layer: `accounts`, `billing`, `catalog`, `db`,
`redemptions`, `reviews`, `outbox`, `polos`, `seeds`, `web`, `docs`.

Real examples from this repository:

```text
feat(reviews): add moderation workflow, backoffice endpoints, and public place feed
refactor(accounts): extract registration persistence helper
feat(db): add review moderation queue and public feed compound indexes
chore(docs): document outbox publisher worker and webhook signatures
```

Explain the *why* in the body when the change is not obvious. Keep one logical
change per commit.

---

## Pull requests

Before opening:

- [ ] `mix precommit` passes locally
- [ ] `mix dialyzer` passes if you touched public types or context boundaries
- [ ] Database changes include the migration, a verified rollback, and the
      affected contract/RLS tests
- [ ] Docs updated if the architectural contract changed
- [ ] No secrets, tokens, real credentials, or personal data in the diff

The PR description should state what changed, why, how it was validated, and
which invariants it touches. Fill in the
[pull request template](.github/PULL_REQUEST_TEMPLATE.md).

CI runs two jobs: `Quality and database contract` (role verification, full
migration round trip, quality gate, production compile, asset build) and
`Dialyzer`. Both must be green.

Reviews focus on tenant isolation, transactional atomicity, idempotency, and
data exposure. Expect questions about failure modes — answering them is part of
the contribution.

---

## Reporting security issues

Do not open a public issue for a vulnerability. Follow the process in
[SECURITY.md](SECURITY.md).
