# Ansible role evaluation: tomcat (AlmaLinux 9/10 + Ubuntu 24.04/26.04; amazonlinux-2023 N/A)

**Method.** The reviewed profiles (`profiles/tomcat/*-access.yml`) and the
[dev](../apps/tomcat/dev.md)/[ops](../apps/tomcat/ops.md) doc pair are the
requirement rubric; a public role is scored on how much of it it delivers,
reading the role's own tasks/templates (not its README). What no role delivers
becomes the spec for the org overlay. **Evaluation date: 2026-08-09** (web-search
findings decay — everything below is dated). **Matrix refresh 2026-08-23:** the
requirement set now spans the five-distro matrix — EL9/10, Ubuntu 24.04
(`tomcat10`), Ubuntu 26.04 (`tomcat11`), and amazonlinux-2023 (**N/A** — tomcat
not packaged in AL2023 core repos and no EPEL support). Candidate research was
**not** redone; R1/R7/R10 below are restated against the new matrix from the
2026-08-09 code reads.

The rubric is built from a capture of the **distro package** (`dnf install
tomcat`, `apt install tomcat10` / `tomcat11`): `/etc/tomcat[1x]` config,
`/var/lib/tomcat[1x]/webapps` group-writable to `tomcat`, `tomcat[1x].service`,
uid/gid 53 (EL) / dynamic on Ubuntu (987 / 982 in the current captures).
That framing drives the single biggest finding below.

## Candidates

| Role / collection | Backing | Status (2026-08-09) |
| --- | --- | --- |
| [middleware_automation.jws](https://github.com/ansible-middleware/jws) (`roles/jws`) | Red Hat, Inc. (community middleware; backs the JBoss Web Server product) | Active — release **2.1.4**, 2026-06-03; 8★; `min_ansible 2.16` |
| [robertdebock.tomcat](https://github.com/robertdebock/ansible-role-tomcat) | Community | Active — pushed 2026-06-29; 47★; multi-instance |
| [geerlingguy.tomcat6](https://github.com/geerlingguy/ansible-role-tomcat6) | Community (geerlingguy) | **Archived 2019-12-12; Tomcat 6 (EOL 2016) — eliminated on sight** |
| [idealista.tomcat_role](https://github.com/idealista/tomcat_role) | Community | Semi-active (2024-11-21; 13★); upstream-tarball install — not evaluated in depth |
| [zaxos](https://github.com/zaxos/tomcat-ansible-role), [vantaworks](https://github.com/vantaworks/ansible-role-tomcat), [cetic/tomcat8.5](https://github.com/cetic/ansible-role-tomcat8.5) | Community | Inactive (2021 / 2020) / **archived 2019** — not evaluated in depth |

Two roles carry the evaluation: **middleware_automation.jws** (enterprise,
EL-only) and **robertdebock.tomcat** (community, multi-distro).

## Rubric scoring

Scored from code. `✅` delivers, `⚠️` partial/conditional, `❌` absent.

| # | Requirement (from our profile + docs) | middleware_automation.jws | robertdebock.tomcat |
| --- | --- | --- | --- |
| R1 | Both distro families across the five-distro matrix, **matching our package layout** (`/etc/tomcat[1x]`, `tomcat[1x].service`, EL uid 53 / Ubuntu dynamic; amazonlinux-2023 is N/A — no distro package exists for any role to match) | ❌ EL **8/9 only** (`roles/jws/meta/main.yml`); installs the **JWS product**, not the OS `tomcat` package — no Ubuntu (24.04 or 26.04), EL10 unlisted | ❌ lists EL9/Debian/Fedora/Ubuntu (`meta/main.yml`) but installs an **upstream tarball to `/opt`** with its own unit — layout matches neither the tomcat10 nor the tomcat11 capture |
| R2 | Install + configure via **native package/config** mechanisms | ⚠️ RPM / RHN channel / archive of the JWS product (`tasks/install.yml`, `fastpackage.yml`, `rhn/`) — enterprise package mechanisms, but the JWS product, not the OS `tomcat` package | ❌ `get_url` + `unarchive` from `archive.apache.org` to `/opt` (`tasks/instance.yml`, `defaults/main.yml tomcat_mirror`) — bypasses the package manager entirely |
| R3 | Drop-in discipline / whole-file templating with the FIM note | ⚠️ whole-file templating of the JWS config | ⚠️ whole-file `server.xml.j2` + `setenv.sh.j2` per instance; header is `Ansible managed` → keep `ansible_managed` timestamp-free or every run churns the file (see the FIM note under [nuances](#nuances-found)) |
| R4 | systemd hardening drop-in (`ProtectSystem`, `PrivateTmp`, `NoNewPrivileges`) | ⚠️ generates a unit (`tasks/systemd/`); hardening not asserted | ❌ unit via `robertdebock.service` is bare (`ExecStart=catalina.sh run`, `User=/Group=` only) — none of the hardening the Debian `tomcat10.service` ships |
| R5 | Env / secret file management | ✅ `tasks/tomcat_vault.yml` (keystore/password vault), env handling | ⚠️ `setenv.sh` (`JAVA_OPTS`, `JRE_HOME`); secrets are **plaintext defaults** (`tomcat_shutdown_pass`, `tomcat_ajp_secret`) |
| R6 | **Access model** — scoped sudoers, pam_group, ACLs | ❌ writes its own systemd + firewalld; no least-privilege team-access layer | ❌ none |
| R7 | Verification / idempotence (molecule; which platforms) | ⚠️ Red Hat molecule/CI, EL-centric — none of our EL10 / Ubuntu 24.04 / Ubuntu 26.04 are targets | ✅ molecule (docker) + GitLab CI matrix across robertdebock images; ⚠️ EL10/Ubuntu 24.04 are parameterized env vars, not pinned first-class targets, and Ubuntu 26.04 predates the 2026-08-09 read (`molecule/default/molecule.yml`); AL2023 untested by either role (moot for the package shape — N/A cell) |
| R8 | TLS wiring | ✅ JWS SSL connector + vault-managed keystore password | ❌ the `<Connector port="8443">` block in `server.xml.j2` ships **commented out**; no keystore automation (DIY) |
| R9 | logrotate / self-rotation policy | ❌ no logrotate management | ❌ no logrotate; exposes juli access-log vars (`tomcat_access_log_*`) but no rotation policy |
| R10 | Maintenance & platform assurance for **our** versions (EL9/10, Ubuntu 24.04 `tomcat10`, Ubuntu 26.04 `tomcat11`; amazonlinux-2023 N/A) | ⚠️ Red Hat-backed and current, but scoped to the JWS product on EL8/9 — not our distro-package EL10/Ubuntu, and no Tomcat 11 / 26.04 story as of the 2026-08-09 read | ⚠️ active; pins Apache 7–**11** (`tomcat_version*`) to `/opt` — covers the Tomcat 11 major that 26.04 packages, but as a tarball, not our distro package; EL10/Ubuntu 24.04 via CI params only |

## Nuances found

**The defining nuance: install shape.** Every viable public role installs a
*different install shape* than the one our footprint captured. Community roles
(robertdebock, idealista, vantaworks, zaxos) install the **upstream Apache
tarball to `/opt`** with a hand-rolled unit and their own `tomcat` user;
middleware_automation.jws installs the **Red Hat JWS product**. Neither is `dnf
install tomcat` / `apt install tomcat10`. This is not a defect in the roles — the
distro packages lag Apache releases, so "download the version we want to `/opt`"
is the dominant real-world pattern — but it means the R1/R2 rows fail *against our
rubric* for a structural reason: our reviewed profiles are keyed to the OS
package's paths, unit name, and account, and would **not apply** to a `/opt`
install. Adopting any role forces a re-capture and a new profile for that shape.
The five-distro matrix sharpens the point: on **amazonlinux-2023** the
distro-package shape does not exist at all (the cell is N/A — tomcat not
packaged in AL2023 core repos, no EPEL support), so any Tomcat on AL2023 is
*necessarily* one of these non-package shapes and needs its own capture and
review from scratch — the N/A records the missing package, not an impossible
platform.

**The zero-drift deploy model does not survive a tarball install.** The library's
Tomcat access model leans entirely on the OS package shipping
`/var/lib/tomcat/webapps` as `0775 root:tomcat` (group-writable — pam_group makes
membership *mean* deploy, with no ACL and no setgid; see
[ops §3](../apps/tomcat/ops.md#3-access-model-for-this-app-class)). robertdebock
creates its webapps dir `0755 tomcat:tomcat` (owner-writable only). So under an
adopted tarball role, the "pam_group does the most" property is **lost** — the
overlay would have to add a setgid `2775` webapps dir or a content ACL back,
turning the cleanest case in the library into an ordinary webserver-style
profile. Worth stating plainly before anyone adopts.

**Whole-file `server.xml` (both roles).** Fine under config management — Ansible
owns the file, the FIM baseline accepts the *rendered* version, drift becomes a
tamper signal — provided `ansible_managed` is timestamp-free (its default can
embed a date and churn the file every run). Same calculus as the chrony
whole-file finding.

## Verdict: adopt + wrap — *conditional on install shape*; neither replaces the overlay

1. **If the org standard is the distro package** (what these profiles assume):
   **adopt no role.** `dnf install tomcat` / `apt install tomcat10` (26.04:
   `tomcat11`) is a one-line package task; wrapping it in a tarball or JWS role
   would *change* the install shape our profiles depend on. Use the profiles
   here as-is and spend the effort on the access overlay (R6). (No such option
   exists on amazonlinux-2023 — N/A, no package.)
2. **If the org standard is a pinned upstream Tomcat version** (common — distro
   Tomcat lags): **adopt `robertdebock.tomcat`** as the config engine for a
   `/opt` install (active, multi-distro, multi-instance, pins Apache 7–11), *or*
   **`middleware_automation.jws`** if you want a Red Hat-supported JWS build on
   EL and can consume the JWS content. Then **re-capture a footprint of the
   resulting layout and write a new reviewed profile** — the profiles in this
   repo are for the OS package and will not apply. Pin the role version.
3. **Build the thin org access overlay regardless.** R6 (scoped sudoers,
   pam_group into the service group, config/log ACLs) fails for *every* public
   role for *every* service — that is the standing gap between public roles
   ("make Tomcat run") and this library ("make it operable and least-privilege").
   That overlay *is* playbook 5 + these profiles.

## Implementing least privilege with this role

From "we picked this role" to "the team is locked down and knows how to
operate", in four steps. 6a/6b concern verdict case (2) (a role-driven `/opt`
install — for the distro-package shape there is no role, only the package
task); 6c/6d apply to every shape.

### 6a. Where the role runs in the lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`)
or via platform automation — always **before capture**, so its outputs land in
the footprint exactly like a manual install
([lifecycle](../concepts/lifecycle.md)).

| Role output (robertdebock `/opt` install) | Lands as | Profile key |
| --- | --- | --- |
| generated unit `/etc/systemd/system/<name>.service` (via `robertdebock.service`) | a **team-authored** unit under `/etc/systemd/system` | `declarative_access_services: [<name>]`; `files_modify` on it only if the team must edit it (`REVIEW-KEEP`), else read-only |
| `/opt/<name>/conf` (`server.xml`, `setenv.sh`) | config tree | `folders_modify` (config ACL) |
| `/opt/<name>/webapps` (`0755 tomcat:tomcat`) | deploy dir **not** group-writable | **add** setgid `2775` via `ownership` *or* a content ACL — the zero-drift model does not apply here |
| `robertdebock.service` handler (`Restart tomcat instance`) | the reload verb that matters | restart only — Tomcat has no graceful reload |
| `/opt/<name>/logs` (juli) | log dir | `folders_read` |

Wrap notes: **pin the role version** — a bump changes `tomcat_version`/the
tarball, which changes the footprint → re-capture, re-review. **Re-running the
role post-lockdown is a platform act** — it re-renders `server.xml` (an ACL'd
file), which sheds the file's ACL; **re-run playbook 5 after** (idempotent) to
restore grants.

### 6b. Configuring the deployment for least privilege

The role vars and app config that keep a robertdebock install
least-priv-compatible, scored from the role's own code (2026-08-09 read):

- **Config stays root-owned: not expressible with this role.** It chowns the
  whole `/opt/<name>` tree to the service account — acceptable for pam_group
  *read*, but it leaves `webapps/` owner-writable-only and the config files
  service-owned. The overlay corrects both: re-add group-write on `webapps/`
  (setgid `2775` or a content ACL, 6a) and put the team's config write in an
  ACL, never a chgrp to the service account. Neither role writes its own
  sudoers or PAM config, so there is no access-layer behavior to disable.
- **Run as the dedicated system account, never a login user.** The generated
  unit carries only `ExecStart`/`User=`/`Group=` — point them at the role's
  `tomcat` system account.
- **Port / capability posture.** The bare generated unit sets no
  `AmbientCapabilities=` (unlike the Debian package unit), so keep connectors
  above 1024; a sub-1024 connector is an ops unit change in a change window,
  not a team grant.
- **Secrets.** The role's `tomcat_shutdown_pass` and `tomcat_ajp_secret`
  default to plaintext literals — override them from vault; never leave the
  defaults, and never world-readable files. (middleware_automation.jws has this
  built in: `tomcat_vault.yml` manages the keystore password.)
- **TLS.** `server.xml.j2` ships the SSL connector commented out — enabling it
  is DIY; keep the PKCS12 keystore inside the team's ACL'd config tree so the
  self-service rotation model from [ops §9](../apps/tomcat/ops.md#9-tls-key-ownership-and-rotation)
  carries over.
- **Logs.** juli writes under `/opt/<name>/logs` — that dir is what the
  profile's `folders_read` grant must name. The role exposes access-log vars
  (`tomcat_access_log_*`) but no rotation policy (R9): pair with an ops-owned
  logrotate fragment or juli `maxDays`.

### 6c. Applying the access profile

Once the install is deployed and capture/review is done, lockdown is playbook 5
with the reviewed profile, then the verify pass and the flip out of app-full —
the full runbook is [ops §4–§6](../apps/tomcat/ops.md#4-apply). For the
distro-package shape the shipped profiles apply as-is (`<distro>` ∈
almalinux-9, almalinux-10, ubuntu-24.04, ubuntu-26.04 — no amazonlinux-2023
profile exists, N/A cell; note ubuntu-26.04 is `VERIFIED: pending`); for a
role-driven `/opt` install, substitute the re-captured reviewed profile of that
shape.

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/tomcat/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted"
```

### 6d. Who does what after lockdown

The **application team's** admin surface is the dev guide
([dev.md](../apps/tomcat/dev.md) — "your life after lockdown"): the granted
`systemctl` verbs on `tomcat` / `tomcat10` / `tomcat11`, the granted
`journalctl` spellings, config edits through the `/etc/tomcat[1x]` ACL, webapp
deploy through pam_group membership in `tomcat`, and the self-service keystore
flow.

The **operations team's** reference is the runbook
([ops.md](../apps/tomcat/ops.md)): footprint evidence (§1), the raw→reviewed
decisions (§2), apply/verify/flip (§4–§6), revoke and its cleanup exceptions
(§7), drift after patching (§8), and the `risks[]` triage (§11).

## If nothing fits (org overlay spec)

An `org.tomcat` install role could parameterize the install shape (distro package
*vs* pinned `/opt` tarball) and — critically — guarantee the webapps dir is
group-writable to the service group so the pam_group deploy model works zero-drift
on both shapes. Distro matrix EL9/EL10/Ubuntu 24.04/26.04 (amazonlinux-2023
reachable only via the tarball shape — no package, N/A cell); molecule asserting
the service starts, a WAR deploys via group membership, and `getfacl` shows the
default ACL on the log dir. **Not scheduled** — the access overlay (R6), which is
this library plus playbook 5, is the part that actually has no public equivalent
and is already built; a bespoke install role is only worth it if the org rejects
both the distro package and the two adoptable roles.

## Sources

- middleware_automation.jws — https://github.com/ansible-middleware/jws
  (`roles/jws/meta/main.yml`: Red Hat, EL 8/9, `min_ansible 2.16`;
  `roles/jws/tasks/`: `install.yml`, `java_install.yml`, `systemd/`,
  `firewalld.yml`, `tomcat_vault.yml`, `rhn/`, `fastpackage.yml`; release 2.1.4,
  2026-06-03) — read 2026-08-09.
- robertdebock.tomcat — https://github.com/robertdebock/ansible-role-tomcat
  (`tasks/main.yml`, `tasks/instance.yml` — `get_url`+`unarchive` to `/opt`,
  unit via `robertdebock.service`; `defaults/main.yml` — `tomcat_directory: /opt`,
  `tomcat_version: 11`, `tomcat_mirror: https://archive.apache.org`;
  `meta/main.yml` — EL9/Debian/Fedora/Ubuntu; `templates/server.xml.j2`
  (SSL connector commented out), `templates/setenv.sh.j2`;
  `molecule/default/molecule.yml`) — read 2026-08-09; repo pushed 2026-06-29.
- geerlingguy.tomcat6 — https://github.com/geerlingguy/ansible-role-tomcat6
  (archived 2019-12-12; Tomcat 6) — read 2026-08-09.
- Activity checks (GitHub API, 2026-08-09): idealista/tomcat_role (2024-11-21,
  13★), zaxos/tomcat-ansible-role (2021-12-12, 38★), vantaworks/ansible-role-tomcat
  (2020-09-17, 0★), cetic/ansible-role-tomcat8.5 (archived 2019-06-05).
- Requirement source: `profiles/tomcat/{almalinux-9,almalinux-10,ubuntu-24.04,ubuntu-26.04}-access.yml`,
  `docs/apps/tomcat/dev.md`, `docs/apps/tomcat/ops.md` (five-distro matrix per
  `matrix.yml`, refreshed 2026-08-23; amazonlinux-2023 N/A).
