# Microsoft SQL Server — lockdown runbook (ops)

The operations-side reference for `profiles/mssql/`: what the installer
actually did (evidence), what the review kept and dropped, and how to apply,
verify, flip, revoke and live with the profile. The developer-facing
counterpart is [dev.md](dev.md).

One structural fact drives everything here: **the capture ran against the
package install only — `mssql-conf setup` never ran.** That is deliberate.
Setup is where the edition (`MSSQL_PID`: Express … Enterprise), the sa
password and the data root come from, so stopping before it keeps the
footprint **edition-neutral**: one profile covers an Express box and an
Enterprise Evaluation box identically, because on disk they *are* identical
until setup. It also means `/var/opt/mssql` — the data root, the unit's
`WorkingDirectory`, the `mssql` user's home — **does not exist in the
evidence**, and the profile treats it accordingly (§3).

## 1. Footprint summary (evidence)

| | almalinux-9 | almalinux-10 | ubuntu-24.04 |
|---|---|---|---|
| files added | 583 | 884 | 1371 |
| files modified | 84 | 214 | 29 |
| systemd units | 4 (`mssql-server` + `saslauthd`, each ×2 paths) | 4 (same) | 2 (`mssql-server` ×2 paths) |
| accounts created | `mssql` (home `/var/opt/mssql` — not created), `saslauth` | same | `mssql` only |
| key dirs | `/opt/mssql` (vendor tree, root:root) | same + `/etc/debuginfod` | same + `/etc/gdb` |
| security-relevant | `/etc/security/limits.d/99-mssql-server.conf` | same + debuginfod profile.d scripts | same |
| risks[] | 2 (saslauthd runs as root, ×2 unit paths) | 2 (same) | 0 |
| source | `footprints/almalinux-9/footprint-mssql.json`, schema 1.0, 2026-08-29, treadmark 0.11.0, KVM alma9-20260823 | …alma10-20260823 | …ubuntu2404-20260823 |

No sudoers files, no setuid/setgid binaries, no PAM edits, no cron jobs on
any distro. The package drops one `limits.d` file (memlock/nofile for
sqlservr) — configuration the ENGINE needs, not an access artifact. The gdb/
debuginfod toolchain rides in as a dependency for crash-dump capture, which
is where the odd `/etc/gdbinit.d`-family paths in the raws come from.

## 2. Raw → reviewed: the decisions

| Raw key (distros) | Decision | Why |
|---|---|---|
| `services: ['mssql-server']` (all) | **KEEP** | the app's own unit; the profile's entire grant surface |
| `services: ['saslauthd']` (EL only) | **REVIEW-DROP** | a dependency's daemon (cyrus-sasl, for AD auth). Runs as root — the footprint's own `risks[]` says so — and the team does not operate it. AD integration is a deliberate ops decision, not a profile side effect |
| `files_modify: [mssql-server.service, saslauthd.service ×2 paths]` | **REVIEW-DROP** | vendor unit files; a write ACL on a unit file is root-equivalent for that unit. Read-only-units profile, same as every engine here |
| `folders_modify: ['/etc/gdbinit.d']` (EL9) / `['/etc/debuginfod','/etc/gdbinit.d']` (EL10) / `['/etc/debuginfod','/etc/gdb']` (24.04) | **REVIEW-DROP** | debugger-toolchain config owned by mssql's gdb dependency; gdbinit autoload is executed by any future root gdb session. Not team config |
| `folders_modify: ['/opt/mssql']` (all) | **REVIEW-DROP** | the vendor binary tree, root:root. Write access is binary tampering, not configuration — the app's real config does not even exist yet (below) |
| ownership | **none, ON PURPOSE** | `/var/opt/mssql` is born at setup (0700 `mssql:mssql`), not at install; asserting a missing path fails the apply. The DATABASE-class rule pre-applies to it: never grantable |

## 3. Access model for this app class

**Database — config-scoped, NOT group-scoped**, with the twist that mssql has
*even less* to grant than PostgreSQL:

- **No pam_group / group membership.** Once setup runs, the `mssql` group
  owns the raw data files under `/var/opt/mssql`; membership is filesystem
  access that bypasses every server-level permission and SQL GRANT. (The raws
  carry no group grant to begin with — the review records the rule anyway,
  because the day someone "helpfully" adds one is the day it matters.)
- **No config path.** SQL Server on Linux has no `/etc` presence and no
  drop-in dir: `mssql.conf` lives INSIDE the closed data root and is written
  by `/opt/mssql/bin/mssql-conf` as root. Server settings are ops-side
  (mssql-conf + restart) or SQL-side (`sp_configure`, `ALTER SERVER
  CONFIGURATION`). There is nothing here for a team ACL to target — the
  narrowest database profile in the library, and correctly so.
- **The service grant is the whole surface**: scoped systemctl verbs +
  journalctl on `mssql-server`, via sudoers. Everything else a team does to
  SQL Server, it does over 1433 with a SQL login — which is the access model
  working as intended.
- **Editions do not change the profile.** Express and Enterprise Evaluation
  install identical bits; `MSSQL_PID` at setup is the only divergence. One
  reviewed profile per distro covers both db-lab clusters.

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/mssql/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifact checklist after a green run — shorter than most engines because the
profile grants no paths:

- `/etc/sudoers.d/mssql` — the scoped systemctl/journalctl verbs
  (`visudo -cf` it if in doubt)
- **no** setfacl targets, **no** group.conf line, **no** ownership changes,
  **no** linger

Revoke is the same command `+ --tags cleanup`.

## 5. Verify

`scripts/verify-profile-kvm.sh --app mssql <distro>` (or
`pytest --distro <distro> --app mssql`) launches a fresh golden-image guest,
installs the package (repo enable per `matrix.yml` `repos: [mssql-2025]`),
applies the profile, probes, revokes, and stamps the header on green:

- **DENY**: a foreign unit restart (`sshd`) as the team principal must be
  refused — the sudoers scoping doing its job.
- **ALLOW**: the granted-verbs listing must show the `mssql-server` verbs.
  The folders-writability probe is **structurally skipped**: this profile
  grants no `folders_modify`, and that absence is the finding, not a gap.
- **pam_group behavioral probe**: skipped — database class sets none.
- **Revoke**: `/etc/sudoers.d/` must be clean afterwards.

The stamp names the guest's self-reported image, MAC and CIS state; a profile
edit invalidates it until the next green pass.

## 6. Flip

Standard flip: remove the executor from `<hostname>-app_full` (restricted is
nested inside it already), `loginctl terminate-user <user>`, `sss_cache -E`
where SSSD is in play, and confirm on next login that `sudo -l` shows the
mssql verbs and nothing else.

## 7. Revoke / tighten later

The three standard moments (offboarding, incident, migration) all reduce to
`--tags cleanup` plus group membership. Cleanup exceptions, verbatim from the
role's contract: parent traverse ACLs remain; ownership is never reverted
(none was asserted here); linger was never granted. With no path grants,
revoke for mssql is effectively "delete the sudoers file" — audit it that way.

## 8. Drift and patching

- `rpm -V mssql-server` / `dpkg --verify mssql-server` covers the vendor tree
  under `/opt/mssql` — with no intentional ownership/setgid changes in this
  profile, ANY hit is unexplained and worth a look.
- What package verification cannot see still does not matter here: there are
  no file ACLs to shed. A package update can, however, replace the unit file
  and drop nothing of ours — re-running playbook 5 stays idempotent and
  cheap; do it after every CU.
- **CU cadence is the real drift source**: Microsoft ships Cumulative Updates
  roughly monthly and each changes the file inventory (the footprint pinned
  CU8-era bits, 2026-08). Re-capture on a CU boundary you intend to keep, not
  on every converge.
- The `limits.d` file is package-owned config; if hardening baselines flag
  it, the accept-list entry belongs to the PACKAGE, not the profile.

## 9. TLS: key ownership and rotation

SQL Server encrypts 1433 when told to: `mssql-conf` sets `network.tlscert`,
`network.tlskey`, `network.forceencryption` — root runs it, and the key must
be readable by the `mssql` account (`root:mssql 0640` is the working shape,
key outside the data root). Rotation is entirely ops: place cert+key, run
mssql-conf, restart the granted way (the team can run the restart; the team
cannot touch the key). Client side, `sqlcmd` from mssql-tools18 encrypts by
default and needs `-C` against the self-signed bootstrap certificate — which
is itself the reason to move to CA-issued material anywhere real. No profile
key exists for any of this, and none should.

## 10. Logs

- The **errorlog** lands in `/var/opt/mssql/log/` — inside the closed data
  root, unreadable by design. The granted read path is the journal:
  `journalctl -u mssql-server`, scoped per-unit (never the `systemd-journal`
  group). SQL-side, `sys.xp_readerrorlog` reads the same file over a SQL
  login — data-root closure is not observability loss.
- **No logrotate involvement**: the errorlog self-cycles on restart and by
  count (`mssql-conf errorlog.numerrorlogs`). There is no
  `/etc/logrotate.d/mssql*` to manage and no `create`-mode mask gotcha to
  test — the standard pre-flip logrotate drill is N/A for this app.

## 11. Known risks

| Risk | Severity | Disposition |
|---|---|---|
| `saslauthd.service` runs as root (footprint `risks[]`, EL both) | medium | **Accept + contain**: dependency of mssql-server, disabled by default and NOT granted (§2 drop). Owner: platform. Revisit only if AD auth integration turns it on |
| SQL Server **2025 refuses to start under SELinux enforcing without `mssql-server-selinux`** — error 101, no ERRORLOG, no AVC even with dontaudit disabled: the launcher checks the mode itself and self-refuses (found live on alma9, 2026-08-29; the 2017–2022 "unconfined, policy optional" guidance is stale for 2025). No AppArmor profile exists on Ubuntu, where it genuinely runs unconfined | medium | **Fix, done**: deployments on enforcing EL install the policy package alongside the engine (the db-lab role does); the archive-volume equivalence label is what lets the confined engine write its backup chain. Owner: deployment |
| Evaluation edition stops starting after 180 days (error 17051) — and its license grants **evaluation use only, never production**; the free Developer PIDs are likewise dev/test-only, and Express is the sole no-cost edition with production rights | low (lab) / high (anywhere else) | **Accept in the lab** — weekly rebuilds reset the clock at setup and the lab is evaluation by definition; the db-lab README states the terms. Anywhere durable: paid Standard/Enterprise, or Express within its caps. The EULA is accepted non-interactively at setup (`ACCEPT_EULA=Y`). Owner: deployment |
| 1433 (and 5022 where an AG exists) exposure | medium | **Contain**: host firewall scoped to the lab CIDR by the deploying role; SQL auth enforces 3-of-4 password classes on sa. Owner: deployment |

## 11b. Windows Server, in one paragraph

Everything above describes SQL Server on **Linux**, which is where this app's
profiles and evidence come from. The estate also runs it on **Windows Server
2022 and 2025 Core** (`app-vending-machine` labs/db `mswe01`/`mswx01`, and
labs/gmsa's SQL 2022 host), and the operational shape differs in ways worth
knowing before you carry a Linux assumption across: the **edition is the
media**, not a PID, and Evaluation ships an ISO while Express ships a
self-extracting EXE; installation is `setup.exe` with a rendered configuration
file, run from a one-shot scheduled task so it executes in SYSTEM context;
there is no `mssql-conf`, so host-level settings are `sqlservr` command-line
flags, registry, or T-SQL; and automation reaches the guest over **SSH with
`ansible_shell_type: powershell`**, never WinRM. No Windows access profile
exists for mssql yet — `matrix-windows.yml` covers `iis` only, and a Windows
profile needs live evidence (`evidence/<platform>/inventory-mssql.json`)
committed before it can be reviewed. The role evaluation's §8 covers the
Windows tooling question separately.

## 12. Storage and growth

Two growth surfaces, both familiar from the other engines and both landing in
`/var/opt/mssql` once setup runs:

- **Data files** grow with data; nothing new.
- **The transaction log is the one that bites**: a FULL-recovery database
  (which DR requires) grows its log **without bound until log backups run**.
  Error 4214 on the first `BACKUP LOG` (no full backup yet) is the visible
  corner of that: the db-lab's backup timer self-heals it, and its cadence is
  what caps log growth thereafter. A stalled log-backup timer is a disk-full
  incident on a delay timer — the freshness check in the lab's verify exists
  for exactly this.
- Backup history accumulates in `msdb` (`backupset`); the lab prunes the
  archive volume by age (7 days, matching the binlog retention elsewhere)
  and leaves msdb to the rebuild cycle.

## 13. Disk layout & data volume

The db-lab deployment (`app-vending-machine/labs/db`) is the reference:

- **Mount before install**: `/var/opt/mssql` is a dedicated data volume,
  mounted *before* the package lands, so setup initializes straight onto it
  (the mount-hides-ACLs rule — nothing here to hide, but the ordering
  discipline is uniform across engines).
- **The backup chain lives on its own archive volume**
  (`/var/opt/mssql-archive`): a runaway chain fills its own disk instead of
  stopping the engine, and the PITR evidence survives losing the data disk.
- On EL the archive volume carries an SELinux **equivalence label** to
  `/var/opt/mssql` — load-bearing, not decorative: 2025 runs CONFINED there
  (§11's policy-package requirement), and the label is what lets the engine
  write its backup chain onto the second volume.
- Sizing in the lab: 10 GB data / 5 GB archive per node, deliberately
  unequal so the two virtio disks can never be told apart wrongly.
