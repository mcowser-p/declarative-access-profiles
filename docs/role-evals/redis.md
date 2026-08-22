# Ansible role evaluation: redis / valkey (AlmaLinux 9/10 + Ubuntu 24.04)

## 1. Method

The reviewed profiles and the [dev](../apps/redis/dev.md)/[ops](../apps/redis/ops.md)
docs are the requirement rubric; a public role is scored (R1–R10) on how much of
it the role delivers, read from the role's **code**, not its README. What no role
delivers becomes the spec for the org overlay. Evaluated **2026-08-09**
(web-search findings decay — dates are load-bearing). Note the distro split:
AlmaLinux 10 ships **valkey**, not redis, and that split is itself a scoring axis.

## 2. Candidates

| Role | Backing | Status (verified via repo, 2026-08-09) |
|---|---|---|
| [geerlingguy.redis](https://github.com/geerlingguy/ansible-role-redis) | Community (Jeff Geerling) | **Active** — tag `1.9.1` (2025-10-17), last commit 2025-11-28. The de-facto role. Scored below. |
| [DavidWittman.redis](https://github.com/DavidWittman/ansible-redis) | Community | **Source-build model + stale platforms** — installs redis by **compiling from source** (repo-install is an added option); Sentinel-rich; last commit 2025-02-15 (sporadic, ~yearly gaps); README claims "Ubuntu/Debian and RHEL/CentOS **6.x**". No valkey. Eliminated as engine (see §4). |
| [mother-of-all-self-hosting.valkey](https://github.com/mother-of-all-self-hosting/ansible-role-valkey) | Community | Runs valkey as a **Docker container wrapped in a systemd service** — not a native package install. Outside our lifecycle (we lock down native packages, not containers). Eliminated. |
| [webarch/valkey](https://git.coop/webarch/valkey) | Community (Webarchitects) | Native valkey role, but small/niche and Debian-leaning. Not evaluated in depth (no EL10 assurance surfaced). |
| linux-system-roles.* | Red Hat official | **No redis or valkey role exists** in the linux-system-roles org (2026-08-09) — nothing official to adopt, unlike timesync/postgresql. |

Only **geerlingguy.redis** clears the bar (active + native package + both distro
families for redis proper). It is scored below; its **EL10/valkey gap** is the
headline finding.

## 3. Rubric scoring — geerlingguy.redis @ 1.9.1

Scored from `tasks/main.yml`, `tasks/setup-RedHat.yml`, `tasks/setup-Debian.yml`,
`vars/RedHat.yml`, `vars/Debian.yml`, `defaults/main.yml`,
`templates/redis.conf.j2`, `meta/main.yml`, `.github/workflows/ci.yml`
(read 2026-08-09).

| # | Requirement | Score | Evidence (from code) |
|---|---|---|---|
| R1 | Covers both distro families (paths/units/accounts correct) | ⚠️ | `tasks/main.yml` includes OS-specific vars. `vars/Debian.yml`: `redis_package: redis-server`, `redis_daemon: redis-server`, `redis_conf_path: /etc/redis/redis.conf` — correct for Ubuntu 24.04. `vars/RedHat.yml`: `redis_package: redis`, `redis_daemon: redis` — correct for EL9. **EL10 is broken**: the role has no valkey awareness, and EL10 has no `redis` package (it is `valkey`, unit `valkey.service`, user/paths `valkey`). Accounts: the role creates none (the package does) — correct. |
| R2 | Installs + configures via native package/config mechanisms | ✅ | `setup-RedHat.yml`/`setup-Debian.yml` use the `package` module (`redis_enablerepo: epel` default on EL); config via a whole-file Jinja template to `redis_conf_path`, extensible via `redis_extra_config` + `redis_includes`. |
| R3 | Drop-in discipline / whole-file determinism (FIM) | ⚠️ | redis has **no `conf.d` model** — one `redis.conf` + `include`s — so a whole-file template is the only option; `redis_includes` is the drop-in analogue. But `redis.conf.j2` starts with `# {{ ansible_managed }}`, and the default `ansible_managed` embeds a timestamp → the file churns every run and trains operators to ignore FIM diffs. Set `ansible_managed` timestamp-free (the chrony/apache whole-file nuance applies — §4). |
| R4 | systemd hardening drop-ins | ❌ | No `*.service.d` drop-ins. (The Debian vendor unit already ships heavy hardening — `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`, `MemoryDenyWriteExecute` — while the EL/valkey vendor units ship almost none; the role contributes to neither.) |
| R5 | Env / secret file management | ⚠️ | `redis_requirepass` is templated **inline into `redis.conf`** (mode 0640), not a separate secret file; the role does not manage `/etc/default/redis-server` or `/etc/sysconfig/valkey`. Password-in-config is workable under our config ACL but is not secret-file hygiene. |
| R6 | **Access model** (scoped sudoers, pam_group, ACLs) | ❌ | None — no sudoers, pam/sssd, ACLs, or ownership in `tasks/`. The standing all-roles-fail row; that gap is this library's job (delivered by the reviewed profiles + playbook 5). |
| R7 | Verification / idempotence quality | ⚠️ | `.github/workflows/ci.yml` molecule matrix = **ubuntu2404, debian12, rockylinux9** → Ubuntu 24.04 ✅ and EL9-family (Rocky 9) ✅, but **no Alma 10 / valkey**. Role is idempotent; our EL10 target is untested upstream. |
| R8 | TLS wiring | ❌ | `defaults/main.yml` and `redis.conf.j2` have **no** TLS directives (`tls-port`, `tls-cert-file`, `tls-key-file` absent). TLS must be added via `redis_extra_config`/`redis_includes` by hand. |
| R9 | logrotate policy management | ❌ | No logrotate handling; relies on the package fragment (`/etc/logrotate.d/redis*`). Note `redis_logfile` defaults to `/var/log/redis/redis-server.log` — applying that on **EL switches redis from journal to file logging**, a deliberate change (§6). |
| R10 | Maintenance & platform assurance for OUR versions | ⚠️ | Actively maintained (`1.9.1`, 2025-10; commits to 2025-11). Ubuntu 24.04 + Rocky 9 in CI. `meta/main.yml` lists Fedora/Debian/Ubuntu/Archlinux — **no explicit EL, no EL10, no valkey**. Verify EL10/valkey out of band before rollout. |

## 4. Nuances found

**EL10/valkey is the real gap — and it's a variable overlay, not a fork.**
Because R2's config path, package, and daemon are all variables, EL10 can in
principle be driven by overriding
`redis_package: valkey`, `redis_daemon: valkey`,
`redis_conf_path: /etc/valkey/valkey.conf`. `valkey.conf` is redis-config-
compatible, so `redis.conf.j2` *should* render a valid file — but this is
**unverified upstream** (valkey is not in the role's CI, meta, or vars). Treat
EL10 as a thin per-distro overlay (vars + a molecule run), mirroring the chrony
eval's "fall back to a small internal task for the family the role doesn't
cover." If the template diverges from valkey's expectations, a ~20-line internal
`valkey`-package task is the fallback — do **not** fork the whole role.

**The whole-file question (mirrors chrony/apache).** Our admin doctrine is
drop-in-per-intention, but redis genuinely has no drop-in dir. geerlingguy owning
the whole `redis.conf` is fine under config management — the FIM baseline accepts
the *rendered* file, so drift is a tamper signal — **provided** the
`ansible_managed` timestamp is stripped. The real tension is with **our** access
model: the reviewed profile hands the team a **write ACL on `/etc/redis`**, so
post-lockdown the team edits config the role doesn't know about. Clean seam:
let the role own `redis.conf` (setup window, before capture) and give the team an
`include`d file (`redis_includes`) to own after lockdown — see §6.

**No graceful reload — the handler is `restart`, and that's correct.** redis has
no zero-downtime config reload; the role's `restart redis` handler (not a reload)
is the right verb, and it is the verb our profile grants. Cert/config pickup is a
brief-outage `systemctl restart`, unlike apache/nginx `reload`.

**Password-in-config.** `redis_requirepass` lands in `redis.conf` inside our
config-ACL tree, so the team *can* rotate it — but for secret hygiene prefer an
`include`d file with tight perms over the main config, and never co-locate TLS
key material there.

## 5. Verdict: adopt + wrap (redis); overlay for valkey

1. **Adopt `geerlingguy.redis` as the install/config engine for redis** —
   **EL9 and Ubuntu 24.04**. It is the only active, native, two-family option
   (DavidWittman is source-build + stale; the valkey roles are container/niche;
   Red Hat ships nothing). Pin **`1.9.1`**. It correctly leaves accounts to the
   package and writes no sudoers/users/ACLs, so it does not fight the
   read-only-units + config-ACL posture.
2. **Overlay for EL10/valkey.** Drive the same role with valkey vars
   (`redis_package/redis_daemon/redis_conf_path`) and **verify in molecule on
   Alma 10** before rollout; keep a ~20-line internal valkey task as the fallback
   if the config template diverges. This is the only place a public role does not
   cover a target out of the box.
3. **Build a thin org overlay** carrying the rubric rows the role fails: R4
   (systemd hardening drop-in), R5 (secret/env-file hygiene), R6 (**the access
   model — already delivered by this repo's reviewed profiles + playbook 5**),
   R8 (TLS wiring, with key material left to platform), R9 (logrotate policy).
4. **Generalize.** R4/R5/R6/R8/R9 fail for *every* public data-store role — the
   standing gap between "make the software run" and "make it operable and
   least-privilege." One reusable overlay parameterized per service covers it
   fleet-wide; the redis profiles here are its R6 payload.

## 6. Running the adopted role inside our access lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`) or
via platform automation — **always before capture**, so its outputs land in the
treadmark footprint exactly like a manual install and flow through the normal
raw→reviewed step.

| Role output | Lands in footprint as | Profile key it maps to |
|---|---|---|
| `redis_package` installed + vendor unit started/enabled | `redis.service` / `valkey.service` / `redis-server.service` | `declarative_access_services` (read-only-units — the role emits **no** unit of its own; Sentinel dropped at review) |
| Templated whole-file config at `redis_conf_path` | config-tree file (`<user>:root 0640` EL; `redis:redis 0640` Deb) | config **write ACL** — `folders_modify: ['/etc/redis'/'/etc/valkey']` |
| Package-created `redis`/`valkey` user + `/var/lib/redis(valkey)` | account + `state_dir` in footprint | `ownership` kept as captured; **data dir never granted** |
| `redis_requirepass` (inline in config) | secret inside the config file | inside the config ACL (team can rotate) — wrap note: prefer an `include`d secret file |
| `redis_logfile` set (default `/var/log/redis/...`) | file-log dir (and on EL, a switch away from journal) | log **read ACL** — `folders_read: ['/var/log/redis'/'/var/log/valkey']` |
| `restart redis` handler | — (runtime verb) | the granted `systemctl restart` in `_services` — the verb that matters (no graceful reload) |

**Wrap notes.**

- **Pin the role version.** `1.9.1` is the baseline; a bump can change the
  templated output or files → re-capture, re-review, re-verify.
- **Strip the `ansible_managed` timestamp** (`redis.conf.j2` header) so FIM stays
  quiet on repeated runs.
- **EL10:** set the valkey vars (§5.2) and re-verify — the role has no built-in
  valkey path.
- **Decide the logging model deliberately.** Leaving `redis_logfile` at its
  default turns on **file** logging on EL, diverging from the journal-default our
  ops doc documents; either accept it (and rely on the `/var/log` read ACL) or
  set `redis_logfile: ""` to keep journal logging.
- **Re-running post-lockdown is a platform act.** A later role run re-templates
  `redis.conf` and **sheds its ACL** with the file replace — **re-run playbook 5
  afterward** (idempotent) to reassert the config ACL. Give the team an
  `include`d file to own so their edits survive role re-runs.

## 7. If nothing fits

Not applicable — geerlingguy.redis fits as the engine for redis. The two unbuilt
pieces: (a) the **valkey overlay** for EL10 (vars + molecule verify, fallback a
20-line internal task); and (b) the shared **`org.cache_baseline`** overlay
(R4/R5/R6/R8/R9 for every cache/data-store): scope = hardening drop-in +
secret/env hygiene + this repo's access-profile apply + TLS wiring (key material
to platform) + logrotate policy; distro matrix = Alma 9/10 + Ubuntu 24.04;
molecule = apply-then-assert on all three. **Not scheduled** — the access-model
half (R6) already ships here as the reviewed profiles.

## 8. Sources

- https://github.com/geerlingguy/ansible-role-redis — `tasks/main.yml`,
  `tasks/setup-RedHat.yml`, `tasks/setup-Debian.yml`, `vars/RedHat.yml`,
  `vars/Debian.yml`, `defaults/main.yml`, `templates/redis.conf.j2`,
  `meta/main.yml`, `.github/workflows/ci.yml` (read 2026-08-09); tags API
  (`1.9.1`, 2025-10-17); commits (last 2025-11-28).
- https://github.com/DavidWittman/ansible-redis — README + commits API (source
  build; last commit 2025-02-15; RHEL/CentOS 6.x + Ubuntu/Debian; read
  2026-08-09).
- https://github.com/mother-of-all-self-hosting/ansible-role-valkey — README
  (Docker-container-in-systemd model; read 2026-08-09).
- https://git.coop/webarch/valkey — repo (native valkey role, niche; read
  2026-08-09).
- https://github.com/orgs/linux-system-roles/repositories — no redis/valkey role
  present (read 2026-08-09).
- Requirement source: `profiles/redis/*-access.yml`,
  `docs/apps/redis/{dev,ops}.md`.
