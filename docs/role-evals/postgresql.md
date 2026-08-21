# Ansible role evaluation: PostgreSQL (AlmaLinux 9/10 + Ubuntu 24.04)

## 1. Method

The reviewed PostgreSQL profiles and the [dev](../apps/postgresql/dev.md) /
[ops](../apps/postgresql/ops.md) doc pair are the requirement rubric; each
public role is scored (from its actual GitHub source, not its README) on how
much of it the role delivers, and the gap becomes the spec for our overlay.
Findings are dated **2026-08-09** — web-search results decay, so re-verify
activity and CI before adopting.

## 2. Candidates

| Role | Backing | Status (as of 2026-08-09) |
|---|---|---|
| [linux-system-roles.postgresql](https://github.com/linux-system-roles/postgresql) | Red Hat official (ships in `rhel-system-roles`) | **Active**; v1.8.0 released 2026-08-06. EL-first (`tasks/main.yml` validates RHEL 8/9/10). |
| [geerlingguy.postgresql](https://github.com/geerlingguy/ansible-role-postgresql) | Community (Jeff Geerling, ~655★) | Active; molecule CI on `ubuntu2404`/`ubuntu2604`/`ubuntu2204` + Debian 11/12/13. **EL disabled** (`rockylinux9` commented out in `.github/workflows/ci.yml`). |
| [ANXS.postgresql](https://github.com/ANXS/postgresql) | Community (long-standing) | Active; last commit 2026-05-30 (PG17, Debian 13). `meta/main.yml`: EL 8/9 + Ubuntu focal/jammy/noble + Debian — **no EL10**. |
| galaxyproject.postgresql, idealista.postgresql_role, trainline-eu, claranet | Community | Niche / single-family / lower activity — not scored in depth. |

## 3. Rubric scoring

Scored from source (`tasks/`, `templates/`, `meta/`, CI), not the README.

| # | Requirement (from our profiles/docs) | linux-system-roles | geerlingguy | ANXS |
|---|---|---|---|---|
| R1 | Both our families with correct paths/units/accounts | ❌ EL/Fedora only — `tasks/main.yml` gates on RHEL 8/9/10; no Debian family | ⚠️ Ubuntu-first (incl. `noble` in `meta` + CI); EL supported in `vars/RedHat.yml` but **not CI-tested** | ⚠️ Both families in `meta` (EL 8/9, Ubuntu `noble`, Debian) but **EL10 absent** |
| R2 | Install + configure via native pkg/config mechanisms | ✅ pkg + `postgresql-setup --initdb` + templates | ✅ pkg + templates/lineinfile | ✅ pkg + templates |
| R3 | Drop-in discipline / deterministic whole-file (FIM note) | ⚠️ `postgresql.conf.j2` → internal conf + `include_if_exists` (include-style, deterministic); `pg_hba.conf.j2` full replace | ❌ `postgresql.conf` via **`lineinfile` per-option** (in-place edits of the vendor file — worst for FIM); `pg_hba.conf.j2` full template | ⚠️ **whole-file** `postgresql.conf-<ver>.j2` template (deterministic *if* `ansible_managed` is timestamp-free) |
| R4 | systemd hardening drop-ins | ❌ | ❌ | ❌ |
| R5 | Env / secret file management | ❌ (superuser password set via `psql`, `no_log` — SQL, not a file) | ❌ | ❌ |
| R6 | **Access model** (scoped sudoers, pam_group, ACLs) | ❌ | ❌ | ❌ |
| R7 | Verification / idempotence (molecule? which platforms?) | ✅ Red Hat CI (EL/Fedora) — **verify our EL9/EL10**; no Debian | ⚠️ molecule green on Ubuntu/Debian; **EL path unverified** (disabled) | ⚠️ has test harness; verify `noble` + idempotence this pass |
| R8 | TLS wiring | ✅ `postgresql_ssl_enable` + `postgresql_cert_name` + `postgresql_certificates` (via `certificate.yml` → `fedora.linux_system_roles.certificate`) | ❌ no ssl defaults | ❌ `configure.yml` manages no cert files |
| R9 | logrotate policy management | ❌ | ❌ | ❌ |
| R10 | Maintenance & platform assurance for OUR versions | ✅ EL9/EL10 first-class (Red Hat, v1.8.0 2026-08-06); ❌ Ubuntu | ✅ Ubuntu 24.04 (`noble` CI); ⚠️ EL not assured | ⚠️ active; EL 8/9 + `noble`, **EL10 gap** |

The standing finding holds: **R4, R5, R6 and R9 fail for every candidate.**
R6 (the access model) is not a PostgreSQL gap — no public role manages scoped
sudoers, pam_group, or ACLs for any service. That is exactly the gap this
library fills.

## 4. Nuances found

**The config-write mechanism splits the field, and it matters under FIM.**
Three different strategies, three different drift stories:

- **geerlingguy edits `postgresql.conf` in place with `lineinfile`**
  (`tasks/configure.yml`, "Configure global settings"). The rendered file is
  the vendor file with some lines rewritten — non-deterministic against a
  golden baseline, and the hardest to reason about when a FIM scan flags a
  change. For a config-managed host this is the weakest option.
- **ANXS templates a whole `postgresql.conf-<version>.j2`.** As with the
  chrony/timesync whole-file case, this is *stronger* than hand-edited
  drop-ins for FIM — the baseline accepts the rendered file and any deviation
  is a tamper signal — **provided** `ansible_managed` carries no timestamp
  (otherwise every run churns the file and trains operators to ignore FIM
  diffs).
- **linux-system-roles writes an internal conf and pulls it in with
  `include_if_exists`** — effectively a managed include/drop-in that leaves
  the packaged main file alone. Cleanest of the three, and it lines up with
  our own drop-in guidance (`conf.d` on Ubuntu, `ALTER SYSTEM` on EL).

All three **notify `restart`, not `reload`**, on a config change — a brief
outage on every parameter change, where our profile deliberately grants (and
[our dev guide](../apps/postgresql/dev.md) prefers) the graceful SIGHUP
`reload` for anything that doesn't require a restart. A wrap should override
the handler to `reload` where the changed parameter allows it.

**LSR writes EL config into the data dir.** LSR's `__postgresql_conf_file`
resolves inside `/var/lib/pgsql/data` on EL — the same `0700` directory our
access model keeps closed. That is fine because the role runs during the
setup window as root (before capture), and it is the concrete reason EL
config is not team-grantable afterward: the file physically lives inside the
closed data dir.

**Only LSR wires TLS.** It is also the only role that touches certificates at
all, via the shared `certificate` role. Even so it places `server.key` where
our model says it belongs — root-owned, inside the data dir (EL) — so key
rotation stays ops, exactly as [ops §9](../apps/postgresql/ops.md#9-tls-key-ownership-and-rotation)
requires.

## 5. Verdict: adopt + wrap (family-split) — do NOT force one role across both

1. **EL9 / EL10 → adopt `linux-system-roles.postgresql` as the config
   engine.** It is the only enterprise-maintained option, EL10 is
   first-class (RHEL 8/9/10 validation in `tasks/main.yml`, v1.8.0 shipped
   2026-08-06), its include-style config is the cleanest, and it is the only
   candidate that wires TLS the way ops needs. Pin the version.
2. **Ubuntu 24.04 → adopt `geerlingguy.postgresql`** (its molecule CI treats
   `noble` as a first-class target) **and override its `lineinfile`
   `postgresql.conf` handling** — drive settings through a `conf.d` drop-in
   template instead, so the config tree our profile ACLs stays deterministic.
   `ANXS.postgresql` is the fallback (whole-file template, both families) once
   its EL10 support lands; a thin internal Debian task file is the last
   resort, mirroring the chrony pattern. Do **not** adopt LSR here — it does
   not target the Debian family.
3. **Build the thin org overlay for the rows every role fails.** R6 (access
   model) is already delivered by this repo's PostgreSQL profiles +
   playbook 5. R4 (systemd hardening), R5 (env files) and R9 (logrotate) are
   the remaining reusable overlay payload — parameterized per service, not
   PostgreSQL-specific.

## 6. Running the adopted role inside our access lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`)
or via platform automation — **always before capture**, so its outputs land
in the footprint like a manual install and flow through the normal
capture → review → apply → flip pipeline
([lifecycle](../concepts/lifecycle.md)).

| Role output | Lands in footprint as | Profile key |
|---|---|---|
| Packaged unit(s) — `postgresql.service`, on Ubuntu `postgresql@16-main` | `services.systemd_units[]` | `declarative_access_services` (read-only-units — **drop** `files_modify`) |
| `initdb` + started cluster | data dir `0700 postgres:postgres` | `declarative_access_ownership` assertion only — **never** granted |
| Templated/included config (LSR internal conf; geerlingguy `postgresql.conf`; ANXS whole-file) | Ubuntu: `/etc/postgresql/16/main` tree; EL: files inside the data dir | Ubuntu → `declarative_access_folders_modify` (`/etc/postgresql/16/main`); EL → **nothing** (config is inside the closed data dir → SQL/ops) |
| TLS cert/key (LSR `certificate.yml`) | key `0600 root` in data dir (EL) / `/etc/ssl/private` via `ssl-cert` (Ubuntu) | **no key in any profile**; team gets the granted `reload` |
| Config-change handler | — | the reload-vs-restart choice: our profile grants both; wrap should prefer `reload` |
| logrotate | none of the roles write it | `/var/log/postgresql` → `declarative_access_folders_read` is **our** REVIEW-ADD (Ubuntu); EL is journal-only |

**Wrap notes.**

- **Pin the role version.** A version bump changes the rendered config /
  unit set → the footprint changes → re-capture and re-review. Treat the
  pinned role like any other input to the baseline.
- **Neutralize the handler where it fights us.** Override `restart` →
  `reload` for SIGHUP-safe parameters so routine tuning stays zero-downtime,
  matching the granted verb the team actually uses.
- **Re-running the role post-lockdown is a platform act.** LSR/geerlingguy
  rewrite `postgresql.conf`/`pg_hba.conf`; on Ubuntu that **sheds the file
  ACL** on the replaced file. The directory's default ACL re-covers *new*
  files, but re-run playbook 5 after any role run and `getfacl` to confirm
  (idempotent) — see [ops §8](../apps/postgresql/ops.md#8-drift-and-patching).
- **Do not let any role write sudoers or chown config off `postgres`.** None
  of the three do today; if a future version adds it, disable that feature —
  the access model is this library's layer, applied by playbook 5, not the
  install role's.

## 7. If nothing fits

Not the case here — LSR (EL) + geerlingguy/ANXS (Ubuntu) cover install and
config. The only unfilled rows are the cross-service overlay concerns (R4
hardening, R5 env files, R9 logrotate) plus R6, which this repo already
delivers. A dedicated `org.postgresql` install role is **not scheduled**: the
reusable `org.service_baseline`-style overlay (the same one the chrony eval
specs) carries R4/R5/R6/R9 fleet-wide, parameterized per service, with this
app's reviewed profiles as its access-model input.

## 8. Sources

- https://github.com/linux-system-roles/postgresql — `README.md`,
  `tasks/main.yml`, `meta/main.yml`, releases (v1.8.0, 2026-08-06). Fetched
  2026-08-09.
- https://github.com/geerlingguy/ansible-role-postgresql — `meta/main.yml`,
  `tasks/main.yml`, `tasks/configure.yml`, `defaults/main.yml`,
  `.github/workflows/ci.yml` (655★). Fetched 2026-08-09.
- https://github.com/ANXS/postgresql — `meta/main.yml`, `tasks/configure.yml`,
  `commits/master` (last commit 2026-05-30). Fetched 2026-08-09.
- Requirement source: `profiles/postgresql/*-access.yml`,
  `docs/apps/postgresql/{dev,ops}.md` in this repo.
