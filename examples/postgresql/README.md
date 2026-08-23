# postgresql — deploy least-priv, then lock down

Runnable form of
[the postgresql role evaluation](../../docs/role-evals/postgresql.md)
(verdict: adopt `geerlingguy.postgresql` on Ubuntu; EL/AL2023 gated on
local molecule).

Database-class example: the profile is **config-scoped** — config + logs
via ACL, no pam_group into `postgres`, and the data directory is never
granted. Disk layout for the data volume (own volume, attaching a disk to
a holy-qcow VM, growth) is
[ops.md §13](../../docs/apps/postgresql/ops.md).

After lockdown: [dev.md](../../docs/apps/postgresql/dev.md) for the team,
[ops.md](../../docs/apps/postgresql/ops.md) for operations.
