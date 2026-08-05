<!--
Thanks for the contribution.

Keep the diff as small as the change requires. If this PR touches a
transactional boundary (billing, redemptions, tenancy, outbox), make sure an
issue discussed it first.

Never include secrets, real credentials, or personal data in the diff.
-->

## Summary

<!-- What changed and why. One or two paragraphs. -->

Closes #

## Type of change

- [ ] `feat` — new user-visible behavior
- [ ] `fix` — bug fix
- [ ] `refactor` — behavior-preserving restructuring
- [ ] `test` — tests only
- [ ] `docs` — documentation only
- [ ] `chore` / `style` — tooling, dependencies, formatting

## Invariants touched

<!--
Answer explicitly, even when the answer is "none".
-->

- **Tenant isolation:**
- **Transactional boundary:**
- **Idempotency / replay:**
- **Data exposed in audit, domain events, or outbox:**

## Database changes

- [ ] No database changes
- [ ] Migration added under `priv/repo/migrations/`
- [ ] Rollback verified on an empty database (`ecto.migrate` → `ecto.rollback --all` → `ecto.migrate`)
- [ ] Tenant-aware references use composite foreign keys including `polo_id`
- [ ] New constraints and indexes map to a real invariant or query
- [ ] Contract and RLS tests updated

## Validation

<!-- Paste the commands you actually ran and their outcome. -->

```sh
mix precommit
```

- [ ] `mix precommit` passes
- [ ] `mix dialyzer` passes (required when public types, contexts, or complex boundaries changed)
- [ ] Tenant-aware tests exercise the real restricted role, not `postgres`

## Checklist

- [ ] I followed the existing patterns in the surrounding context
- [ ] Business rules live in contexts, not in controllers, LiveViews, or seeds
- [ ] External input is validated at the edge, with no silent fallback
- [ ] No new HTTP client — `Req` is the one already installed
- [ ] Docs updated (`README.md`, `docs/architecture.md`, `docs/development.md`) if the architectural contract changed
- [ ] No secrets, tokens, real credentials, or personal data in the diff
- [ ] Commits follow Conventional Commits (`type(scope): summary`)

## Notes for reviewers

<!-- Known limitations, deliberate trade-offs, follow-up slices, or areas you want scrutinized. -->
