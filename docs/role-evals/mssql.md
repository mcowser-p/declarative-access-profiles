# Ansible role evaluation: Microsoft SQL Server

_Linux (AlmaLinux 9/10, Ubuntu 24.04) in §1–§7; **Windows Server 2022/2025 in §8**,
which is a separate evaluation with different candidates and a different answer._

## 1. Method

The reviewed profiles (`profiles/mssql/<distro>-access.yml`) and the
[dev](../apps/mssql/dev.md)/[ops](../apps/mssql/ops.md) docs are the requirement
rubric: a public role is scored on how much of that operable, least-privilege
target it delivers, read from the role's **code and CI**, not its README.
Whatever no role delivers becomes the spec for the org overlay. Evaluation
date: **2026-08-29** — web-search findings decay, so every activity/version
claim below is dated.

mssql covers **three cells** (`matrix.yml`): almalinux-9, almalinux-10 and
ubuntu-24.04 — SQL Server 2025's Linux support matrix is RHEL 9/10 and
Ubuntu 24.04, so **ubuntu-26.04** and **amazonlinux-2023** are N/A by
Microsoft's own support boundary, not by packaging accident. One fact shapes
this whole eval: the app is ONE package on every distro (`mssql-server` from
packages.microsoft.com), and the **edition** — Express through Enterprise —
is decided by `MSSQL_PID` at `mssql-conf setup`, after install.

## 2. Candidates

| Role | Backing | Status (as of 2026-08-29) |
|---|---|---|
| [microsoft.sql.server](https://github.com/linux-system-roles/mssql) (`linux-system-roles/mssql`) | **Vendor-official**: Microsoft collection, engineered by Red Hat's linux-system-roles team; 34★, 401 commits | **Active.** Latest **2.6.6, 2026-02-06**; ansible-lint + ansible-test + TFT integration CI. **RHEL-only** (the system-roles charter); declares SQL Server **2017/2019/2022** — no 2025 as of the eval date. Rich surface: `mssql_edition` (every edition or a product key), per-component EULA vars, `mssql_ha_configure` (Always On AGs via **Pacemaker**), `mssql_tls_enable`/`mssql_tls_cert`/`mssql_tls_private_key`, `mssql_datadir`/`mssql_logdir` with SELinux context handling |
| [lowlydba.sqlserver](https://github.com/LowlyDBA/lowlydba.sqlserver) | Community, in the Ansible package | **Active.** 2.8.1; a **module collection wrapping dbatools** (PowerShell) that configures a *running* instance — databases, logins, AGs, jobs. Not an installer role, so it does not compete on this rubric; it is the SQL-side complement, exactly the position `ansible.mysql` holds in the mysql eval |
| [thomasliddledba/ansible-role_mssql](https://github.com/thomasliddledba/ansible-role_mssql) | Community, 2★ | **Eliminated.** RHEL/CentOS **7** + SQL Server **2017**, 11 commits, dormant |
| [kyleabenson/ansible-role-mssql](https://github.com/kyleabenson/ansible-role-mssql) | Community | **Eliminated on sight.** RHEL demo-scale role from the SQL-2017-on-RHEL announcement era; superseded by the system role above |

## 3. Rubric scoring (requirements from our profile + docs)

Scored for `microsoft.sql.server` only — nothing else survived §2.

| # | Requirement (from our artifacts) | microsoft.sql.server |
|---|---|---|
| R1 | Correct paths/units/accounts on all three targets (EL 9/10 + Ubuntu 24.04; `mssql-server.service`, `mssql` account everywhere) | ❌ **RHEL-only by charter** — no Debian-family vars, tasks or CI at all. Two of our three cells it simply cannot reach; on the EL cells the paths/unit/account are right |
| R2 | Install + configure via native mechanisms (packages.microsoft.com + `mssql-conf`) | ✅ configures the Microsoft repo, installs `mssql-server`, drives `mssql-conf` non-interactively |
| R3 | Drop-in discipline / deterministic config | ⚠️ SQL Server on Linux has **no drop-in model** — settings live in `mssql.conf` inside the data root and are written by the `mssql-conf` tool, which the role drives. Nothing for a team ACL to target (consistent with our profile granting **no** config path — see ops §3) |
| R4 | systemd hardening drop-ins | ❌ none; the vendor unit ships unhardened and the role adds nothing |
| R5 | Env/secret file management | ⚠️ passwords enter as role vars (`mssql_password`, no_log); no managed env file. Our db-lab overlay keeps `SQLCMDPASSWORD` in a root-only `EnvironmentFile` instead |
| R6 | **Access model** (scoped sudoers, ACLs, the flip) | ❌ the standing all-roles-fail row; this library's job |
| R7 | Verification / idempotence quality | ⚠️ real CI (ansible-test + TFT integration on RHEL) — strongest assurance of any candidate, but only for the platform half it covers |
| R8 | TLS wiring | ✅ **rare genuine pass**: `mssql_tls_enable` + cert/key placement vars, driving `network.tlscert`/`tlskey` via mssql-conf |
| R9 | logrotate policy management | ⚠️ inapplicable-by-design: the errorlog self-cycles (`errorlog.numerrorlogs`), no `/etc/logrotate.d` file exists to manage — see ops §10 |
| R10 | Maintenance & assurance for OUR cells (EL9/10, Ubuntu 24.04, SQL Server **2025**) | ⚠️ actively maintained and RHEL-9-assured, but `mssql_version` stops at **2022** as of 2026-08-29 — our fleet installs 2025 — and Ubuntu is out of charter permanently |

## 4. Nuances found

**The Ubuntu hole is structural, not a backlog item.** linux-system-roles is a
Red Hat product line; Ubuntu support is out of charter, not merely missing.
For a matrix that commits to both families (the same reason the mysql clusters
span alma9 and ubuntu), a role that can never cover one family fails R1 in a
way no release will fix.

**The version lag is the second structural problem.** The role's
`mssql_version` accepts 2017/2019/2022; the fleet deploys **SQL Server 2025**
(GA 2025-11, CU8 current). History says support arrives eventually — but
"eventually" means the org overlay must exist NOW, and once it exists for both
families the role's remaining value on the EL cells is repo setup and
`mssql-conf` calls, which is ~30 lines of the overlay.

**HA shape mismatch.** `mssql_ha_configure` wires Always On AGs **through
Pacemaker** (the RHEL HA add-on) — automatic failover, fencing, the full
cluster stack. The db-lab's DR target is deliberately lighter: a clusterless
read-scale AG (`CLUSTER_TYPE = NONE`, certificate-auth endpoint) on the
Enterprise-class cluster, and a scripted log-restore standby on Express, which
has no AG at all. The role has no clusterless mode and nothing for Express —
the two shapes the lab actually proves.

**The dbatools complement.** `lowlydba.sqlserver` occupies the same position
`ansible.mysql` does for mysql: SQL-side objects (logins, databases, AG
membership, agent jobs) on an already-running instance. It requires PowerShell
+ dbatools on the controller or target, which is a real dependency decision —
the db-lab overlay stays with `sqlcmd` and guarded T-SQL instead, but a larger
estate automating many instances should evaluate it.

## 5. Verdict: build — a thin org role, with the system role as the EL-only reference

1. **Build the thin org role.** It exists and is the reference implementation:
   `app-vending-machine/labs/db/ansible/roles/mssql` — Microsoft repo setup
   for both families (including the noble signed-by keyring trap, §8 sources),
   unattended `mssql-conf -n setup` with `MSSQL_PID` from cluster config,
   root-only credential env file, firewall scoping, and the per-edition DR
   plumbing (clusterless AG / scripted standby) that no public role
   expresses. ~450 lines covering everything R1–R10 need on our cells except
   R4 (tracked as overlay work, same as every other engine).
2. **Do not adopt `microsoft.sql.server` for the fleet** while it cannot
   reach Ubuntu 24.04 and cannot install 2025 — that is two of three cells
   and the only SQL Server version we ship. Re-check at the next eval date;
   if 2025 lands, it becomes the natural EL-side install engine and the org
   role shrinks to the Ubuntu half plus the DR overlay.
3. **Keep `lowlydba.sqlserver` on the radar** for SQL-side estate management;
   it is out of scope for install/lockdown and carries a PowerShell+dbatools
   dependency the lab does not want.

## 6. Implementing least privilege with this role

"This role" here is the org role (§5.1); the mapping is identical if the
system role ever takes the EL half.

### 6a. Where the role runs in the lifecycle

During the **setup window** (executor in `<hostname>-app_full`) or via
platform automation — always **before capture**, so its outputs land in the
footprint like a manual install. Mapping:

| Role output | Lands in footprint as | Profile key |
|---|---|---|
| installs `mssql-server` (+ deps: gdb toolchain; saslauthd on EL) | `mssql-server.service` unit, `mssql` account, `/opt/mssql` tree | `declarative_access_services: ['mssql-server']` — deps are REVIEW-DROPPED (ops §2) |
| `mssql-conf -n setup` (edition, sa password, memory cap) | **nothing** — capture runs pre-setup on purpose, keeping the footprint edition-neutral | no key; `/var/opt/mssql` is born 0700 `mssql:mssql` at setup and is never grantable (ops §3) |
| log-backup timers + wrapper (db-lab DR plumbing) | would land as units + `/usr/local/sbin` scripts if captured post-deploy | none today — the lab applies profiles from THIS repo's capture, which predates them |
| TLS cert/key placement (when enabled) | key material, root-placed, `mssql`-readable | **no profile key** — custody is ops (ops §9) |

Wrap notes: **pin the package version** the way a role version would be pinned
— Microsoft CUs land monthly-ish and each changes the file inventory;
re-capture on a CU boundary, not on every converge. Re-running setup is
guarded (`master.mdf` sentinel) so a re-run cannot re-edition a live instance.

### 6b. Configuring the deployment for least privilege

- **Keep config root-owned:** there is no config path to hand the team —
  `mssql.conf` lives inside the closed data root and is written by
  `/opt/mssql/bin/mssql-conf` as root. Do not loosen the data root to make it
  "editable"; settings changes are ops (mssql-conf) or SQL (`sp_configure`).
- **Run as the packaged account:** setup creates and uses `mssql`; never
  point the unit at a login user.
- **Port/capability posture:** 1433 and 5022 are unprivileged; no capability
  work. Scope both to the lab CIDR at the host firewall (the db-lab role
  does).
- **Secrets:** sa's password belongs in a root-only env file consumed by a
  wrapper (`SQLCMDPASSWORD`), never on a command line, in a unit file, or in
  the granted... there are no granted paths; keep it that way.
- **Editions:** `MSSQL_PID` is deployment config, not profile config — the
  profile is edition-neutral by construction (capture never ran setup).

### 6c. Applying the access profile

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/mssql/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Then the verify pass and the flip out of app-full — the full runbook is
[ops §4–§6](../apps/mssql/ops.md#4-apply).

### 6d. Who does what after lockdown

**The application team's** admin surface is the [dev guide](../apps/mssql/dev.md):
granted systemctl verbs and journalctl spellings for `mssql-server`, and the
everything-is-SQL rule — objects, users and settings via T-SQL, not the
filesystem.

**The operations team's** reference is the [ops runbook](../apps/mssql/ops.md):
footprint evidence (§1), raw→reviewed decisions (§2), apply/verify/flip
(§4–6), drift and CU patching (§8), TLS custody (§9), risk triage (§11), and
storage mechanics (§12–13).

## 7. If nothing fits

Not applicable — §5 is already a build verdict and the build exists
(`app-vending-machine/labs/db/ansible/roles/mssql`). If that role ever needs
to stand alone in this repo's terms: scope = repo + install + unattended
setup + firewall on EL9/10 + Ubuntu 24.04, molecule with an allow/deny probe
pair per [ops §5](../apps/mssql/ops.md). **Not scheduled.**

## 8. Windows Server 2022/2025 — a separate evaluation

Added 2026-09-01, after the db lab grew a Windows tier (`mswe01` on Server 2022
Core, `mswx01` on Server 2025 Core). It is deliberately its own section rather
than extra rows above, because almost nothing transfers.

**Why the Linux answer does not apply.** On Linux, one package serves every
edition and `MSSQL_PID` at `mssql-conf setup` selects it. On Windows there is
no such switch: **the edition IS the media** — Microsoft publishes a separate
download per edition, each carrying a predefined key, so `/PID` is meaningful
only for a paid key. The media shapes differ too: the Evaluation bootstrapper
emits an **ISO**, Express emits a **self-extracting EXE**. A role that assumes
"download, mount, run setup.exe" works for Evaluation and fails for Express at
the mount. Any candidate has to be judged on installation mechanics that the
Linux candidates never face.

### 8.1 Candidates

| Role/module | Backing | Status (2026-09-01) |
|---|---|---|
| [SqlServerDsc](https://github.com/dsccommunity/SqlServerDsc) via `ansible.windows.win_dsc` | **DSC Community** (not Microsoft, despite common belief), 386★, 1303 commits | **Active and widely used.** 17.5.1 (2026-02-05), releases in Jan and Feb 2026; **14.4M downloads**; PowerShell 5.0+. Its `SqlSetup` resource installs the engine; the module also covers logins, permissions, AGs, RS |
| [lowlydba.sqlserver](https://github.com/LowlyDBA/lowlydba.sqlserver) | Community, in the Ansible package | **Active**, 2.8.1. A **dbatools wrapper that configures a RUNNING instance** — logins, databases, AG membership, agent jobs. Not an installer, so it does not compete on install; it is the natural complement |
| `microsoft.sql.server` (linux-system-roles) | Vendor-official | **Cannot reach Windows at all** — RHEL-only by charter (§2). Excluded on sight here |

### 8.2 Scoring, on the rows that differ from Linux

| # | Requirement | SqlServerDsc + win_dsc |
|---|---|---|
| R1 | Server 2022 **and** 2025 Core | ✅ version-agnostic; `SqlSetup` drives `setup.exe`, which both support |
| R2 | Install via native mechanism | ✅ that is precisely what `SqlSetup` wraps |
| R2b | **Acquire the media** | ❌ **out of scope for the module** — it consumes a `SourcePath` you must already have staged. The per-edition download, the ISO-vs-EXE shape difference and the mount/extract split are all still yours to solve |
| R5 | Secrets | ⚠️ credentials pass as DSC `PSCredential`; workable, but adds a `become`/CredSSP or DSC-credential-encryption question the SSH+PowerShell path does not have |
| R7 | Verification / assurance | ⚠️ the module itself is well-tested, but `win_dsc` + `MSFT_SqlSetup` has a long tail of reported breakage — missing CIM class, "resource not found", `Test-TargetResource` null-reference — across Ansible issue trackers |
| R10 | Dependency footprint | ⚠️ requires the DSC module chain pre-installed on every guest, and DSC itself, which nothing else in this estate uses |

### 8.3 Verdict: build (again) — but for a different reason than Linux

On Linux the verdict was *build* because the vendor role could not reach two of
three cells. Here the verdict is *build* because **the hard part is the part no
role does**: acquiring the right media per edition and handling two media
shapes. `SqlServerDsc` would install a SQL Server from media already staged —
which is the easy half — while adding DSC as a dependency this estate has
nowhere else.

Weighed against that, the org role reuses a technique **already proven in this
estate**: `labs/gmsa` installs SQL Server 2022 on Server 2022 Core unattended
today, via `setup.exe` with a rendered configuration `.ini` driven from a
one-shot scheduled task (SYSTEM context, which is what makes the install
behave). `labs/db`'s `mssql_windows` role generalises that to two editions and
two Server versions.

Two standing recommendations rather than one:

1. **Keep the org role for installation.** Revisit if DSC ever earns its place
   in this estate for other reasons — the calculus changes the moment DSC is
   already a dependency rather than a new one.
2. **Adopt `lowlydba.sqlserver` if instance MANAGEMENT grows** — declarative
   logins, databases, AG membership and agent jobs across many instances. It
   does not overlap the installer, and it is the same "adopt + wrap" shape the
   MySQL eval reached: a public module collection for the SQL-side objects, an
   org role for the deployment. It carries a PowerShell + dbatools dependency,
   which is why it is a recommendation and not a default.

### 8.4 What is proven, and what is not

The Windows tier's **infrastructure** is proven on hardware as of 2026-09-01:
both guests build from the golden images, complete the rename reboot, and
answer as themselves. The **installation** path — the SSEI bootstrapper's
flags, and Express's self-extracting-EXE branch specifically — is the part
still being exercised for the first time; `labs/db/media/` is the deterministic
fallback when a download link rots or the lab is offline. This section will be
worth re-reading once that run is on the record either way.

## 9. Sources

- https://github.com/linux-system-roles/mssql — repo, 34★, 401 commits; README: SQL Server 2017/2019/2022; RHEL platforms; `mssql_edition`, EULA vars, `mssql_ha_configure`, `mssql_tls_*`, `mssql_datadir`/`mssql_logdir` (2026-08-29)
- https://github.com/linux-system-roles/mssql/releases — latest 2.6.6, 2026-02-06 (2026-08-29)
- https://catalog.redhat.com/en/software/collection/microsoft/sql — the certified `microsoft.sql` collection (2026-08-29)
- https://github.com/LowlyDBA/lowlydba.sqlserver — dbatools-wrapping module collection, 2.8.1; cross-platform via PowerShell (2026-08-29)
- https://github.com/thomasliddledba/ansible-role_mssql — RHEL7 + SQL 2017, 2★, 11 commits (eliminated) (2026-08-29)
- https://github.com/kyleabenson/ansible-role-mssql — RHEL demo role (eliminated) (2026-08-29)
- https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-release-notes-2025?view=sql-server-ver17 — SQL Server 2025 on Linux: RHEL 9/10, Ubuntu 22.04/24.04 (2026-08-29)
- https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-editions-and-components-2025?view=sql-server-ver17 — edition feature boundaries (AG: Express **No**) (2026-08-29)
- https://github.com/dsccommunity/SqlServerDsc — DSC Community, 386★, 1303 commits; SqlSetup installs the engine (2026-09-01)
- https://www.powershellgallery.com/packages/SqlServerDsc — 17.5.1 published 2026-02-05; 14.4M downloads; PowerShell 5.0+ (2026-09-01)
- https://github.com/ansible-collections/ansible.windows/issues/32 and ansible/ansible#68246, #51543 — win_dsc + MSFT_SqlSetup failure reports (2026-09-01)
- Windows deployment reference in this estate: `app-vending-machine` labs/gmsa `roles/mssql` (SQL 2022 on Server 2022 Core) and labs/db `roles/mssql_windows` (2026-09-01)
- Requirement source: `profiles/mssql/almalinux-9-access.yml`, `docs/apps/mssql/{dev,ops}.md`, and the deployed reference `app-vending-machine/labs/db/ansible/roles/mssql`
