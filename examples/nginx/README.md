# nginx — deploy least-priv, then lock down

Runnable form of [the nginx role evaluation](../../docs/role-evals/nginx.md)
(verdict: **adopt+wrap** `geerlingguy.nginx`).

1. `deploy.yml` — the role with the §6b least-priv vars (packaged service
   account, root-owned config, packaged docroot + log paths).
2. `lockdown.yml` — applies
   [`profiles/nginx/<distro>-access.yml`](../../profiles/nginx/) to
   `<hostname>-app_restricted`.

After lockdown: the team's day-2 surface is
[dev.md](../../docs/apps/nginx/dev.md); the operations runbook is
[ops.md](../../docs/apps/nginx/ops.md).
