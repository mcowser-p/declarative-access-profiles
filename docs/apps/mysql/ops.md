# MySQL — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profile:
`profiles/mysql/almalinux-9-access.yml`
([reviewed](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/almalinux-9-access.yml),
[raw](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/almalinux-9-raw.yml))
— the untouched `-raw.yml` sibling is the review baseline. Role fit and
adopt/wrap decision: [role-eval](../../role-evals/mysql.md). Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

MySQL is **AlmaLinux 9 only** in this library: EL10 dropped `mysql-server`
(mariadb is the packaged option) and Ubuntu is a deliberate wave-1 scope cut
(mariadb covers the Ubuntu MySQL-compatible story). alma9 is the single profile;
alma10/ubuntu cells below read N/A.

This is a **database** profile — config-scoped by class: config + logs via ACL,
**no pam_group**, and the data directory (and its `mysql-files` / `mysql-keyring`
siblings) is never granted. See §3 and
[the database exception](../../concepts/access-model.md).

## 1. Footprint summary (evidence)

From `footprints/almalinux-9/footprint-mysql.json` (schema 1.0, captured
2026-08-09 on an AlmaLinux 9 EC2 AMI, SELinux enforcing; cairn 0.10.0 feature
branch):

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| App package | `mysql-server` (MySQL 8.0) | N/A — dropped from EL10 (mariadb is packaged) | N/A — wave-1 scope cut (mariadb covers; package exists) |
| Files added / modified | 1895 / 1958 | N/A | N/A |
| Units installed | `mysqld.service`, `mysqld@.service` (each present under both `/usr/lib/systemd/system` and `/lib/systemd/system` — usr-merge; 4 unit paths). No sockets, no timers. | N/A | N/A |
| Unit exec / identity | `ExecStart=/usr/libexec/mysqld --basedir=/usr`, `Type=notify`, `User=mysql` `Group=mysql`, `PrivateTmp=true`, `LimitNOFILE=10000`. **No** `ProtectSystem`/`NoNewPrivileges`/capabilities set in the unit (`access_hints.hardening` all null). | N/A | N/A |
| Accounts created | **none new in this capture** — `users_added`/`groups_added`/`membership_changes` all empty. The `mysql` user/group pre-existed (created by the earlier **mariadb** capture in the same container per `matrix.yml`), so `mysql-server`'s `/usr/lib/sysusers.d/mysql.conf` was a no-op. On a clean host it creates `mysql` uid/gid 27. | N/A | N/A |
| Data dir (captured) | `/var/lib/mysql` `mysql:mysql 0755` — **present but empty** (dnf did not auto-start; `--initialize` had not run) | N/A | N/A |
| Data-adjacent dirs | `/var/lib/mysql-files` `mysql:mysql 0750` (secure_file_priv import/export); `/var/lib/mysql-keyring` `mysql:mysql 0700` (InnoDB tablespace-encryption master keys) | N/A | N/A |
| Config (captured) | `/etc/my.cnf` `root:root 0644` (just `!includedir /etc/my.cnf.d`); `/etc/my.cnf.d/` `root:root 0755` with `client.cnf` + `mysql-server.cnf` (`root:root 0644`) | N/A | N/A |
| Other install-tree noise | `/var/lib/selinux/targeted/active/modules/200/mysql` (`root:root 0700`, compiled policy module); `/usr/lib/tmpfiles.d/mysqld.conf`; `/usr/lib/sysusers.d/mysql.conf`; `/etc/dbus-1/system.d/org.selinux.conf` (dbus policy, dep noise) | N/A | N/A |
| logrotate fragment | `/etc/logrotate.d/mysqld` `root:root 0644` (541 B) | N/A | N/A |
| Vendor sudoers shipped | none (`privilege.sudoers_files` empty; `sudo_rules` 0) | N/A | N/A |
| Notable binary | `/usr/libexec/mysqld` carries file capability `cap_sys_nice=ep` (the one `risks[]` entry — see §11); `/usr/bin/mysql_ssl_rsa_setup` present (auto-TLS generator, see §9) | N/A | N/A |

`privilege.sudoers_files[]` is empty — nothing to quote here. The high
`files_modified` count is an artifact of the shared-container capture
(`mariadb-server` was removed before the re-baseline, so many shared libraries /
perl modules re-appear as "modified"); it is not evidence of MySQL rewriting
system files. Because this is a single-distro row, there is nothing to compare
across families.

## 2. Raw → reviewed: the decisions

One row per delta from `almalinux-9-raw.yml`:

| Change | Tag | Why |
| --- | --- | --- |
| Drop all `files_modify` (4 unit paths: `mysqld.service` + `mysqld@.service`, `/lib` + `/usr/lib`) | REVIEW-DROP | Vendor unit files. A write ACL on a unit file is root-equivalent for that unit (edit `ExecStart=/usr/libexec/mysqld`, then the granted `daemon-reload` + `restart`). Read-only-units profile. |
| No `pam_group` to drop | (note) | The raw carried none: the `mysql` group pre-existed at capture (`groups_added` empty — created by the earlier mariadb run in the same container), so the exporter emitted no pam_group. On a clean host it would, and this review would DROP it for the database-class reason below. The apply-time opt-in is §3. |
| Drop `/var/lib/mysql` from `folders_modify` | REVIEW-DROP | The data directory — **never** granted for a database, in any list; filesystem access to the raw tables bypasses every SQL `GRANT`. |
| Drop `/var/lib/mysql-files` from `folders_modify` | REVIEW-DROP | The `secure_file_priv` import/export dir (`0750`), data-adjacent — holds bulk `LOAD DATA` / `SELECT ... INTO OUTFILE` payloads. Never granted. |
| Drop `/var/lib/mysql-keyring` from `folders_modify` | REVIEW-DROP | The keyring dir (`0700`) holding InnoDB tablespace-encryption master keys. Granting it hands the team the at-rest encryption keys — **more** sensitive than the data dir. Never granted. |
| Drop `/var/lib/selinux/targeted/active/modules/200/mysql` | REVIEW-DROP | Compiled SELinux policy module store (`root:root 0700`); landed with the policy module, not team space. |
| Add `/var/log/mysql` to `folders_read` | REVIEW-ADD | `/var/log` is excluded from footprints by default; file-log read is still wanted. EL `mysql-server` ships `/etc/logrotate.d/mysqld` + `/usr/lib/tmpfiles.d/mysqld.conf`, and `mysql-server.cnf` points `log-error` at `/var/log/mysql/mysqld.log`. |
| Add `ownership` for `/var/lib/mysql` (0755), `/var/lib/mysql-files` (0750), `/var/lib/mysql-keyring` (0700) | REVIEW-ADD | Assert the captured `state_dir` modes and make drift visible (re-tighten the 0700 keyring / 0750 secure dir if loosened). **Not** a grant — no membership/ACL is created. Raw omitted these only because the `mysql` account pre-existed in the shared capture; on a clean host the exporter would emit at least `/var/lib/mysql`. |

## 3. Access model for this app class

Database: **config-scoped**. Config drop-in write **ACL** (`/etc/my.cnf.d`) + log
read **ACL** (`/var/log/mysql`), **no pam_group** into the service group, and
**never** the data directory or its `mysql-files`/`mysql-keyring` siblings. The
`mysql` group owns the raw data files, and filesystem access to them bypasses
every `GRANT` the database enforces — DB administration happens through the SQL
client, not the filesystem. See the
[database exception](../../concepts/access-model.md) and its decision matrix.

**The pam_group opt-in.** The group option remains available at apply time for a
team that knowingly accepts data-dir exposure (e.g. filesystem backups of
`/var/lib/mysql`):

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/mysql/almalinux-9-access.yml \
  -e "group_name=<hostname>-app_restricted" \
  -e '{"declarative_access_pam_group": true, "declarative_access_local_groups": ["mysql"]}'
```

Treat that as a reviewed exception, not a default — it grants read of every table
file on disk, and (once initialized) read of the `mysql-keyring` encryption keys
and the `ca.pem`/`server-key.pem` TLS material in the data dir.

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/mysql/almalinux-9-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/mysql-rg-<host>-app-restricted` — `visudo -cf` it; confirm it
  lists `mysqld` (bare + `.service`) and the `journalctl -u` spellings, and
  **no** `files_modify` entries.
- **No `group.conf` line** — this profile has no pam_group (database class); if
  you see a `mysql` mapping, someone used the §3 opt-in.
- `getfacl /etc/my.cnf.d` — team group `rwx` + a `default:` entry.
- `getfacl /var/log/mysql` — team group `r-x` + `default:` (confirm the dir
  exists; `/usr/lib/tmpfiles.d/mysqld.conf` creates it at install).
- `/var/lib/mysql`, `/var/lib/mysql-files`, `/var/lib/mysql-keyring` — ownership
  asserted (`mysql:mysql 0755/0750/0700`), and **no ACL should appear on any of
  them**; if one does, the profile was applied wrong.
- No linger (no rootless quadlets).

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Verification vehicle: `scripts/verify-profile.sh mysql almalinux-9` (init
container, real playbook apply, probes, real `--tags cleanup`) — batched EC2
verify pass pending; see the `# VERIFIED: pending` line in the profile. On a live
host:

```bash
sudo -l -U <pilot>                          # exactly the scoped grants
sudo systemctl restart mysqld               # allow
sudo journalctl -e -u mysqld                # allow (granted spelling)
: > /etc/my.cnf.d/zz-probe.cnf              # allow — config ACL; then rm
tail -n1 /var/log/mysql/mysqld.log          # allow — log ACL (no sudo)
sudo systemctl restart sshd                 # DENY
sudo journalctl -e -u mysql                 # DENY (service is mysqld, not mysql)
echo x | sudo tee /var/lib/mysql/probe      # DENY — data dir never granted
sudo cat /var/lib/mysql-keyring/*           # DENY — encryption keyring never granted
```

There is **no behavioral pam_group check** for this profile (no service-group
membership is granted). The behavioral check is that the DB comes back after a
profile-scoped restart and still serves: `mysql -e 'SELECT 1'`. A stale-session
false-negative does not apply to the ACL grants here, but *does* apply to the
host-level `app-full → wheel` mapping during the flip (§6).

## 6. Flip

Remove the team from `<hostname>-app_full` (the restricted grants are already live
via nesting), `loginctl terminate-user <user>` per user, `sss_cache -E`. Confirm
on a fresh login: `id` shows no `wheel` and **not** `mysql`; `sudo -l` shows only
the mysql profile. Because this profile grants no pam_group of its own, the only
session-staleness concern at the flip is the host `app-full → wheel` mapping,
which the terminate + cache-flush clears (see
[lifecycle](../../concepts/lifecycle.md) step 9).

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time (this profile is
already ACL-only, so nothing to strip for tightening — the lever here is the
*opt-in* direction in §3); or full revoke with the same command + `--tags
cleanup`. Cleanup removes the sudoers file and the ACLs (access **and** default)
on the config drop-in dir and log dir. Deliberate exceptions, verbatim from
[lifecycle](../../concepts/lifecycle.md#revocation):

- **Parent traverse ACLs remain** (e.g. `rX` on `/etc` so the entity can reach
  `/etc/my.cnf.d`) — shared across profiles; remove manually with
  `setfacl -x g:<group> <dir>` only if the entity has no other profiles.
- **Ownership is never reverted** — the three `/var/lib/mysql*` ownership entries
  re-assert vendor state anyway, so cleanup leaves those dirs exactly as the
  package shipped them.

## 8. Drift and patching

A nice property of the config-scoped DB profile: it makes **no vendor-permission
deviation**. The only ownership entries re-assert the captured `mysql:mysql`
modes on the data + data-adjacent dirs, so `rpm -V mysql-server` stays clean —
there is **no setgid content dir to add to the golden-baseline accept-list**
(unlike the webserver profiles). ACLs are invisible to `rpm -V` either way. The
`cap_sys_nice` file capability on `/usr/libexec/mysqld` (§11) is vendor-shipped —
record it in the accept-list so a capability audit doesn't read it as tampering.

Package upgrades replace files and **shed file ACLs** — the config drop-in dir
and log dir ACLs vanish after `dnf update`. Remedy: re-run playbook 5 with the
same inputs (idempotent), then `getfacl` to confirm. On authselect-managed EL
hosts, `authselect apply-changes` can drop a pam_group line from
`/etc/pam.d/sshd` — not a concern for *this* profile (no pam_group), but it still
affects the host-level `app-full → wheel` mapping, so re-run the host access
playbook after authselect changes.

## 9. TLS: key ownership and rotation

Two MySQL-specific facts, both grounded in the capture:

1. **MySQL auto-generates a self-signed TLS pair — but not until first init.**
   Unlike MariaDB (which ships TLS off), MySQL 8 runs the equivalent of
   `mysql_ssl_rsa_setup` (the tool is present at `/usr/bin/mysql_ssl_rsa_setup`
   in the footprint) at its first `--initialize`, creating
   `ca.pem`/`server-cert.pem`/`server-key.pem` **inside the data directory**
   (`/var/lib/mysql`). dnf did not auto-start the service, so the data dir was
   empty at capture and no cert files appear — they will be generated the first
   time the server initializes. `[app-knowledge]`
2. **The key lands in the ungranted data dir, and `mysqld` reads it as `mysql`.**
   This is the PostgreSQL-on-EL situation: `server-key.pem` lives inside
   `/var/lib/mysql` (never granted), so **key rotation is always ops**. When
   replacing the self-signed default with a CA-signed pair, ops places the key
   **readable by the `mysql` account** — `root:mysql 0640` under
   `/etc/pki/tls/private` with the correct SELinux label (`mysqld` runs
   `User=mysql`, so unlike nginx/httpd it is the service account, not root, that
   reads the key) — and points `ssl_key`/`ssl_cert`/`ssl_ca` at it via a
   `[mysqld]` drop-in in the team's `/etc/my.cnf.d`.

Rotation keeps the boundary: platform places the new key (with the `mysql`-
readable perms above) and cert → the **team** runs its granted
`sudo systemctl restart mysqld` (MySQL has no graceful TLS reload; a restart is
the pickup, with a brief outage). Expiry monitoring needs no privileges
(`openssl x509 -enddate …`). The doctrine (keys are root-owned, in no profile)
and the EL cert/key paths are in [tls-ssl](../../concepts/tls-ssl.md); MySQL is a
service-account-key-read exception alongside MariaDB.

## 10. Logs

`journalctl` grants are per-unit scoping — never substitute `systemd-journal`
group membership (host-global journal read). Pre-flip test for the rotation mask
gotcha:

```bash
logrotate -f /etc/logrotate.d/mysqld
getfacl /var/log/mysql/mysqld.log     # team group present, no #effective:---
```

The `create`-mode in `/etc/logrotate.d/mysqld` sets the ACL mask on each fresh
file `[needs-runtime-confirmation on this host]`. Two database-specific caveats:

- **`log-error` may target the journal, not a file.** If MySQL logs errors to
  stderr/journald rather than `/var/log/mysql/mysqld.log`, the log-dir read ACL
  grants access to an empty or non-existent file — the journal grant is what
  matters. Confirm the effective `log-error` destination before relying on file
  read `[needs-runtime-confirmation]`.
- **General/slow query logs can be SQL tables, not files.** With
  `log_output=TABLE` they live in `mysql.general_log` / `mysql.slow_log` inside
  the (ungranted) data dir. Keep `log_output=FILE` to land them in the granted
  log dir; otherwise they are SQL-client-only. This is MySQL's self-logging
  equivalent of the PostgreSQL `log_file_mode` case in
  [logging](../../concepts/logging.md).

## 11. Known risks (from `risks[]`)

The footprint carries exactly **one** `risks[]` entry.

| Finding | Severity | Decision | Detail |
| --- | --- | --- | --- |
| `/usr/libexec/mysqld` carries a `security.capability` xattr | **high** | **Accept** | The captured xattr (`0100000200008000…`) decodes to **`cap_sys_nice=ep`** (effective + permitted, VFS caps v2). It lets `mysqld` raise thread scheduling priority / set CPU affinity without running as root — a standard MySQL-on-EL tuning capability, scoped to the daemon binary. Vendor-shipped; the binary (`root:root 0755`, under `/usr/libexec`) is in **no** grant, and the unit adds no further capabilities. Record it in the golden-baseline/capability accept-list; no fix. If thread-priority tuning is unwanted, `setcap -r` it (ops), but that is a hardening choice, not a defect. |

Context (not a `risks[]` entry, but worth an accept-or-fix note): the `mysqld`
units set **no** `ProtectSystem`, `PrivateDevices`, `NoNewPrivileges`, or
capability confinement (`access_hints.hardening` all null; only `PrivateTmp=true`
is set). Adding a systemd hardening drop-in is overlay/platform work — it belongs
in `/etc/systemd/system/mysqld.service.d/` (owned by the overlay, **never** in
the team profile, since a unit-drop-in write ACL is root-equivalent). See the
[role-eval](../../role-evals/mysql.md) R4 gap.

## 12. Storage and growth

Doctrine — who may provision, the mount trap, the separate-volume rule —
lives in [storage, disks, and growth](../../concepts/storage.md). This
section is the MySQL instantiation only.

### Install-time floor

Summed added-file bytes from the same footprint as §1. Treat it as a **floor,
not a forecast**: it records what the installer wrote, so it answers "will it
fit," never "how fast will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Install floor (all added files) | **335.4 MB** / 1895 files | N/A on alma10 — `mysql-server` dropped from EL10 | N/A on ubuntu — wave-1 scope cut (mariadb covers) |
| Largest category | `binary` 216.0 MB, of which `/usr/libexec/mysqld` alone is 53.8 MB; then `library` 102.4 MB | N/A on alma10 | N/A on ubuntu 24.04 |
| Data dir inside that total | **none** — dnf never ran `--initialize`; `/var/lib/mysql` was captured empty (§1) | N/A on alma10 | N/A on ubuntu 24.04 |

Two things make that figure conservative rather than tight. It counts **both
usr-merge spellings** of every binary and library (`/bin` and `/usr/bin` are
the same inode on EL9 — the same duplication as the four unit paths in §1),
so the deduplicated allocation is nearer 203 MB; size to the larger number.
And it contains **no database at all** — the first start writes the system
tablespace, redo log and undo tablespaces before a single row exists, of
order 150–200 MB on MySQL 8 defaults (`innodb_redo_log_capacity` alone is
100 MB). Budget alma9 hosts as package payload **plus** that first data dir.
`[needs-runtime-confirmation]`

### What grows after install

| Component | Where | Bounded? | Driver |
| --- | --- | --- | --- |
| Dataset | `/var/lib/mysql` | **No** | tables and indexes; InnoDB does not return freed space to the filesystem until a tablespace is rebuilt `[app-knowledge]` |
| Binary logs | `/var/lib/mysql`, `binlog.NNNNNN` | Only by `binlog_expire_logs_seconds` (30 days by default) | see below — the fastest and least visible way to fill this volume `[app-knowledge]` |
| Redo / undo | `/var/lib/mysql` | **Yes** — fixed capacity | `innodb_redo_log_capacity`, 100 MB default `[app-knowledge]` |
| Import/export payloads | `/var/lib/mysql-files` (`mysql:mysql 0750`, §1) | **No** | `SELECT ... INTO OUTFILE` / `LOAD DATA` files. REVIEW-DROPped (§2), so the team can neither see nor clear them |
| Dumps / backups | wherever ops points `mysqldump`/`mysqlsh` — **no backup dir ships** in the footprint | **No** | each full copy needs headroom ≈ the dataset |
| Log files | `/var/log/mysql` (created by `/usr/lib/tmpfiles.d/mysqld.conf`; `/var/log` is excluded from footprints) | **Yes** — the shipped fragment | verbose general/slow query logging |
| journald | all units | **Yes** — `SystemMaxUse` default | only unbounded if an operator raised the cap |

**Binlogs deserve their own check.** They are this app's instance of the
component [the doctrine names](../../concepts/storage.md#what-actually-grows):
log rotation never touches them, MySQL 8 enables binary logging by default,
and a long expiry plus a write-heavy schema can hold more binlog than data.
`[app-knowledge]` Look before it bites, and fix it in SQL:

```sql
SHOW BINARY LOGS;                                    -- per-file sizes
PURGE BINARY LOGS BEFORE NOW() - INTERVAL 3 DAY;     -- reclaim now
SET PERSIST binlog_expire_logs_seconds = 259200;     -- and keep it reclaimed
```

All three are superuser work and none of it is in the team's grant, so all
three arrive as ops requests. Check for a stalled replica before purging —
MySQL has no replication-slot backpressure, so an expiry short enough to
protect the disk can break a lagging replica instead. `[app-knowledge]`

### Separate volume: yes — and mount it at the data path

MySQL is the doctrine's database case: unbounded growth whose failure mode is
"fills the root filesystem". Give it its own volume, mounted at the app's
existing data path
([separate volumes](../../concepts/storage.md#separate-volumes-when-and-where)).

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Mount point | `/var/lib/mysql` — dataset **and** binlogs | N/A on alma10 | N/A on ubuntu 24.04 |
| Required state on the new fs root | `mysql:mysql 0755` (captured state, §1) | N/A on alma10 | N/A on ubuntu 24.04 |
| Restored by playbook 5? | **Yes** — the profile asserts ownership on exactly this path (§2) | N/A on alma10 | N/A on ubuntu 24.04 |
| *Not* covered by that mount | `/var/lib/mysql-files` (0750) and `/var/lib/mysql-keyring` (0700) are **siblings**, not children — mount them separately or leave them on root | N/A on alma10 | N/A on ubuntu 24.04 |
| SELinux relabel | required (EL enforcing); mounting at the app's own path keeps the existing fcontext rules, so `restorecon -Rv /var/lib/mysql` suffices — a *new* path needs `semanage fcontext -a -e` first | N/A on alma10 | N/A on ubuntu 24.04 |

### Ordering

Follow [the ops ordering](../../concepts/storage.md#separate-volumes-when-and-where)
— attach, `mkfs`, `fstab` by UUID, mount at the data path, restore
ownership/mode and the SELinux label, **re-apply, then `getfacl`**. Two MySQL
specifics on top of it:

- **Stop `mysqld` and copy the data across first.** A mount over a populated
  data dir hides it; the server then comes up against an empty directory —
  never let a bootstrap re-`--initialize` on top of a hidden dataset.
- **Re-apply even though no ACL lives on the data path.** This profile never
  grants the data dir, so there is no team ACL there to lose — what playbook
  5 restores at `/var/lib/mysql` is the ownership assertion (§2). The ACL'd
  paths are `/etc/my.cnf.d` and `/var/log/mysql`; a separate **log** volume is
  the realistic case where
  [the mount trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it)
  actually costs the team its access.

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/mysql/almalinux-9-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
stat -c '%U:%G %a' /var/lib/mysql     # mysql:mysql 755
getfacl /var/log/mysql                # team entry back, no #effective:---
```

### Log retention

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Rotation fragment shipped | `/etc/logrotate.d/mysqld` `root:root 0644` (541 B) | N/A on alma10 | N/A on ubuntu 24.04 |
| Default sink | `/var/log/mysql/mysqld.log` per the packaged `mysql-server.cnf` `log-error`, plus journald — the effective destination is `[needs-runtime-confirmation]` (§10) | N/A on alma10 | N/A on ubuntu 24.04 |
| Bounded out of the box | yes — the shipped fragment for files, journald `SystemMaxUse` for the journal | N/A on alma10 | N/A on ubuntu 24.04 |
| Team can change retention | no — the fragment is `root:root`, outside the grant | N/A on alma10 | N/A on ubuntu 24.04 |

Two MySQL caveats on top of that: **binlog retention is not logrotate's job**
(it is `binlog_expire_logs_seconds` / `PURGE BINARY LOGS`, superuser SQL,
above), and with `log_output=TABLE` the general/slow query logs move **into**
the data dir as `mysql.general_log` / `mysql.slow_log`, where no fragment
governs them and they grow the dataset instead (§10). Either way, retention
changes are an ops request; whether the team can still *read* a rotated file
is the mask caveat in §10.
