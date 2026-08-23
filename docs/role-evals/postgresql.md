# Ansible role evaluation: PostgreSQL (AlmaLinux 9/10, Ubuntu 24.04/26.04, Amazon Linux 2023)

## 1. Method

The reviewed PostgreSQL profiles and the [dev](../apps/postgresql/dev.md) /
[ops](../apps/postgresql/ops.md) doc pair are the requirement rubric; each
public role is scored (from its actual GitHub source, not its README) on how
much of it the role delivers, and the gap becomes the spec for our overlay.
Role findings are dated **2026-08-09** — web-search results decay, so
re-verify activity and CI before adopting. The requirement side was
refreshed **2026-08-23** against the five-distro KVM capture (ubuntu-26.04
= PostgreSQL 18, amazonlinux-2023 = `postgresql17-server`); the R1/R7/R10
rows below reflect that matrix without new candidate research.

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
| R1 | Both our families with correct paths/units/accounts — now five distros: alma9/10, ubuntu 24.04/26.04, al2023 | ❌ EL/Fedora only — `tasks/main.yml` gates on RHEL 8/9/10; no Debian family; the gate does not name Amazon Linux, so **al2023 is unverified** despite its alma-identical footprint | ⚠️ Ubuntu-first — 24.04 **and** 26.04 in CI (`ubuntu2404`/`ubuntu2604`); EL supported in `vars/RedHat.yml` but **not CI-tested** (al2023 untested too) | ⚠️ Both families in `meta` (EL 8/9, Ubuntu `noble`, Debian) but **EL10 absent**, no 26.04, no al2023 |
| R2 | Install + configure via native pkg/config mechanisms | ✅ pkg + `postgresql-setup --initdb` + templates | ✅ pkg + templates/lineinfile | ✅ pkg + templates |
| R3 | Drop-in discipline / deterministic whole-file (FIM note) | ⚠️ `postgresql.conf.j2` → internal conf + `include_if_exists` (include-style, deterministic); `pg_hba.conf.j2` full replace | ❌ `postgresql.conf` via **`lineinfile` per-option** (in-place edits of the vendor file — worst for FIM); `pg_hba.conf.j2` full template | ⚠️ **whole-file** `postgresql.conf-<ver>.j2` template (deterministic *if* `ansible_managed` is timestamp-free) |
| R4 | systemd hardening drop-ins | ❌ | ❌ | ❌ |
| R5 | Env / secret file management | ❌ (superuser password set via `psql`, `no_log` — SQL, not a file) | ❌ | ❌ |
| R6 | **Access model** (scoped sudoers, pam_group, ACLs) | ❌ | ❌ | ❌ |
| R7 | Verification / idempotence (molecule? which platforms?) | ✅ Red Hat CI (EL/Fedora) — **verify our EL9/EL10**; no Debian; **al2023 in nobody's CI** — a KVM verify run on our own al2023 image is the only assurance path | ⚠️ molecule green on `ubuntu2404` **and** `ubuntu2604` (both our Ubuntu cells); **EL path unverified** (disabled) | ⚠️ has test harness; verify `noble` + idempotence this pass; no 26.04/al2023 coverage |
| R8 | TLS wiring | ✅ `postgresql_ssl_enable` + `postgresql_cert_name` + `postgresql_certificates` (via `certificate.yml` → `fedora.linux_system_roles.certificate`) | ❌ no ssl defaults | ❌ `configure.yml` manages no cert files |
| R9 | logrotate policy management | ❌ | ❌ | ❌ |
| R10 | Maintenance & platform assurance for OUR versions (alma9/10, ubuntu 24.04/26.04, al2023) | ✅ EL9/EL10 first-class (Red Hat, v1.8.0 2026-08-06); ❌ Ubuntu; ⚠️ al2023 outside the declared platform set — assure it ourselves or don't adopt there | ✅ Ubuntu 24.04 + 26.04 (both in CI as of 2026-08-09); ⚠️ EL/al2023 not assured | ⚠️ active (PG17 landed 2026-05-30); EL 8/9 + `noble` only — **EL10, 26.04 and al2023 gaps** |

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
   **al2023 rides this bullet conditionally:** the footprint is
   alma-identical (unversioned paths, same unit, same uid), but LSR's
   platform gate does not name Amazon Linux — prove the gate passes (or
   loosen it in the wrap) on our al2023 image before adopting there;
   otherwise al2023 falls through to the thin internal task file.
2. **Ubuntu 24.04 / 26.04 → adopt `geerlingguy.postgresql`** (its molecule
   CI treats
   `noble` — and, as of 2026-08-09, `ubuntu2604` — as first-class targets)
   **and override its `lineinfile`
   `postgresql.conf` handling** — drive settings through a `conf.d` drop-in
   template instead, so the config tree our profile ACLs (16/main on 24.04,
   18/main on 26.04) stays deterministic.
   `ANXS.postgresql` is the fallback (whole-file template, both families) once
   its EL10 support lands; a thin internal Debian task file is the last
   resort, mirroring the chrony pattern. Do **not** adopt LSR here — it does
   not target the Debian family.
3. **Build the thin org overlay for the rows every role fails.** R6 (access
   model) is already delivered by this repo's PostgreSQL profiles +
   playbook 5. R4 (systemd hardening), R5 (env files) and R9 (logrotate) are
   the remaining reusable overlay payload — parameterized per service, not
   PostgreSQL-specific.

## 6. Implementing least privilege with this role

### 6a. Where the role runs in the lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`)
or via platform automation — **always before capture**, so its outputs land
in the footprint like a manual install and flow through the normal
capture → review → apply → flip pipeline
([lifecycle](../concepts/lifecycle.md)).

| Role output | Lands in footprint as | Profile key |
|---|---|---|
| Packaged unit(s) — `postgresql.service`, on Ubuntu the cluster instance (`postgresql@16-main` / `postgresql@18-main`) | `services.systemd_units[]` | `declarative_access_services` (read-only-units — **drop** `files_modify`) |
| `initdb` + started cluster | data dir `0700 postgres:postgres` | `declarative_access_ownership` assertion only — **never** granted |
| Templated/included config (LSR internal conf; geerlingguy `postgresql.conf`; ANXS whole-file) | Ubuntu: the `/etc/postgresql/16/main` (26.04: `18/main`) tree; EL: files inside the data dir | Ubuntu → `declarative_access_folders_modify` (the cluster config dir); EL → **nothing** (config is inside the closed data dir → SQL/ops) |
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

### 6b. Configuring the deployment for least privilege

What to set (and refuse to set) in the role so the install stays compatible
with the access model — scored from the same 2026-08-09 source reading as §3:

- **Keep config at vendor ownership; no role-written sudoers.** None of the
  three chowns config off its packaged state or writes sudoers today — LSR
  writes EL config inside the data dir as root, geerlingguy/ANXS leave
  Debian's tree at its packaged `postgres:postgres` — and that is exactly
  what our profiles' `ownership` entries assert. If a future version adds
  either behavior, disable it: the access model is this library's layer,
  applied by playbook 5, never the install role's.
- **Run as the packaged service account.** The EL unit carries
  `User=postgres`; Debian starts root and drops via `pg_ctlcluster`. Leave
  any service-account/ownership var at its packaged `postgres` default —
  a cluster running as a login user would put a human identity behind the
  0700 data dir and outside every grant this profile scopes.
- **Port posture: stay above 1024.** The packaged listener is 5432 — no
  capability work, no privileged bind. Keep the port at its default through
  the role's config mechanism (R3); a sub-1024 listener is an ops change
  window plus capability engineering that no candidate expresses.
- **Log to the packaged sink so the log grants hold.** Leave
  `log_destination`/`log_directory` unset: EL logs to stderr → journald
  (covered by the scoped `journalctl` grants), Ubuntu to
  `/var/log/postgresql` (covered by the read ACL). A role-templated
  `log_directory` anywhere else silently orphans the Ubuntu ACL — and on EL
  a hand-enabled collector writes into the closed data dir
  ([ops §10](../apps/postgresql/ops.md#10-logs)).
- **Secrets stay out of files.** Set the superuser password through the
  role's SQL path where offered (LSR does it via `psql` with `no_log`) — the
  catalog, not an env file. File-based env/secret management is **not
  expressible with any candidate** (R5 ❌ across the field); anything
  file-shaped waits for the org overlay, never a world-readable var file.
- **TLS through LSR's vars only.** `postgresql_ssl_enable` +
  `postgresql_certificates` place the key `0600 root` in the locations
  [ops §9](../apps/postgresql/ops.md#9-tls-key-ownership-and-rotation)
  requires. geerlingguy/ANXS manage no cert files (R8 ❌ — not expressible):
  there, ops places key material and the team points config at it via
  `conf.d`/`ALTER SYSTEM` and runs the granted `reload`.

### 6c. Applying the access profile

Once the role has deployed and the capture → review pass is done, lockdown
is one playbook run per host, then verify and flip — the full runbook is
[ops §4–§6](../apps/postgresql/ops.md#4-apply):

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/postgresql/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted"
```

All five distro profiles exist and are reviewed
(`profiles/postgresql/{almalinux-9,almalinux-10,ubuntu-24.04,ubuntu-26.04,amazonlinux-2023}-access.yml`);
run the [ops §5](../apps/postgresql/ops.md#5-verify) probes, then flip the
team out of `<hostname>-app_full`.

### 6d. Who does what after lockdown

**The application team** operates from the
[dev guide](../apps/postgresql/dev.md) — "your life after lockdown": the
granted `systemctl` verbs (umbrella + cluster unit on Ubuntu), the verbatim
`journalctl` spellings, config editing via the `conf.d` ACL on Ubuntu and
`ALTER SYSTEM` on EL, and the log-read paths, with the denied-command
playbook when something isn't granted.

**The operations team** works from the
[ops runbook](../apps/postgresql/ops.md) — the footprint evidence (§1), the
raw→reviewed decisions (§2), apply/verify/flip/revoke (§4–§7), drift and
patching (§8), TLS key custody (§9), risk triage (§11), and the data-volume
mechanics (§12–§13).

## 7. If nothing fits

Not the case here — LSR (EL9/10) + geerlingguy/ANXS (Ubuntu 24.04/26.04)
cover install and
config; al2023 is the one cell that may fall through (LSR's platform gate,
§5.1) — its fallback is a thin internal task file over the alma-identical
footprint, not a new role. The only unfilled rows are the cross-service
overlay concerns (R4
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
