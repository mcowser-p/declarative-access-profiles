# Ansible role evaluation: MySQL (AlmaLinux 9 only)

## 1. Method

The reviewed profile (`profiles/mysql/almalinux-9-access.yml`) and the
[dev](../apps/mysql/dev.md)/[ops](../apps/mysql/ops.md) docs are the requirement
rubric: a public role is scored on how much of that operable, least-privilege
target it delivers, read from the role's **code** (tasks, templates, defaults,
CI), not its README. Whatever no role delivers becomes the spec for the org
overlay. Evaluation date: **2026-08-09** — web-search findings decay, so every
activity/version claim below is dated.

MySQL in this library is **AlmaLinux 9 only** (`matrix.yml`): EL10 dropped
`mysql-server` and Ubuntu is a wave-1 scope cut, both covered by
[MariaDB](mariadb.md) on those distros. So the whole rubric here is judged
against **one** target — EL9 — which sharpens the platform-coverage rows below.

## 2. Candidates

| Role | Backing | Status (as of 2026-08-09) |
|---|---|---|
| [geerlingguy.mysql](https://github.com/geerlingguy/ansible-role-mysql) (`ansible-role-mysql`) | Community, ~1.1k★; the de-facto standard | **Active.** Latest **6.5.0, 2026-07-31**; 466 commits; `min_ansible_version: 2.12`. Installs **MySQL** (native on EL — no daemon override needed) *or* MariaDB. Molecule CI **has no EL9** (see R7). |
| [bmeme.percona_server](https://github.com/bmeme/ansible-role-percona-server) | Community, 1★ | **Active (small).** 2.x installs **Percona Server 8.x**; declares **EL 9** (Rocky/Alma/RHEL 9) + Ubuntu 24.04 noble; 34 commits. Percona repo/packaging — **not** the distro `mysql-server` (baseline consequence — see Nuances). |
| [leadlineit.mysql_server](https://github.com/leadlineit/ansible-role-mysql_server) | Community, 0★ | **Eliminated.** Targets MySQL 8.0 but **Debian (bullseye/buster) only**; no EL9. |
| [lean-delivery.mysql](https://github.com/lean-delivery/ansible-role-mysql) | Community | **Not evaluated in depth.** "MySQL and MariaDB" role; framework-adjacent, EL9-on-MySQL coverage unverified — behind geerlingguy on maintenance/adoption. |
| linux-system-roles / rhel-system-roles | Red Hat official | **Does not exist for databases.** The System Roles catalog covers network/storage/selinux/podman/timesync/firewall/etc.; there is no mysql/mariadb role. No enterprise-official option exists. |

The DB-user/-grant layer is served by the MySQL module collection — historically
**`community.mysql`** (`mysql_user`, `mysql_db`, `mysql_query`,
`mysql_variables`, `mysql_info`, `mysql_replication`). As of 2026 that collection
is **deprecated and renamed to `ansible.mysql`** (content replaced by redirects;
`community.mysql` slated for removal around Ansible 16–17) — update FQCNs in any
overlay. It is a module collection, not a role, so it does not compete on this
rubric; the overlay depends on it.

## 3. Rubric scoring (requirements from our profile + docs)

Read from code; ✅ full / ⚠️ partial / ❌ absent, one evidence note each. The
comparison column is `bmeme.percona_server` — the only candidate that declares
our sole target, EL9 — kept alongside the de-facto `geerlingguy.mysql`.

| # | Requirement (from our artifacts) | geerlingguy.mysql | bmeme.percona_server |
|---|---|---|---|
| R1 | Correct EL9 paths/units/accounts: `/etc/my.cnf.d`, `mysqld.service`, `mysql` account | ⚠️ `defaults/main.yml` `mysql_config_include_dir` OS-dependent (`/etc/my.cnf.d` on EL); RedHat default packages `mysql`/`mysql-server` → MySQL-native, `mysqld.service`, `mysql` account — all correct, **but `meta/main.yml` platforms are Ubuntu/Debian/Archlinux only; EL is not declared** | ⚠️ EL9 first-class, but installs **Percona Server** (packaging/version diverge from distro `mysql-server`); paths (`/etc/my.cnf.d`, `mysqld.service`) match, inventory does not |
| R2 | Install + configure via native package/config mechanisms | ✅ package install + `template` + `ansible.mysql`/community.mysql for users/dbs | ✅ package (Percona repo) + `mysql_server_configuration` |
| R3 | Drop-in discipline (or whole-file templating with FIM-deterministic render) | ⚠️ **whole-file** `my.cnf.j2` → task *"Copy my.cnf global MySQL configuration"* with `force: {{ overwrite_global_mycnf }}` (**default `true`**), **plus** drop-ins via `mysql_config_include_files` → include dir. Acceptable-with-note (see Nuances) | ⚠️ config via a single `mysql_server_configuration` var; whole-file oriented, no drop-in-dir mode matching our ACL target |
| R4 | systemd hardening drop-in | ❌ none (and our capture confirms the vendor unit sets no `ProtectSystem`/`NoNewPrivileges`/caps — real overlay work) | ❌ none |
| R5 | Env/secret file management | ⚠️ writes root creds to `~/.my.cnf` (`0600`); no systemd env-file mgmt | ⚠️ root-password handling only |
| R6 | **Access model** (scoped sudoers, pam_group/ACLs, the flip) | ❌ `tasks/configure.yml` has no sudoers/ACL/pam handling | ❌ none |
| R7 | Verification / idempotence (molecule; which platforms) | ⚠️ `.github/workflows/ci.yml` matrix: `rockylinux10, ubuntu2604, ubuntu2404, ubuntu2204, debian13, debian12` — **EL9 is NOT tested** (only EL10 via rockylinux10). For a role whose one job here is EL9, the one distro we need is the one it doesn't gate | ✅ molecule declares **EL9** (Rocky/Alma 9) + Ubuntu 24.04 — matches our target, but a 1★ role's gate carries less assurance |
| R8 | TLS wiring | ❌ `defaults/main.yml` defines **zero** SSL/TLS/cert variables; role never places or points at certs (note: MySQL auto-generates a self-signed pair at init — neither role manages CA-signed rotation) | ❌ no explicit TLS cert management |
| R9 | logrotate policy management | ❌ ensures log-file/dir existence + perms only, **not** `/etc/logrotate.d/mysqld` | ❌ none evident |
| R10 | Maintenance & assurance for **our** version (EL9) | ⚠️ very actively maintained (6.5.0, 2026-07-31), MySQL-native — **but EL absent from `meta`, and EL9 absent from CI**; our sole target is exactly the one upstream does not verify | ⚠️ EL9 first-class, but 1★/34-commit; Percona baseline diverges from our capture |

R4/R6/R8/R9 fail for **both** roles — and, as in the chrony and mariadb evals,
for essentially every public service role. That is the standing gap between "make
the software run" and "make it operable and least-privilege," and R6 in
particular is this library's job.

## 4. Nuances found

**The platform-coverage inversion — and why it bites harder for MySQL than
MariaDB.** In the [mariadb eval](mariadb.md), geerlingguy's `rockylinux10 +
ubuntu2404` CI matched two of our three targets. For MySQL the target set is a
single distro — **EL9** — and geerlingguy's CI tests `rockylinux10` (EL10, where
we don't even ship MySQL) but **not** EL9, while `meta/main.yml` doesn't declare
Enterprise Linux at all. So the most-maintained, MySQL-native role matches **zero
of our one** target *in its own gates*. The paths and package logic are right
(`/etc/my.cnf.d`, `mysqld.service`, `mysql` account); the assurance for EL9 is
simply not there upstream and must be supplied locally before adoption. This is
the single most important finding of this eval.

**Whole-file config vs our drop-in ACL — and how to reconcile.** Our profile
grants a write ACL on the **drop-in directory** (`/etc/my.cnf.d`) and tells
humans never to touch `/etc/my.cnf`. geerlingguy templates the *whole* main file
by default (`overwrite_global_mycnf: true`, confirmed in `defaults/main.yml`).
Under config management this does not conflict — it inverts, exactly like the
chrony/timesync and mariadb cases: Ansible owns the main file, the FIM baseline
accepts the *rendered* version, and any drift from the template becomes a tamper
signal (a **stronger** property than hand-edited drop-ins). Two conditions make
it safe: (a) keep `ansible_managed` timestamp-free so the file doesn't churn
every run and train operators to ignore FIM diffs; and (b) route all team-facing
settings through `mysql_config_include_files` into the include dir, so the path
our ACL grants is the path humans actually edit. Recommended: whole-file main
config owned by Ansible **+** drop-in dir owned by the team ACL.

**Percona changes the baseline.** `bmeme.percona_server` is the only candidate
that gates EL9, but it installs **Percona Server for MySQL** from the Percona
repo — a different package set, version cadence, and file inventory than the
distro `mysql-server` we captured. Adopting it would invalidate the current
footprint: the profile would have to be re-captured against the Percona layout
(extra components, different SELinux modules) before it is valid. Consider it
only if a Percona baseline is acceptable and the EL9 assurance is worth the swap.

**No role touches TLS, and MySQL's model is unusual.** MySQL 8 auto-generates a
self-signed CA + `server-key.pem` **inside the data directory** at first init
(the `mysql_ssl_rsa_setup` tool is in our capture), and `mysqld` reads the key as
the **`mysql`** account, not root ([ops §9](../apps/mysql/ops.md)). Neither role
wires CA-signed certs, so TLS rotation is overlay work regardless, and the
overlay must place the key `mysql`-readable (`root:mysql 0640`) — still
root-placed, still out of the team profile.

## 5. Verdict: adopt + wrap — with a mandatory EL9 gate before rollout

1. **Adopt `geerlingguy.mysql` as the install/config engine** for the
   distro-package path. It is the most-maintained option, MySQL-native on EL (no
   `mysql_daemon` override needed, unlike the MariaDB case), already uses
   `/etc/my.cnf.d` as its include dir, and pairs with `ansible.mysql` for
   SQL-side user/db work. **Mandatory action before rollout: add `almalinux9` (or
   `rockylinux9`) to a local molecule gate** — upstream CI tests only EL10
   (`rockylinux10`) and `meta` omits EL entirely, so our sole target is
   *unverified* by the role's own suite. If that gate is red, either fix forward
   or fall back per §7. Configure drop-in mode per the Nuances.
2. **Consider `bmeme.percona_server` only if** first-class EL9 gating outweighs a
   Percona baseline swap — then pin it and **re-capture** the footprint against
   the Percona layout before the profile is valid. Not the default.
3. **Build a thin org overlay** carrying exactly the rows every role fails — the
   payload already exists as this library's artifacts:
   - access model → **our reviewed profile + playbook 5** (`R6`) — sudoers
     scoping, config/log ACLs, the app-full→restricted flip. No public role does
     this; it is the whole point of this repo.
   - systemd hardening drop-in (`R4`) → `/etc/systemd/system/mysqld.service.d/`
     (owned by the overlay/platform, **never** in the team profile — a unit-
     drop-in write ACL is root-equivalent).
   - TLS wiring (`R8`) → CA-signed cert/key placement with the `mysql`-readable
     key perms above, plus the `[mysqld]` `ssl_*` drop-in.
   - logrotate policy (`R9`) → own `/etc/logrotate.d/mysqld`, keep the `create`
     mode group-readable so the log-read ACL survives rotation (see
     [logging](../concepts/logging.md)).
4. **Generalize:** R4/R6/R8/R9 fail for every public role for every service — the
   same standing gap the chrony and mariadb evals found. One reusable per-service
   overlay (hardening + access model + TLS + logrotate + verify/baseline-accept)
   covers it fleet-wide; the per-app reviewed profile is its access-model input.

## 6. Running the adopted role inside our access lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`) or
via platform automation — always **before capture**, so its outputs land in the
footprint like a manual install ([lifecycle](../concepts/lifecycle.md) steps
2–5). Then cairn captures, we review, playbook 5 applies. Mapping:

| geerlingguy.mysql output | Lands in footprint as | Profile key |
|---|---|---|
| installs `mysql-server`, enables `mysqld.service` (handler *restart mysql*) | `mysqld.service` (+ `mysqld@.service` template) | `declarative_access_services: ['mysqld']` |
| `my.cnf.j2` → `/etc/my.cnf` **+** `mysql_config_include_files` → `/etc/my.cnf.d` | config tree under `/etc/my.cnf.d` | `declarative_access_folders_modify: ['/etc/my.cnf.d']` |
| ensures error/slow-log files + dir in `/var/log/mysql` | the log dir | `declarative_access_folders_read` (REVIEW-ADD) |
| package init creates `/var/lib/mysql` (+ `mysql-files`, `mysql-keyring`) | data + data-adjacent dirs | `declarative_access_ownership` only — **never** a grant |
| first init auto-generates `ca.pem`/`server-key.pem` in the data dir | key material inside the ungranted data dir | **no profile key** — rotation is ops ([ops §9](../apps/mysql/ops.md)) |
| writes root `~/.my.cnf` (`0600`) | root-only secret | **no profile key** — stays out (root-only) |
| handler restarts (no graceful reload) | — | confirms our dev-doc rule: config change = `restart`, not `reload` |

Wrap notes:

- **Pin the role version.** A bump (e.g. past 6.5.0) can change the rendered
  config or file inventory → re-capture, re-review. Treat an unpinned role as an
  unreviewed footprint change.
- **Disable features that fight the access model.** geerlingguy does **not**
  write a sudoers file and does not chown config to the service account (good).
  Keep `overwrite_global_mycnf` deterministic and `ansible_managed`
  timestamp-free (FIM), and do **not** enable the pam_group data-dir opt-in
  unless a review accepted it ([ops §3](../apps/mysql/ops.md)).
- **Re-running the role post-lockdown is a platform act.** If a later run
  replaces the ACL'd drop-in dir or log files, the ACLs are shed — **re-run
  playbook 5 after** (idempotent), per the package-update rule in
  [access-model](../concepts/access-model.md).

## 7. If nothing fits

Triggered only if the EL9 molecule gate on `geerlingguy.mysql` (the §5 action
item) fails and a Percona baseline swap is unacceptable. Fallback: a ~40-line
internal task file for the EL9 side only — `dnf install mysql-server`, enable
`mysqld.service`, render team settings into `/etc/my.cnf.d` drop-ins, ensure
`/var/log/mysql` — reusing the org overlay for R4/R6/R8/R9. Distro matrix: EL9
only (the whole MySQL scope). Molecule expectation: an `almalinux9` scenario with
allow/deny probes matching [ops §5](../apps/mysql/ops.md). **Not scheduled**
unless the EL9 gate fails.

## 8. Sources

- https://github.com/geerlingguy/ansible-role-mysql — repo, ~1.1k★, 466 commits (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/tags — latest 6.5.0, 2026-07-31 (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/blob/master/meta/main.yml — platforms Ubuntu/Debian/Archlinux (no EL); `min_ansible_version: 2.12` (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/blob/master/.github/workflows/ci.yml — molecule matrix `rockylinux10, ubuntu2604, ubuntu2404, ubuntu2204, debian13, debian12` (no EL9) (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/blob/master/defaults/main.yml — `overwrite_global_mycnf: true`, OS-dependent `mysql_config_include_dir`, **no SSL/TLS vars** (2026-08-09)
- https://github.com/geerlingguy/ansible-role-mysql/blob/master/tasks/configure.yml — whole-file `my.cnf.j2` (`force: overwrite_global_mycnf`) + include-dir drop-ins; no logrotate/sudoers (2026-08-09)
- https://github.com/bmeme/ansible-role-percona-server — Percona Server 8.x, EL9 + Ubuntu 24.04, 1★, 34 commits (2026-08-09)
- https://github.com/leadlineit/ansible-role-mysql_server — MySQL 8.0, Debian-only, 0★ (eliminated) (2026-08-09)
- https://github.com/lean-delivery/ansible-role-mysql — "MySQL and MariaDB" role (not evaluated in depth) (2026-08-09)
- https://forum.ansible.com/t/ansible-mysql-replaces-community-mysql/45798 — `community.mysql` deprecated → `ansible.mysql` (2026-08-09)
- https://github.com/ansible-collections/community.mysql — deprecation notice; modules mysql_user/db/query/etc. (2026-08-09)
- https://linux-system-roles.github.io/ + https://github.com/linux-system-roles — no mysql/mariadb system role exists (2026-08-09)
- Requirement source: `profiles/mysql/almalinux-9-access.yml`, `docs/apps/mysql/{dev,ops}.md`
