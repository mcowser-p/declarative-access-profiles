# Ansible role evaluation: apache (AlmaLinux 9/10 + Ubuntu 24.04)

## 1. Method

The reviewed profiles and the [dev](../apps/apache/dev.md)/[ops](../apps/apache/ops.md)
docs are the requirement rubric; a public role is scored (R1–R10) on how
much of it the role delivers, read from the role's **code**, not its README.
What no role delivers becomes the spec for the org overlay. Evaluated
**2026-08-09** (web-search findings decay — dates are load-bearing).

## 2. Candidates

| Role | Backing | Status (verified via repo, 2026-08-09) |
|---|---|---|
| [geerlingguy.apache](https://github.com/geerlingguy/ansible-role-apache) | Community (Jeff Geerling), 431★/492 forks | **Active** — v4.2.1, last push 2026-05-18, 3 open issues. The de-facto role. |
| [bertvv.httpd](https://github.com/bertvv/ansible-role-httpd) | Community, 31★ | **Stale + EL-only** — last push 2021-08; "RHEL/CentOS 7 and Fedora 28", no Debian. Eliminated. |
| [idealista.apache_httpd_role](https://github.com/idealista/apache_httpd_role) | Community (org), 4★ | Inactive (last push 2022-02). Niche. Not evaluated in depth. |
| [Linuxfabrik lfops `apache_httpd`](https://github.com/Linuxfabrik/lfops/tree/main/roles/apache_httpd) | Community collection | Active collection, but EL-leaning and opinionated to the lfops fleet; not a drop-in for a two-family install. Not evaluated in depth. |
| linux-system-roles.* | Red Hat official | **No Apache/httpd role exists** in the linux-system-roles org (2026-08-09) — unlike nginx/timesync/postgresql there is nothing official to adopt. |

Only **geerlingguy.apache** clears the bar (active + both distro families).
It is scored below.

## 3. Rubric scoring — geerlingguy.apache @ v4.2.1

Scored from `tasks/`, `vars/`, `templates/`, `meta/main.yml`, and
`.github/workflows/ci.yml` (read 2026-08-09).

| # | Requirement | Score | Evidence (from code) |
|---|---|---|---|
| R1 | Covers both distro families (paths/units/accounts correct) | ✅ | `tasks/main.yml` includes `{{ os_family }}.yml`; `vars/RedHat.yml`/`Debian.yml` set `apache_service` (`httpd`/`apache2`) and `apache_conf_path` (`/etc/httpd/conf.d` vs `/etc/apache2`). Accounts come from the package (`apache`/`www-data`) — the role adds none, which is correct. |
| R2 | Installs + configures via native package/config mechanisms | ✅ | `package` module + version detection (`apache-24.yml`); EL vhost templated into `conf.d` (drop-in), Debian into `sites-available` + a `sites-enabled` symlink; ports templated; modules/configs enabled/disabled. |
| R3 | Drop-in discipline / whole-file determinism (FIM) | ✅ | Templates **one** managed `vhosts.conf` into the drop-in dir (not the vendor main file). `templates/vhosts.conf.j2` carries **no `ansible_managed` timestamp header** → deterministic render, FIM-clean (the chrony worked example's whole-file-under-config-mgmt reasoning applies — see §4). |
| R4 | systemd hardening drop-ins | ❌ | No `*.service.d` drop-ins. Leaves vendor units as-is (they run as root; EL10's vendor units already ship `ProtectSystem=yes`/`ProtectHome=read-only`, but the role contributes nothing). |
| R5 | Env / secret file management | ❌ | Does not manage `/etc/sysconfig/httpd` (`$OPTIONS`) or `/etc/apache2/envvars`. |
| R6 | **Access model** (scoped sudoers, pam_group, ACLs) | ❌ | None — no sudoers, no pam/sssd, no ACLs, no ownership. The standing all-roles-fail row; that gap is this library's job. |
| R7 | Verification / idempotence quality | ⚠️ | Molecule exists but the matrix is **Rocky 9, Ubuntu 22.04, Debian 11/12** — not Alma 10 or Ubuntu 24.04 (noble). Role is idempotent; our exact targets are untested upstream. |
| R8 | TLS wiring | ⚠️ | `vhosts.conf.j2` emits `SSLCertificateFile`/`SSLCertificateKeyFile` + `listen 443` from `apache_vhosts_ssl`, and `configure-*` `stat`s the cert before use. It correctly **does not place key material** (aligns with our model) — but it does **not** ensure `mod_ssl` is installed on EL (a separate package) and does not manage the cert lifecycle. |
| R9 | logrotate policy management | ❌ | No logrotate handling; relies on the package fragment. |
| R10 | Maintenance & platform assurance for OUR versions | ⚠️ | Actively maintained (v4.2.1, 2026-05), but `meta/main.yml` platforms are stale (Ubuntu `trusty/xenial/bionic`; no noble) and CI omits EL10 + 24.04. **Verify Alma 10 and Ubuntu 24.04 in molecule before rollout.** |

## 4. Nuances found

**The managed-vhost-file question (mirrors the chrony whole-file nuance).**
Our admin doctrine is drop-in-per-intention, never in-place edits of a
packaged main file. geerlingguy templates a *single* `vhosts.conf` that owns
all vhosts — a whole file, but a **drop-in**, never the vendor
`httpd.conf`/`apache2.conf`. Under config management this is not a conflict:
Ansible owns that file, so the FIM baseline accepts the *rendered* version
and any drift is a tamper signal — a stronger property than hand-edited
drop-ins, provided the template stays timestamp-free (it is). The one real
tension is with **our** access model: the reviewed profile hands the team a
**write ACL on the whole config tree**, so post-lockdown the team edits
config the role doesn't know about. Resolution in §6: the role runs in the
setup window *before* capture; after lockdown, config is the team's (tracked
by ACL), not the role's.

**mod_ssl on EL is a footprint change.** If TLS is enabled, the EL package
set must add `mod_ssl` — the role doesn't. Adding it changes the install
footprint, so it must be captured and re-reviewed (it doesn't alter the
access model, but it is not invisible).

**suexec is untouched (correctly).** The high-severity file-capability on
`/usr/sbin/suexec` ([ops §11](../apps/apache/ops.md)) is a package artifact;
neither the role nor our profile touches it.

## 5. Verdict: adopt + wrap

1. **Adopt `geerlingguy.apache` as the install/config engine.** It is the
   only active, two-family, natively-implemented option (there is no
   official Red Hat role for Apache). Its vhost templating is drop-in and
   FIM-deterministic, and it correctly leaves key material and accounts to
   the platform/package. **Pin `v4.2.1`.** Action item before rollout:
   run molecule on **AlmaLinux 10 and Ubuntu 24.04** — upstream CI is
   Rocky 9 / Ubuntu 22.04 / Debian; if EL10 or noble misbehave, patch a
   thin per-distro task overlay rather than forking the role.
2. **Build a thin org overlay** carrying exactly the rubric rows the role
   fails: R4 (systemd hardening drop-in), R5 (env-file templates), R6
   (**the access model — already delivered by this repo's reviewed profiles
   + playbook 5**), R9 (logrotate policy), and the R8 gap (ensure `mod_ssl`
   on EL; leave key material to platform).
3. **Generalize.** R4/R5/R6/R9 fail for *every* public web-server role — the
   standing gap between "make the software run" and "make it operable and
   least-privilege." One reusable overlay parameterized per service covers
   it fleet-wide; the apache profiles here are its R6 payload.

## 6. Running the adopted role inside our access lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`)
or via platform automation — **always before capture**, so its outputs land
in the treadmark footprint exactly like a manual install and flow through the
normal raw→reviewed step.

| Role output | Lands in footprint as | Profile key it maps to |
|---|---|---|
| `apache_service` state/enabled (vendor unit) | `httpd.service` / `apache2.service` | `declarative_access_services: ['httpd'/'apache2']` (read-only-units — the role emits **no** units of its own) |
| Templated vhost (`conf.d/vhosts.conf` / `sites-available/*.conf`) | config-tree files `root:root` | config **write ACL** — `folders_modify: ['/etc/httpd'/'/etc/apache2']` |
| `sites-enabled` symlink (Debian) | symlink in the config tree | same `/etc/apache2` ACL |
| DocumentRoot content (role does **not** manage content) | — (not created by the role) | setgid `ownership: /var/www/html 2775 root:<group>` (hand-added) |
| `reload apache` handler | — (runtime verb) | the granted `systemctl reload` in the `_services` sudoers — the verb that matters for cert/config pickup |
| `mod_ssl` package (only if TLS) | extra `binary`/`config` files | **re-capture + re-review** (new footprint) |

**Wrap notes.**

- **Pin the role version.** A bump can change the templated output or add
  files → re-capture, re-review, re-verify. `v4.2.1` is the pinned baseline.
- **Disable nothing that fights the model — it already doesn't fight it.**
  The role never chowns config to the service account and never writes
  sudoers/users/groups (confirmed in `tasks/`), so the read-only-units +
  config-ACL posture holds. Keep `apache_vhosts_template` timestamp-free
  (the default is) so FIM stays quiet.
- **Re-running post-lockdown is a platform act.** If a later role run
  replaces an ACL'd file (e.g. rewrites `vhosts.conf`), the file's ACL is
  shed with the replace — **re-run playbook 5 afterward** (idempotent) to
  reassert the config ACL and setgid content dir.

## 7. If nothing fits

Not applicable — geerlingguy.apache fits as the engine. The only unbuilt
piece is the shared **`org.web_baseline`** overlay (R4/R5/R6/R9 for every
web server, apache included): scope = hardening drop-in + env-file template
+ this repo's access profile apply + logrotate policy; distro matrix =
Alma 9/10 + Ubuntu 24.04; molecule = apply-then-assert on all three. Two
paragraphs of spec, **not scheduled** — the access-model half (R6) already
ships here as the reviewed profiles.

## 8. Sources

- https://github.com/geerlingguy/ansible-role-apache — `tasks/main.yml`,
  `tasks/configure-RedHat.yml`, `tasks/configure-Debian.yml`,
  `templates/vhosts.conf.j2`, `meta/main.yml`, `.github/workflows/ci.yml`
  (read 2026-08-09); tags API (v4.2.1); repo API (431★, pushed 2026-05-18,
  not archived).
- https://github.com/bertvv/ansible-role-httpd — repo API (31★, last push
  2021-08, RHEL/CentOS7/Fedora only; read 2026-08-09).
- https://github.com/idealista/apache_httpd_role — repo API (4★, last push
  2022-02; read 2026-08-09).
- https://github.com/Linuxfabrik/lfops/tree/main/roles/apache_httpd
  (read 2026-08-09).
- https://github.com/orgs/linux-system-roles/repositories — no httpd/apache
  role present (read 2026-08-09).
- Requirement source: `profiles/apache/*-access.yml`,
  `docs/apps/apache/{dev,ops}.md`.
