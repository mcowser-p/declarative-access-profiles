# caddy — deploy least-priv, then lock down

Runnable form of [the caddy role evaluation](../../docs/role-evals/caddy.md)
(verdict: **build (thin)** — no public role reproduces the packaged
install; `deploy.yml` is the thin build).

Caddy inverts the usual TLS doctrine: it issues and rotates its own keys
inside `/var/lib/caddy`, which no profile ever grants — static platform
certs need a per-user ACL on the key, not group-read
([ops.md §9](../../docs/apps/caddy/ops.md)).

After lockdown: [dev.md](../../docs/apps/caddy/dev.md) for the team,
[ops.md](../../docs/apps/caddy/ops.md) for operations.
