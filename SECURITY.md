# Security Policy

Clubeira handles authentication, payments, entitlements, and personal data
across multiple tenants. Security reports are treated as a priority.

## Supported versions

The project is in early development and there is no released version line yet.
Only the `main` branch receives security fixes.

| Version | Supported |
|:--|:--:|
| `main` | ✅ |
| any tag or fork | ❌ |

## Reporting a vulnerability

**Do not open a public issue, discussion, or pull request for a vulnerability.**

Report it privately through either channel:

1. **GitHub Private Vulnerability Reporting** — preferred.
   [Open a draft advisory](https://github.com/gabrielmaialva33/clubeira/security/advisories/new)
   on the Security tab.
2. **Email** — <gabrielmaialva33@gmail.com> with the subject prefix
   `[clubeira][security]`.

Please include:

- affected component, endpoint, or module (`file.ex:line` if you have it);
- the branch or commit you tested;
- a minimal reproduction: request, payload, scope, and expected vs. actual
  behavior;
- the impact you believe it has (data exposure, cross-tenant read/write,
  privilege escalation, financial impact, denial of service);
- any suggested mitigation.

Never include real personal data, production credentials, or third-party payment
tokens in the report. Redact them.

## What to expect

| Stage | Target |
|:--|:--|
| Acknowledgement | within 72 hours |
| Initial assessment and severity | within 7 days |
| Fix or documented mitigation plan | depends on severity, communicated in the assessment |
| Public disclosure | coordinated with you after a fix is available |

We will keep you updated during triage and credit you in the advisory unless you
prefer to stay anonymous.

## Scope

Especially interested in reports involving:

- **Cross-tenant access** — any path that reads or writes data of a polo outside
  the active scope, bypasses `FORCE ROW LEVEL SECURITY`, or exploits a
  non-composite foreign key.
- **Authorization** — treating a client-supplied `polo_id`, `user_id`,
  `validation_point_id`, device ID, or role claim as proof of permission.
- **Authentication** — session token forgery, fixation, or replay; weaknesses in
  Argon2id parameters or in the password credential flow; rate-limit bypass.
- **Payments** — accepting an unauthenticated capture, forging or replaying a
  Mercado Pago webhook, bypassing HMAC verification, or double-provisioning a
  contract from a single payment.
- **Redemptions** — forging or replaying a redemption grant, reusing a nonce,
  bypassing validation point credentials, or consuming an allocation twice.
- **Data exposure** — secrets, bearer tokens, CPF, encrypted contacts, or full
  sensitive payloads leaking into logs, audit records, domain events, or the
  outbox.
- **Idempotency and transactional integrity** — any path that leaves the
  database in a partially committed business state.

## Out of scope

- Findings that only apply to the local demo scenario, including the documented
  seed passwords and the demo validation key in `README.md`. Those are local
  fixtures and must be replaced in any shared environment.
- Missing hardening that the documentation already declares as an operator
  responsibility, such as the ingress rate limit required to enforce the cluster
  ceiling, or trusted-proxy configuration for `conn.remote_ip`.
- Vulnerabilities in third-party dependencies without a demonstrated impact on
  Clubeira. Report those upstream; `mix deps.audit` and `mix hex.audit` run in
  CI.
- Reports produced only by automated scanners with no reproduction or impact
  analysis.
- Denial of service through unrealistic traffic volume, social engineering,
  physical attacks, and self-XSS.

## Safe harbor

We will not pursue or support legal action against research conducted in good
faith that respects this policy: no data destruction, no access to data that is
not yours, no privacy violation, no service degradation, and private disclosure
before going public. Test against your own local environment — never against a
production deployment you do not own.
