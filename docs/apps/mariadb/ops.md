# MariaDB — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/mariadb/{almalinux-9,almalinux-10,ubuntu-24.04,ubuntu-26.04,amazonlinux-2023}-access.yml`
with their untouched `-raw.yml` siblings. Role fit and adopt/wrap decision:
[role-eval](../../role-evals/mariadb.md). Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

This is a **database** profile — config-scoped by class: config + logs via
ACL, **no pam_group**, and the data directory is never granted. See §3 and
[the database exception](../../concepts/access-model.md).

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-mariadb.json` (schema 1.0, captured
2026-08-23 on holy-qcow KVM golden images, treadmark 0.11.0 — the full matrix
re-captured on the KVM substrate the day the two new cells joined):

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | amazonlinux 2023 |
| --- | --- | --- | --- | --- | --- |
| App package | `mariadb-server` (MariaDB 10.5) | `mariadb-server` (10.11) | `mariadb-server` (10.11.14) | `mariadb-server` (11.8.6) | `mariadb1011-server` (10.11.18 — the 10.11 dnf stream, newest of 10.5/10.11) |
| Units installed | `mariadb.service`, `mariadb@.service`, galera bootstrap drop-in | same **+** `mariadb.socket`, `mariadb@.socket`, `mariadb-extra.socket`, `mariadb-extra@.socket`, and the `mysql`/`mysqld` **compat alias symlinks** | same as alma10 **+** `/etc/systemd/system/multi-user.target.wants/mariadb.service` enablement symlink (apt auto-started it) **+ `rsync.service`** (newly installed dependency — see noise row) | same as alma10 **+** the enablement symlink; no rsync | alma10's socket set but **no** `mysql`/`mysqld` unit files — the names exist only as `Install.Alias` lines in `mariadb.service` |
| Accounts created | `mysql` (uid 27, gid 27, `/sbin/nologin`, home `/var/lib/mysql`) | `mysql` (uid 27) | `mysql` (uid 113, gid 117, `/bin/false`) **+** `_galera` (uid 112, gid 65534, nologin — galera SST account) | `mysql` (uid 982, gid 982, `/bin/false`, home `/nonexistent`) — **no `_galera`**, though the galera provider lib still ships | `mysql` (uid 27, gid 27, `/sbin/nologin`, home `/var/lib/mysql`) |
| Group created | `mysql` (gid 27) | `mysql` (gid 27) | `mysql` (gid 117) | `mysql` (gid 982) | `mysql` (gid 27) |
| Data dir (captured) | `/var/lib/mysql` `mysql:mysql 0755` | same | `/var/lib/mysql` `mysql:mysql 0755`; subdirs `mysql/`,`sys/`,`performance_schema/` `0700` (data initialised — apt auto-start) | **`/var/lib/mariadb`** `mysql:mysql 0755`, initialised, same `0700` subdirs — **no `/var/lib/mysql` exists at all** (the 11.8 packaging moved the default datadir) | `/var/lib/mysql` `mysql:mysql 0755` |
| Config (captured) | `/etc/my.cnf` `root:root 0644`; `/etc/my.cnf.d/` `root:root 0755` | same | `/etc/mysql/` tree `root:root`; **`/etc/mysql/debian.cnf` `root:root 0600` (holds debian-sys-maint credentials)**; drop-ins in `/etc/mysql/mariadb.conf.d/` | same as ubuntu 24.04, `debian.cnf 0600` included | same as alma9; the 10.11-stream drop-ins add `cracklib_password_check.cnf` |
| Other install-tree noise | `/var/lib/selinux/…/modules/{200,disabled}` (`root:root 0700`, policy store) | same | `/etc/logcheck/ignore.d.*` fragments; AppArmor profile `usr.sbin.mariadbd`; init-script `/etc/init.d/mariadb`; **`rsync.service`** (the EC2 AMI had rsync preinstalled — the leaner KVM golden image does not, so the dependency now lands in the capture) | `/etc/logcheck/ignore.d.*` fragments; AppArmor profile renamed **`mariadbd`** (+ `local/mariadbd`); init-script | SELinux policy store (`mysql` **+ `mariadb-plugin-cracklib-password-check`** modules); D-Bus policy `org.selinux.conf` |
| logrotate fragment | `/etc/logrotate.d/mariadb` | same | same | same | same |
| Vendor sudoers shipped | none (`privilege.sudoers_files` empty) | none | none | none | none |

`privilege.sudoers_files[]` is empty on every distro — nothing to quote here.
Setuid/capability findings are triaged in §11.

Both Ubuntu footprints include first-start side effects (apt auto-starts
services), so their data dirs are fully initialised; the EL trio
(alma9/alma10/AL2023) is pre-first-start. That's evidence, not noise — but raw
profiles are not line-comparable across distros.

## 2. Raw → reviewed: the decisions

| Change | Tag | Why |
| --- | --- | --- |
| Drop all `files_modify` (6 / 18 / 21 / 19 / 14 entries) | REVIEW-DROP | Every entry is a vendor unit/socket file (plus, on Ubuntu, the apt enablement symlink; plus, on ubuntu-24.04, the `rsync.service` dependency unit). A write ACL on a unit file is root-equivalent for that unit. Read-only-units profile. |
| Drop `pam_group` + `local_groups: ['mysql']` | REVIEW-DROP | **Database class.** The `mysql` group owns the raw table files, so membership = filesystem read of the data — which bypasses every SQL `GRANT`. Config-scoped instead. Apply-time opt-in remains (see §3). |
| Drop the data dir from `folders_modify` (`/var/lib/mysql`; `/var/lib/mariadb` on ubuntu-26.04) | REVIEW-DROP | The data directory — **never** granted for a database, in any list, whatever the distro calls it. |
| Drop `/var/lib/selinux/…/modules/{200,disabled}` (alma9/10, AL2023) | REVIEW-DROP | Compiled SELinux policy module store (`root:root 0700`); landed with the policy modules, not team space. On the lean KVM golden images the priority-200 store dirs are themselves install-created — the EC2 AMIs already had them, so earlier raws named only `…/200/mysql` — meaning the raw now points at **every** module at that priority (AL2023 compiles two: `mysql` + `mariadb-plugin-cracklib-password-check`); one more reason to drop. |
| Drop `mysql`, `mysqld` from `services` (alma10, both ubuntus) | REVIEW-DROP | Shipped alias symlinks for `mariadb.service` — same daemon. Grant the canonical `mariadb`. AL2023 needs no drop: the names are `Install.Alias` lines only, so its raw already lists just `mariadb`. |
| Drop `rsync` from `services` + its unit files (ubuntu-24.04, KVM re-capture) | REVIEW-DROP | Dependency noise, not the app: `mariadb-server` pulls rsync for galera SST, and the leaner KVM golden image (unlike the EC2 AMI) did not have it preinstalled, so it landed in the capture. The team never legitimately restarts rsync. Same call for the moved logcheck path in the same re-capture — **none of the 2026-08-23 drift enters the reviewed grants**, which are unchanged for all three existing cells. |
| Narrow Ubuntu config: drop `/etc/mysql`, add `/etc/mysql/mariadb.conf.d` (both ubuntus) | REVIEW-DROP + REVIEW-ADD | `folders_modify` is a **recursive** rw ACL; a tree-wide ACL on `/etc/mysql` would reach `debian.cnf` (`0600`, the debian-sys-maint credentials — present on 26.04 too). Grant only the drop-in dir the team edits (parallels EL's `/etc/my.cnf.d`). |
| Drop `/etc/logcheck/ignore.d.*` (both ubuntus) | REVIEW-DROP | Owned by the `logcheck` package; the dirs appear only because `mariadb-server` ships ignore fragments. Dependency noise, not team space. |
| Add `/var/log/mariadb` `folders_read` (**EL trio only** — alma9/10, AL2023) | REVIEW-ADD | `/var/log` is excluded from footprints by default; file-log read is still wanted. AL2023's stream package ships the same `/etc/logrotate.d/mariadb` fragment as the almas. |
| Drop `/var/log/mysql` on Ubuntu (both) | REVIEW-DROP | The directory does not exist — Debian leaves `log_error` unset, so the error log goes to journald. Verification on a real ubuntu-24.04 instance caught this (apply failed with "not a directory or regular file"); 26.04 keeps the same packaging, same call, re-checked at verify time. Journal access is the granted `journalctl` spellings. |
| Keep the data-dir ownership entry (`/var/lib/mysql`; `/var/lib/mariadb` on ubuntu-26.04) | as captured | Asserts install-time state (`mysql:mysql 0755`); makes drift visible. **Not** an access grant — no membership/ACL on the data dir is created. |

The result is **identical on alma9, alma10 and amazonlinux-2023** (the extra
sockets/compat units and the broader SELinux store all drop out; AL2023's
reviewed file says so in its header); the two Ubuntu cells differ only in the
config/log paths, the Debian-specific drops — and, on 26.04 alone, the
`/var/lib/mariadb` data-dir path in the ownership entry.

## 3. Access model for this app class

Database: **config-scoped**. Config drop-in write **ACL** + log read **ACL**,
**no pam_group** into the service group, and **never** the data directory. The
`mysql` group owns the raw data files, and filesystem access to them bypasses
every `GRANT` the database enforces — DB administration happens through the SQL
client, not the filesystem. See the
[database exception](../../concepts/access-model.md) and its decision matrix.

**The pam_group opt-in.** The group option remains available at apply time for a
team that knowingly accepts data-dir exposure (e.g. filesystem backups of
`/var/lib/mysql`):

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/mariadb/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" \
  -e '{"declarative_access_pam_group": true, "declarative_access_local_groups": ["mysql"]}'
```

Treat that as a reviewed exception, not a default — it grants read of every
table file on disk, ciphertext-at-rest included.

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/mariadb/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/mariadb-rg-<host>-app-restricted` — `visudo -cf` it.
- **No `group.conf` line** — this profile has no pam_group (database class).
- `getfacl /etc/my.cnf.d` (EL + AL2023) / `getfacl /etc/mysql/mariadb.conf.d`
  (Ubuntu) — team group `rwx` + a `default:` entry.
- `getfacl /var/log/mariadb` (EL trio only; Ubuntu has no log dir) — team
  group `r-x` + `default:`.
- Data-dir ownership `mysql:mysql 0755` on `/var/lib/mysql`
  (`/var/lib/mariadb` on ubuntu-26.04) — asserted, unchanged from vendor —
  **no ACL should appear on it**; if one does, the profile was applied wrong.
- No linger (no rootless quadlets).

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Verification vehicle: `scripts/verify-profile.sh mariadb <distro>` (init
container, real playbook apply, probes, real `--tags cleanup`). The three
original cells carry `# VERIFIED: 2026-08-09` from the EC2 pass; the two new
cells (ubuntu-26.04, amazonlinux-2023) are `# VERIFIED: pending` until the
first KVM verify pass. On a live host:

```bash
sudo -l -U <pilot>                          # exactly the scoped grants
sudo systemctl restart mariadb              # allow
sudo journalctl -e -u mariadb               # allow (granted spelling)
: > /etc/my.cnf.d/zz-probe.cnf              # allow (EL) — config ACL; then rm
sudo systemctl restart sshd                 # DENY
sudo journalctl -e -u mysqld                # DENY (alias not granted)
echo x | sudo tee /var/lib/mysql/probe      # DENY — data dir never granted
                                            # (ubuntu-26.04: /var/lib/mariadb/probe)
sudo tee -a /etc/mysql/debian.cnf </dev/null  # DENY (Ubuntu) — outside the ACL
```

There is **no behavioral pam_group check** for this profile (no service-group
membership is granted). The behavioral check is that the DB comes back after a
profile-scoped restart and still serves: `mariadb -e 'SELECT 1'`. A stale
session false-negative does not apply to the ACL grants here, but *does* apply
to the host-level `wheel` mapping during the flip (§6).

## 6. Flip

Remove the team from `<hostname>-app_full` (the restricted grants are already
live via nesting), `loginctl terminate-user <user>` per user, `sss_cache -E`.
Confirm on a fresh login: `id` shows no `wheel`, `sudo -l` shows only the
mariadb profile. Because this profile grants no pam_group of its own, the only
session-staleness concern at the flip is the host `app-full → wheel` mapping,
which the terminate + cache-flush clears (see
[lifecycle](../../concepts/lifecycle.md) step 9).

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time
(this profile is already ACL-only, so nothing to strip for tightening — the
lever here is the *opt-in* direction in §3); or full revoke with the same
command + `--tags cleanup`. Cleanup removes the sudoers file and the ACLs
(access **and** default) on the config drop-in dir and log dir. Deliberate
exceptions, verbatim from [lifecycle](../../concepts/lifecycle.md):

- **Parent traverse ACLs remain** (e.g. `rX` on `/etc/mysql` so the entity can
  reach `mariadb.conf.d`) — shared across profiles, remove manually with
  `setfacl -x g:<group> /etc/mysql` only if the entity has no other profiles.
- **Ownership is never reverted** — the data-dir ownership entry
  (`/var/lib/mysql`; `/var/lib/mariadb` on ubuntu-26.04) is a no-op to revert
  anyway (it asserts the vendor state), so cleanup leaves the data dir exactly
  as the package shipped it.

## 8. Drift and patching

A nice property of the config-scoped DB profile: it makes **no vendor-permission
deviation**. The only ownership entry re-asserts the captured `mysql:mysql 0755`
on the data dir, so `rpm -V mariadb-server` / `dpkg --verify mariadb-server`
stay clean — there is **no setgid content dir to add to the golden-baseline
accept-list** (unlike the webserver profiles). ACLs are invisible to rpm/dpkg
verification either way.

Package upgrades replace files and **shed file ACLs** — the config drop-in dir
and log dir ACLs vanish after `dnf update` / `apt upgrade`. Remedy: re-run
playbook 5 with the same inputs (idempotent). On EL, `authselect apply-changes`
can drop a pam_group line from `/etc/pam.d/sshd` — not a concern for *this*
profile (no pam_group), but it still affects the host-level `app-full → wheel`
mapping, so re-run the host access playbook after authselect changes.

## 9. TLS: key ownership and rotation

Two MariaDB-specific facts, both grounded in the capture:

1. **No certificates are auto-generated.** Unlike MySQL 8 / Percona (which
   create `ca.pem`/`server-cert.pem`/`server-key.pem` in the data dir at first
   start), MariaDB ships TLS **off**. No cert/key material appears in any of the
   five footprints — including the two Ubuntu boxes where apt started the
   daemon. TLS is therefore an explicit opt-in: a `[mariadbd]` `ssl_ca`/`ssl_cert`/
   `ssl_key` block in the team's drop-in dir, plus ops placing key material.
2. **mariadbd reads the key as the `mysql` account, not root.** This is the
   MariaDB wrinkle absent from the nginx/httpd model (where root reads the key).
   Ops must place the private key **readable by `mysql`** — `root:mysql 0640`
   under `/etc/pki/tls/private` (EL) or via the `ssl-cert` group under
   `/etc/ssl/private` (Ubuntu) — never world-readable and **never** in the team
   profile. The doctrine (keys are root-owned and in no profile) and the
   EL-vs-Ubuntu paths are in [tls-ssl](../../concepts/tls-ssl.md); MariaDB is
   the fourth per-class exception to note there (service-account key read).

Rotation keeps the boundary: platform places the new key (with the `mysql`-
readable perms above) and cert → the **team** runs its granted
`sudo systemctl restart mariadb` (MariaDB has no graceful TLS reload; a restart
is the pickup, with a brief outage). Expiry monitoring needs no privileges
(`openssl x509 -enddate …`). A team that must own the cert directory itself is a
profile-review conversation, not this profile.

## 10. Logs

`journalctl` grants are per-unit scoping — never substitute `systemd-journal`
group membership (host-global journal read). Pre-flip test for the rotation mask
gotcha:

```bash
logrotate -f /etc/logrotate.d/mariadb
getfacl /var/log/mariadb/mariadb.log   # EL trio only — Ubuntu logs to journald
                                       # team group present, no #effective:---
```

The `create`-mode in `/etc/logrotate.d/mariadb` sets the ACL mask on each fresh
file `[needs-runtime-confirmation on this host]`. Two database-specific caveats:

- **`log_error` may target the journal, not a file.** If MariaDB logs errors to
  stderr/journald (the default when `log_error` is unset), the `/var/log/*`
  read ACL grants access to an empty or non-existent file — the journal grant is
  what matters. Confirm the `log_error` destination before relying on file read
  `[needs-runtime-confirmation]`.
- **General/slow query logs can be SQL tables, not files.** The capture shows
  `general_log.CSV` / `slow_log.CSV` under the (ungranted) data dir. If a team
  needs them on disk, set `log_output=FILE` so they land in the granted log dir;
  otherwise they are SQL-client-only. This is MariaDB's self-logging equivalent
  of the PostgreSQL `log_file_mode` case in [logging](../../concepts/logging.md).

## 11. Known risks (from `risks[]`)

The `/lib` vs `/usr/lib` duplicates below are the same file via the usr-merge
symlink; each is one logical finding.

| Finding | Severity | Distros | Decision | Owner |
| --- | --- | --- | --- | --- |
| `use_galera_new_cluster.conf` has no `User=` → runs as **root** | medium | all five | **Accept.** It's the `mariadb@bootstrap.service.d` drop-in, active only during a deliberate Galera cluster bootstrap, not normal operation — and the unit is not granted (read-only-units). Relevant only if you run Galera. | DBA/ops |
| `auth_pam_tool` is **setuid root** (`/usr/lib/mysql/plugin/auth_pam_tool_dir/`) | high | ubuntu 24.04 + 26.04 | **Accept.** Vendor-shipped helper for MariaDB's PAM authentication plugin; setuid is required for it to check `/etc/shadow`. Not in any grant. Confirm it's still `0755 root:root` after upgrades; disable the PAM auth plugin if unused. | ops |
| `mariadb`/`mysql`/`mysqld`/`mariadb@` services grant **`CAP_IPC_LOCK`** (ambient) | high | ubuntu 24.04 + 26.04 | **Accept.** Lets `mariadbd` lock its buffer pool into RAM (`memlock`), a standard DB tuning capability, scoped to the daemon. Vendor default; units are read-only in this profile. | DBA/ops |
| `rsync.service` has no `User=` → runs as **root** | medium | ubuntu 24.04 only | **Accept.** Not mariadb's unit at all — the rsync dependency the KVM golden image lacked (§1). Disabled by default, not granted anywhere (its unit files are dropped in review), and stock Ubuntu rsyncd. Absent from the 26.04 capture. | ops |

The EL trio (alma9/alma10/AL2023) carries only the two medium Galera-bootstrap
entries (the `/lib`+`/usr/lib` pair); each Ubuntu adds the setuid and
`CAP_IPC_LOCK` highs above (13 raw entries each, collapsing to 3 logical
findings), and the ubuntu-24.04 KVM re-capture adds the rsync medium (4th).
None require a profile change — they are properties of the vendor units, which
this read-only-units profile never grants write to.

## 12. Storage and growth

Install-time floor, summed from the `filesystem` block of each
`footprints/<distro>/footprint-mariadb.json`:

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | amazonlinux 2023 |
| --- | --- | --- | --- | --- | --- |
| Install floor (all added files) | **241.3 MB** | **256.9 MB** | **494.0 MB** | **383.8 MB** | **253.3 MB** |
| Dominated by | binaries 162.7 MB + libraries 66.5 MB; `mariadb-backup` 23.9 MB, `mariadbd` 23.5 MB | binaries 188.4 MB + libraries 54.0 MB; `mariadb-backup` 21.5 MB, `mariadbd` 21.0 MB | binaries 338.4 MB; `mariadbd` 26.1 MB — **plus an initialised data dir** | binaries 211.4 MB; `mariadbd` 26.8 MB — **plus an initialised data dir** | binaries 200.2 MB + libraries 46.3 MB; `mariadb-backup` 24.9 MB, `mariadbd` 24.4 MB |
| Of which the data dir | none — capture is pre-first-start (empty dir only) | none — pre-first-start | **~124.4 MB** in `/var/lib/mysql` — apt auto-started the daemon, so InnoDB is already allocated | **~154.4 MB** in `/var/lib/mariadb` — as 24.04, plus 11.8's three preallocated `undo00N` tablespaces (10 MB each) | none — pre-first-start |

Treat that as a **floor, not a forecast** — it answers "will it fit", never
"how fast will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).
`/var/log` is excluded from footprints, so no log volume is priced in here.

**The five numbers are not comparable, and the EL trio understates the real
floor.** The Ubuntu figures include the InnoDB baseline the daemon allocated at
first start; the EL captures are pre-first-start (§1), so an EL host pays that
same allocation *after* handover. Budget the EL floor as install + the InnoDB
baseline below. The sums also count the usr-merge duplicate paths
(`/bin` ↔ `/usr/bin`) as separate entries — the same convention as every other
app row in this library, and the same duplication flagged in §11.

Growth drivers, worst first:

| Driver | Bounded? | Detail |
| --- | --- | --- |
| Dataset in the data dir (`/var/lib/mysql`; 26.04: `/var/lib/mariadb`) | **No** | The unbounded path, and the one **never granted** (§3). The team cannot measure it from the filesystem at all — dataset-size questions go through the SQL client. |
| Binlogs | **No — once enabled** | **No binlog files appear in any footprint**, including the two Ubuntu captures whose data dirs are fully initialised: binary logging is off as shipped. Once a team sets `log_bin` (replication, PITR), retention is `binlog_expire_logs_seconds` or an explicit `PURGE BINARY LOGS`; **rotation of log files never touches them** `[app-knowledge]`. Classic disk-full cause. |
| InnoDB redo + system tablespace | Yes — preallocated, fixed | Both Ubuntu captures: `ib_logfile0` 96 MB, `ibdata1` 12 MB; 26.04 (MariaDB 11.8) additionally preallocates `undo001`–`undo003` at 10 MB each. Allocated at first start, which is why the EL floor above omits it. |
| `ibtmp1` temp tablespace | **No — within a run** | 12 MB at first start (both Ubuntu captures); grows with large sorts and temp tables and only returns to its initial size on restart `[app-knowledge]`. |
| `/var/log/mariadb/*` | Yes — package fragment | `/etc/logrotate.d/mariadb` ships on all five distros (§1). N/A on ubuntu-24.04/26.04 — the directory does not exist (§2 REVIEW-DROP). |
| journal | Yes — journald `SystemMaxUse` | Ubuntu's only error-log destination. On the EL trio it carries startup/shutdown unless `log_error` targets a file (§10). |

**A separate volume is warranted — this is a database.** Mount it at the app's
own data path — **`/var/lib/mysql`** everywhere except ubuntu-26.04, where the
canonical path is **`/var/lib/mariadb`** (§1) — never a new path with a symlink
or a `datadir=` override: the ownership assertion, the SELinux policy module
(§1) and the team's grants are all written against the canonical path. The
substrate-specific how-to (attaching the disk on a holy-qcow KVM VM, the guest
migration sequence) is §13.

Ordering differs from the webserver profiles in one useful way — the data dir
is **not** a granted path here, so the mount-hides-ACLs trap does not bite the
team's grants at the canonical mount point. What a fresh filesystem *does* wipe
is the vendor state this profile asserts:

1. mount at the canonical data path (see above),
2. restore `mysql:mysql 0755` and, on EL/AL2023, `restorecon -Rv
   /var/lib/mysql` — the package ships the policy module (§1), and mounting at
   the canonical path means no `semanage fcontext -e` equivalency is needed,
3. **re-apply playbook 5** (§4) — it re-asserts the ownership entry,
4. confirm: `ls -ld` on the data dir shows `mysql:mysql 0755` and `getfacl`
   shows **no** team ACL on it (§4), while `getfacl` on the config drop-in dir
   and, on the EL trio, `/var/log/mariadb` still shows the team entry +
   `default:`.

If ops instead splits logs onto their own volume at `/var/log/mariadb` (EL
trio), that *is* a granted path and the trap applies in full — re-apply, then
`getfacl`. Full procedure:
[separate volumes: when and where](../../concepts/storage.md#separate-volumes-when-and-where).

Retention reality: file logs rotate on the shipped `/etc/logrotate.d/mariadb`
fragment (create-mode detail in §10) on the EL trio; **Ubuntu has no log files
to rotate** — the error stream goes to journald, bounded by journald defaults.
Binlog retention is neither of those: it is a server variable, and purging
needs the service account or root. None of the three is in any profile —
**retention or frequency changes are an ops request**, handled in a change
window.

## 13. Disk layout & data volume

**Layout doctrine.** The data directory — `/var/lib/mysql` everywhere except
ubuntu-26.04's `/var/lib/mariadb` (§1) — belongs on its **own volume**, and it
appears in **no profile list of any kind**: not `folders_modify`, not
`folders_read`, on any distro — only the non-granting ownership assertion
(§2). That is the database exception in one sentence: the DBA surface is the
**database protocol**, not the filesystem — see
[§3](#3-access-model-for-this-app-class) and
[the database exception](../../concepts/access-model.md). Sizing and growth
drivers for the volume: §12.

**Attaching the data disk (holy-qcow KVM substrate).** holy-qcow's
`tofu/modules/vm` provisions **only the root disk** today, so the data volume
is a post-deploy step on the virt host:

```bash
virsh vol-create-as vmdisks <name>-data.qcow2 <size>G --format qcow2
virsh vol-path <name>-data.qcow2 --pool vmdisks    # → <path> for the next line
virsh attach-disk <domain> --source <path> --target vdb --persistent --subdriver qcow2
```

The host AppArmor accommodation already covers the `vmdisks` pool, so the
attach needs no host-side policy work. A `data_disk_gb` variable on the vm
module (the module carves and attaches the second qcow2 itself; the root disk
stays golden-image sized) is the clean future upstream extension —
**not scheduled**.

**Guest-side migration** — change window; none of these commands is in any
profile, so this is ops (or the team back in app-full):

```bash
sudo mkfs.xfs /dev/vdb                  # or ext4; a single-purpose virtio disk
                                        # needs no partition table [app-knowledge]
sudo systemctl stop mariadb
sudo mv /var/lib/mysql /var/lib/mysql.orig      # ubuntu-26.04: /var/lib/mariadb
sudo mkdir /var/lib/mysql
echo "UUID=$(sudo blkid -s UUID -o value /dev/vdb) /var/lib/mysql xfs defaults 0 2" \
  | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /var/lib/mysql
sudo cp -a /var/lib/mysql.orig/. /var/lib/mysql/
sudo restorecon -R /var/lib/mysql       # EL/AL2023 only — the package ships the
                                        # SELinux policy module (§1); AppArmor on
                                        # Ubuntu needs no relabel
sudo systemctl start mariadb && mariadb -e 'SELECT 1'
sudo rm -rf /var/lib/mysql.orig         # only after the DB verifies
```

Then **re-apply playbook 5** and run the §12 confirmation (ownership
re-asserted, **no** team ACL on the data dir). Two sequencing notes:

- On the pre-first-start EL trio the dance is shorter: attach, mkfs, mount and
  fstab **before first start**, and there is nothing to move — their captured
  data dirs are empty (§1).
- Do **not** soften the fstab entry with `nofail` for this volume: the EL
  trio's unit runs `/usr/libexec/mariadb-prepare-db-dir` before the daemon
  (`exec_start_pre` in each EL footprint), which on a missing mount would
  quietly initialise a **fresh, empty** data dir on the root disk — a
  confusing failure that looks like data loss. A boot that stops on a broken
  data mount is the better failure mode for a database.

**Growing the volume later.** In-place growth (disk → partition → LVM →
filesystem) is automated by the
[mcowser_p.fleet_medic](https://github.com/mcowser-p/fleet-medic) collection's
`disk_expand` role — growing in place never remounts, so the profile's grants
are untouched. Details, and the six-step for any *new* volume:
[growing existing volumes](../../concepts/storage.md#growing-existing-volumes).
