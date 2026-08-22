# Ansible role evaluation: MariaDB (AlmaLinux 9/10 + Ubuntu 24.04)

## 1. Method

The reviewed profiles (`profiles/mariadb/*-access.yml`) and the
[dev](../apps/mariadb/dev.md)/[ops](../apps/mariadb/ops.md) docs are the
requirement rubric: a public role is scored on how much of that operable,
least-privilege target it delivers, read from the role's **code** (tasks,
templates, defaults, CI), not its README. Whatever no role delivers becomes the
spec for the org overlay. Evaluation date: **2026-08-09** — web-search findings
decay, so every activity/version claim below is dated.

## 2. Candidates

| Role | Backing | Status (as of 2026-08-09) |
|---|---|---|
| [geerlingguy.mysql](https://github.com/geerlingguy/ansible-role-mysql) (`ansible-role-mysql`) | Community, 1.1k★; the de-facto standard | **Active.** 466 commits; `min_ansible 2.12`; molecule CI green on EL10 + Ubuntu 24.04 (see R7). Installs MySQL *or* MariaDB via var overrides. |
| [fauust.mariadb](https://github.com/fauust/ansible-role-mariadb) | Community, 48★; MariaDB-native | **Active.** 282 commits; molecule incl. Galera cluster + AlmaLinux 9. Defaults to the **MariaDB Foundation repo**, not distro packages (baseline consequence — see Nuances). |
| [bertvv.mariadb](https://github.com/bertvv/ansible-role-mariadb) | Community | **Eliminated.** Last commit 2020-10-15, targets CentOS 7; ~6 years stale, no EL9/10 or Ubuntu 24.04. |
| [ansible/mariadb (solarchemist)](https://codeberg.org/ansible/mariadb) | Community, derived from geerlingguy | **Eliminated.** Ubuntu 18.04/20.04 only, MariaDB 10.4+, 0 tags, last commit 2024-02-22 — no Ubuntu 24.04, no EL. |
| linux-system-roles / rhel-system-roles | Red Hat official | **Does not exist for databases.** The System Roles catalog covers network/storage/selinux/podman/timesync/firewall/etc.; there is no mysql/mariadb role. No enterprise-official option exists. |
| debops.mariadb, lean-delivery.mysql, systemli, O-X-L | Community | Niche/framework-coupled (DebOps is Debian-only and assumes the whole DebOps harness) — not evaluated in depth. |

The DB-user/-grant layer is served by the **community.mysql collection**
(modules `mysql_user`, `mysql_db`, `mysql_query`) — that's how both live roles do
SQL-side work. It is a module collection, not a role, so it does not compete on
this rubric; the overlay depends on it.

## 3. Rubric scoring (requirements from our profile + docs)

Read from code; ✅ full / ⚠️ partial / ❌ absent, one evidence note each.

| # | Requirement (from our artifacts) | geerlingguy.mysql | fauust.mariadb |
|---|---|---|---|
| R1 | Both families, correct paths/units/accounts: EL `/etc/my.cnf.d` + Ubuntu `/etc/mysql/mariadb.conf.d`; `mariadb.service`; `mysql` account | ⚠️ `tasks/{setup-RedHat,setup-Debian}.yml` split; `defaults/main.yml` `mysql_config_include_dir: /etc/my.cnf.d`, OS-dependent `mysql_config_file` — but **MySQL-first** (needs `mysql_daemon: mariadb` + `mysql_packages` override) and `meta/main.yml` platforms list is **Ubuntu/Debian/Archlinux only — EL is not declared** | ⚠️ MariaDB-native, Debian+RHEL paths; but whole-file `templates/mariadb.cnf.j2`, not the drop-in dir our ACL targets |
| R2 | Install + configure via native package/config mechanisms | ✅ package install + `template` + community.mysql for users/dbs | ✅ package + config + Galera-aware |
| R3 | Drop-in discipline (or whole-file templating with FIM-deterministic render) | ⚠️ **whole-file** `my.cnf.j2` → `mysql_config_file` (`force: overwrite_global_mycnf`), **plus** optional drop-ins via `mysql_config_include_files` → include dir. Acceptable-with-note (see Nuances) | ⚠️ whole-file `mariadb.cnf.j2`; no drop-in mode |
| R4 | systemd hardening drop-in | ❌ none | ❌ none |
| R5 | Env/secret file management | ⚠️ writes root creds to `~/.my.cnf` (`0600`); no systemd env-file mgmt | ❌ not evident |
| R6 | **Access model** (scoped sudoers, pam_group/ACLs, the flip) | ❌ none | ❌ none |
| R7 | Verification / idempotence (molecule; which platforms) | ✅ `.github/workflows/ci.yml` molecule matrix: `rockylinux10, ubuntu2404, ubuntu2204, ubuntu2604, debian12, debian13` — **EL10 + Ubuntu 24.04 covered; EL9 not tested** | ✅ molecule default/MDBF/single+multi-node Galera; **AlmaLinux 9** + Fedora 37 — EL9 covered; alma10/ubuntu 24.04 not named |
| R8 | TLS wiring | ❌ `defaults/main.yml` has **no** SSL variables; role never places/points at certs | ❌ no explicit TLS cert management |
| R9 | logrotate policy management | ❌ manages log-file existence + `0640` perms only, **not** `/etc/logrotate.d/mariadb` | ❌ none evident |
| R10 | Maintenance & assurance for **our** versions (EL9/10, Ubuntu 24.04) | ⚠️ very actively maintained; EL10 + Ubuntu 24.04 first-class in CI; **EL9 absent from CI and EL absent from meta** | ⚠️ active but 48★; MDBF-repo default diverges from our distro-package baseline; alma10/ubuntu 24.04 not named as CI targets |

R4/R6/R8/R9 fail for **both** roles — and, as in the chrony eval, for essentially
every public service role. That is the standing gap between "make the software
run" and "make it operable and least-privilege," and R6 in particular is this
library's job.

## 4. Nuances found

**Whole-file config vs our drop-in ACL — and how to reconcile.** Our profile
grants a write ACL on the **drop-in directory** (`/etc/my.cnf.d` /
`/etc/mysql/mariadb.conf.d`) and tells humans never to touch the vendor main
file. geerlingguy templates the *whole* main file by default
(`overwrite_global_mycnf`, default `true`). Under config management this does not
conflict — it inverts, exactly like the chrony/timesync case: Ansible owns the
main file, the FIM baseline accepts the *rendered* version, and any drift from
the template becomes a tamper signal (a **stronger** property than hand-edited
drop-ins). Two conditions make it safe: (a) keep `ansible_managed` timestamp-free
so the file doesn't churn every run and train operators to ignore FIM diffs; and
(b) run the role with `overwrite_global_mycnf: false` **or** route all team-facing
settings through `mysql_config_include_files` into the drop-in dir, so the path
our ACL grants is the path humans actually edit. Recommended: whole-file main
config owned by Ansible **+** drop-in dir owned by the team ACL — the two layers
coexist.

**fauust's MariaDB-Foundation repo changes the baseline.** fauust defaults to
installing from the MDBF apt/yum repo (newer MariaDB than the distro ships). That
changes unit paths, versions, and file inventory versus our capture, which is the
**distro** `mariadb-server`. Adopting fauust would require pinning it to distro
packages, or re-capturing against the MDBF layout before the profile is valid.

**No role touches TLS, and MariaDB's key-read model is unusual.** Neither role
wires certificates, so TLS is overlay work regardless. Note the app-specific
constraint the overlay must honor (from [ops §9](../apps/mariadb/ops.md)):
`mariadbd` reads `ssl_key` as the **`mysql`** account, not root, so the key must
be `mysql`-readable (`root:mysql 0640` / `ssl-cert` group) — still root-placed,
still out of the team profile.

## 5. Verdict: adopt + wrap (do NOT build from scratch, do NOT adopt bare)

1. **Adopt `geerlingguy.mysql` as the install/config engine** for the
   distro-package path. It is the most-maintained option, its EL10 + Ubuntu 24.04
   CI matches two of our three targets, it already uses `/etc/my.cnf.d` as its
   include dir, and it pairs with community.mysql for SQL-side user/db work.
   Action items before rollout: (a) set `mysql_daemon: mariadb` +
   `mysql_packages` to the distro `mariadb-server`; (b) add **almalinux9** to a
   local molecule run — upstream CI tests only `rockylinux10`, so EL9 is
   unverified for us; (c) configure drop-in mode per Nuances. Prefer fauust only
   if first-class Galera clustering is a requirement — then pin it to distro
   packages and re-capture.
2. **Build a thin org overlay** carrying exactly the rows both roles fail — the
   payload already exists as this library's artifacts:
   - access model → **our reviewed profile + playbook 5** (`R6`) — sudoers
     scoping, log/config ACLs, the app-full→restricted flip. No public role does
     this; it is the whole point of this repo.
   - systemd hardening drop-in (`R4`) → `/etc/systemd/system/mariadb.service.d/`
     (owned by the overlay/platform, never in the team profile).
   - TLS wiring (`R8`) → cert/key placement with the `mysql`-readable key perms
     above, plus the `[mariadbd]` `ssl_*` drop-in.
   - logrotate policy (`R9`) → own `/etc/logrotate.d/mariadb`, and keep the
     `create` mode group-readable so the log-read ACL survives rotation (see
     [logging](../concepts/logging.md)).
3. **Generalize:** R4/R6/R8/R9 fail for every public role for every service —
   the same standing gap the chrony eval found. One reusable per-service overlay
   (hardening + access model + TLS + logrotate + verify/baseline-accept) covers
   it fleet-wide; the per-app reviewed profile is its access-model input.

## 6. Running the adopted role inside our access lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`) or
via platform automation — always **before capture**, so its outputs land in the
footprint like a manual install ([lifecycle](../concepts/lifecycle.md) steps
2–5). Then treadmark captures, we review, playbook 5 applies. Mapping:

| geerlingguy.mysql output | Lands in footprint as | Profile key |
|---|---|---|
| installs `mariadb-server`, enables `mariadb.service` (handler *restart mysql*) | `mariadb.service` (+ aliases/sockets) | `declarative_access_services: ['mariadb']` (aliases dropped in review) |
| `my.cnf.j2` → main file **+** `mysql_config_include_files` → include dir | config tree under `/etc/my.cnf.d` / `/etc/mysql/mariadb.conf.d` | `declarative_access_folders_modify` (the drop-in dir) |
| ensures log-error / slow-log files `0640 mysql:mysql` in `/var/log/*` | the log dir | `declarative_access_folders_read` (REVIEW-ADD) |
| package init creates `/var/lib/mysql` | data dir `mysql:mysql 0755` | `declarative_access_ownership` only — **never** a grant |
| writes root `~/.my.cnf` (`0600`) | root-only secret | **no profile key** — stays out (root-only) |
| handler restarts (no graceful reload) | — | confirms our dev-doc rule: config change = `restart`, not `reload` |

Wrap notes:

- **Pin the role version.** A version bump can change the rendered config or file
  inventory → re-capture, re-review. Treat an unpinned role as an unreviewed
  footprint change.
- **Disable features that fight the access model.** geerlingguy does **not** write
  a sudoers file and does not chown config to the service account (good). Do keep
  `overwrite_global_mycnf` deterministic and `ansible_managed` timestamp-free
  (FIM), and do **not** enable the pam_group data-dir opt-in unless a review
  accepted it ([ops §3](../apps/mariadb/ops.md)).
- **Re-running the role post-lockdown is a platform act.** If a later role run
  replaces the ACL'd drop-in dir or log files, the ACLs are shed — **re-run
  playbook 5 after** (idempotent), per the package-update rule in
  [access-model](../concepts/access-model.md).

## 7. If nothing fits

Not triggered — `geerlingguy.mysql` + community.mysql is a viable config engine.
Were it to fall over on EL9 in the local molecule gate (R7 action item), the
fallback is a ~40-line internal task file for install + drop-in config on the
Debian and EL sides (package, include-dir template, log dir), reusing the org
overlay for R4/R6/R8/R9. **Not scheduled** unless the EL9 gate fails.

## 8. Sources

- https://github.com/geerlingguy/ansible-role-mysql — repo, 1.1k★, 466 commits (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/blob/master/tasks/main.yml — task include order (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/blob/master/tasks/configure.yml — whole-file `my.cnf.j2` + include-dir drop-ins (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/blob/master/defaults/main.yml — `mysql_config_include_dir: /etc/my.cnf.d`, log vars, no SSL vars (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/blob/master/meta/main.yml — platforms Ubuntu/Debian/Archlinux (no EL) (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/blob/master/.github/workflows/ci.yml — molecule matrix rockylinux10/ubuntu2404/ubuntu2204/ubuntu2604/debian12/debian13 (2026-08-09)
- https://github.com/fauust/ansible-role-mariadb — MariaDB-native, MDBF repo, Galera molecule, AlmaLinux 9 (2026-08-09)
- https://github.com/bertvv/ansible-role-mariadb — last commit 2020-10-15, CentOS 7 (eliminated) (2026-08-09)
- https://codeberg.org/ansible/mariadb — Ubuntu 18.04/20.04, last commit 2024-02-22, 0 tags (eliminated) (2026-08-09)
- https://linux-system-roles.github.io/ + https://github.com/linux-system-roles — no mysql/mariadb system role exists (2026-08-09)
- https://galaxy.ansible.com/ui/repo/published/community/mysql/ — community.mysql modules (mysql_user/db/query) (2026-08-09)
- Requirement source: `profiles/mariadb/{almalinux-9,almalinux-10,ubuntu-24.04}-access.yml`, `docs/apps/mariadb/{dev,ops}.md`
