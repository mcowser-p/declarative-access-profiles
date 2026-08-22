# MariaDB — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/mariadb/{almalinux-9,almalinux-10,ubuntu-24.04}-access.yml` with
their untouched `-raw.yml` siblings. Role fit and adopt/wrap decision:
[role-eval](../../role-evals/mariadb.md). Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

This is a **database** profile — config-scoped by class: config + logs via
ACL, **no pam_group**, and the data directory is never granted. See §3 and
[the database exception](../../concepts/access-model.md).

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-mariadb.json` (schema 1.0, captured
2026-08-09 on EC2 AMIs, treadmark 0.10.0 feature branch; EL captures SELinux
enforcing):

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| App package | `mariadb-server` (MariaDB 10.5) | `mariadb-server` | `mariadb-server` (10.11) |
| Units installed | `mariadb.service`, `mariadb@.service`, galera bootstrap drop-in | same **+** `mariadb.socket`, `mariadb@.socket`, `mariadb-extra.socket`, `mariadb-extra@.socket`, and the `mysql`/`mysqld` **aliases** | same as alma10 **+** `/etc/systemd/system/multi-user.target.wants/mariadb.service` enablement symlink (apt auto-started it) |
| Accounts created | `mysql` (uid 27, gid 27, `/sbin/nologin`, home `/var/lib/mysql`) | `mysql` (uid 27) | `mysql` (uid 114, gid 116, `/bin/false`) **+** `_galera` (uid 113, gid 65534, nologin — galera SST account) |
| Group created | `mysql` (gid 27) | `mysql` (gid 27) | `mysql` (gid 116) |
| Data dir (captured) | `/var/lib/mysql` `mysql:mysql 0755` | same | `/var/lib/mysql` `mysql:mysql 0755`; subdirs `mysql/`,`sys/`,`performance_schema/` `0700` (data initialised — apt auto-start) |
| Config (captured) | `/etc/my.cnf` `root:root 0644`; `/etc/my.cnf.d/` `root:root 0755` | same | `/etc/mysql/` tree `root:root`; **`/etc/mysql/debian.cnf` `root:root 0600` (holds debian-sys-maint credentials)**; drop-ins in `/etc/mysql/mariadb.conf.d/` |
| Other install-tree noise | `/var/lib/selinux/…/mysql` (`root:root 0700`, policy module) | same | `/etc/logcheck/ignore.d.*` fragments; AppArmor profile `usr.sbin.mariadbd`; init-script `/etc/init.d/mariadb` |
| logrotate fragment | `/etc/logrotate.d/mariadb` | same | same |
| Vendor sudoers shipped | none (`privilege.sudoers_files` empty) | none | none |

`privilege.sudoers_files[]` is empty on every distro — nothing to quote here.
Setuid/capability findings are triaged in §11.

Ubuntu's footprint includes first-start side effects (apt auto-starts
services), so its data dir is fully initialised; EL captures are pre-first-start.
That's evidence, not noise — but raw profiles are not line-comparable across
distros.

## 2. Raw → reviewed: the decisions

| Change | Tag | Why |
| --- | --- | --- |
| Drop all `files_modify` (6 / 18 / 19 entries) | REVIEW-DROP | Every entry is a vendor unit/socket file (plus, on Ubuntu, the apt enablement symlink). A write ACL on a unit file is root-equivalent for that unit. Read-only-units profile. |
| Drop `pam_group` + `local_groups: ['mysql']` | REVIEW-DROP | **Database class.** The `mysql` group owns the raw table files, so membership = filesystem read of the data — which bypasses every SQL `GRANT`. Config-scoped instead. Apply-time opt-in remains (see §3). |
| Drop `/var/lib/mysql` from `folders_modify` | REVIEW-DROP | The data directory — **never** granted for a database, in any list. |
| Drop `/var/lib/selinux/…/mysql` (EL) | REVIEW-DROP | Compiled SELinux policy module store (`root:root 0700`); landed with the policy module, not team space. |
| Drop `mysql`, `mysqld` from `services` (alma10, ubuntu) | REVIEW-DROP | Install.Alias / Debian compat names for `mariadb.service` — same daemon. Grant the canonical `mariadb`. |
| Narrow Ubuntu config: drop `/etc/mysql`, add `/etc/mysql/mariadb.conf.d` | REVIEW-DROP + REVIEW-ADD | `folders_modify` is a **recursive** rw ACL; a tree-wide ACL on `/etc/mysql` would reach `debian.cnf` (`0600`, the debian-sys-maint credentials). Grant only the drop-in dir the team edits (parallels EL's `/etc/my.cnf.d`). |
| Drop `/etc/logcheck/ignore.d.*` (Ubuntu) | REVIEW-DROP | Owned by the `logcheck` package; appear only because `mariadb-server` ships an ignore fragment. Dependency noise, not team space. |
| Add `/var/log/mariadb` `folders_read` (**EL only**) | REVIEW-ADD | `/var/log` is excluded from footprints by default; file-log read is still wanted. |
| Drop `/var/log/mysql` on Ubuntu | REVIEW-DROP | The directory does not exist — Debian leaves `log_error` unset, so the error log goes to journald. EC2 verification caught this: the apply failed with "not a directory or regular file". Journal access is the granted `journalctl` spellings. |
| Keep `/var/lib/mysql` ownership | as captured | Asserts install-time state (`mysql:mysql 0755`); makes drift visible. **Not** an access grant — no membership/ACL on the data dir is created. |

The result is **identical on alma9 and alma10** (EL10's extra sockets/aliases
all drop out); Ubuntu differs only in the config/log paths and the extra
Debian-specific drops.

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
- `getfacl /etc/my.cnf.d` (EL) / `getfacl /etc/mysql/mariadb.conf.d` (Ubuntu) —
  team group `rwx` + a `default:` entry.
- `getfacl /var/log/mariadb` (EL only; Ubuntu has no log dir) — team
  group `r-x` + `default:`.
- `/var/lib/mysql` ownership `mysql:mysql 0755` (asserted, unchanged from
  vendor) — **no ACL should appear on it**; if one does, the profile was
  applied wrong.
- No linger (no rootless quadlets).

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Verification vehicle: `scripts/verify-profile.sh mariadb <distro>` (init
container, real playbook apply, probes, real `--tags cleanup`) — batched EC2
verify pass pending; see the `# VERIFIED: pending` line in each profile. On a
live host:

```bash
sudo -l -U <pilot>                          # exactly the scoped grants
sudo systemctl restart mariadb              # allow
sudo journalctl -e -u mariadb               # allow (granted spelling)
: > /etc/my.cnf.d/zz-probe.cnf              # allow (EL) — config ACL; then rm
sudo systemctl restart sshd                 # DENY
sudo journalctl -e -u mysqld                # DENY (alias not granted)
echo x | sudo tee /var/lib/mysql/probe      # DENY — data dir never granted
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
- **Ownership is never reverted** — the `/var/lib/mysql` ownership entry is a
  no-op to revert anyway (it asserts the vendor state), so cleanup leaves the
  data dir exactly as the package shipped it.

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
   three footprints — including the Ubuntu box where apt started the daemon.
   TLS is therefore an explicit opt-in: a `[mariadbd]` `ssl_ca`/`ssl_cert`/
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
getfacl /var/log/mariadb/mariadb.log   # EL only — Ubuntu logs to journald
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
| `use_galera_new_cluster.conf` has no `User=` → runs as **root** | medium | all three | **Accept.** It's the `mariadb@bootstrap.service.d` drop-in, active only during a deliberate Galera cluster bootstrap, not normal operation — and the unit is not granted (read-only-units). Relevant only if you run Galera. | DBA/ops |
| `auth_pam_tool` is **setuid root** (`/usr/lib/mysql/plugin/auth_pam_tool_dir/`) | high | ubuntu | **Accept.** Vendor-shipped helper for MariaDB's PAM authentication plugin; setuid is required for it to check `/etc/shadow`. Not in any grant. Confirm it's still `0755 root:root` after upgrades; disable the PAM auth plugin if unused. | ops |
| `mariadb`/`mysql`/`mysqld`/`mariadb@` services grant **`CAP_IPC_LOCK`** (ambient) | high | ubuntu | **Accept.** Lets `mariadbd` lock its buffer pool into RAM (`memlock`), a standard DB tuning capability, scoped to the daemon. Vendor default; units are read-only in this profile. | DBA/ops |

EL (alma9/alma10) carries only the two medium Galera-bootstrap entries; Ubuntu
adds the setuid and `CAP_IPC_LOCK` highs above (13 raw entries, collapsing to
3 logical findings). None require a profile change — they are properties of the
vendor units, which this read-only-units profile never grants write to.

## 12. Storage and growth

Install-time floor, summed from the `filesystem` block of each
`footprints/<distro>/footprint-mariadb.json`:

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Install floor (all added files) | **241.3 MB** | **257.0 MB** | **493.0 MB** |
| Dominated by | binaries 170.6 MB + libraries 69.8 MB; `mariadb-backup` 25 MB, `mariadbd` 24.7 MB | binaries 197.5 MB + libraries 56.7 MB; `mariadb-backup` 22.6 MB, `mariadbd` 22.0 MB | binaries 353.7 MB; `mariadbd` 27.4 MB — **plus an initialised data dir** |
| Of which `/var/lib/mysql` | none — capture is pre-first-start (empty dir only) | none — pre-first-start | **~124 MB** — apt auto-started the daemon, so InnoDB is already allocated |

Treat that as a **floor, not a forecast** — it answers "will it fit", never
"how fast will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).
`/var/log` is excluded from footprints, so no log volume is priced in here.

**The three numbers are not comparable, and the EL pair understates the real
floor.** Ubuntu's 493.0 MB includes the InnoDB baseline the daemon allocated at
first start; the EL captures are pre-first-start (§1), so an EL host pays that
same allocation *after* handover. Budget the EL floor as install + the InnoDB
baseline below. The sums also count the usr-merge duplicate paths
(`/bin` ↔ `/usr/bin`) as separate entries — the same convention as every other
app row in this library, and the same duplication flagged in §11.

Growth drivers, worst first:

| Driver | Bounded? | Detail |
| --- | --- | --- |
| Dataset in `/var/lib/mysql` | **No** | The unbounded path, and the one **never granted** (§3). The team cannot measure it from the filesystem at all — dataset-size questions go through the SQL client. |
| Binlogs | **No — once enabled** | **No binlog files appear in any footprint**, including the Ubuntu capture whose data dir is fully initialised: binary logging is off as shipped. Once a team sets `log_bin` (replication, PITR), retention is `binlog_expire_logs_seconds` or an explicit `PURGE BINARY LOGS`; **rotation of log files never touches them** `[app-knowledge]`. Classic disk-full cause. |
| InnoDB redo + system tablespace | Yes — preallocated, fixed | Ubuntu capture: `ib_logfile0` 96 MB, `ibdata1` 12 MB. Allocated at first start, which is why the EL floor above omits it. |
| `ibtmp1` temp tablespace | **No — within a run** | 12 MB at first start (Ubuntu capture); grows with large sorts and temp tables and only returns to its initial size on restart `[app-knowledge]`. |
| `/var/log/mariadb/*` | Yes — package fragment | `/etc/logrotate.d/mariadb` ships on all three distros (§1). N/A on ubuntu-24.04 — the directory does not exist (§2 REVIEW-DROP). |
| journal | Yes — journald `SystemMaxUse` | Ubuntu's only error-log destination. On EL it carries startup/shutdown unless `log_error` targets a file (§10). |

**A separate volume is warranted — this is a database.** Mount it at
**`/var/lib/mysql`**, the app's own data path, never a new path with a symlink
or a `datadir=` override: the ownership assertion, the SELinux policy module
(§1) and the team's grants are all written against the canonical path.

Ordering differs from the webserver profiles in one useful way — `/var/lib/mysql`
is **not** a granted path here, so the mount-hides-ACLs trap does not bite the
team's grants at the canonical mount point. What a fresh filesystem *does* wipe
is the vendor state this profile asserts:

1. mount at `/var/lib/mysql`,
2. restore `mysql:mysql 0755` and, on EL, `restorecon -Rv /var/lib/mysql` — the
   package ships the policy module (§1), and mounting at the canonical path
   means no `semanage fcontext -e` equivalency is needed,
3. **re-apply playbook 5** (§4) — it re-asserts the ownership entry,
4. confirm: `ls -ld /var/lib/mysql` shows `mysql:mysql 0755` and `getfacl` shows
   **no** team ACL on it (§4), while `getfacl` on the config drop-in dir and, on
   EL, `/var/log/mariadb` still shows the team entry + `default:`.

If ops instead splits logs onto their own volume at `/var/log/mariadb` (EL), that
*is* a granted path and the trap applies in full — re-apply, then `getfacl`. Full
procedure:
[separate volumes: when and where](../../concepts/storage.md#separate-volumes-when-and-where).

Retention reality: file logs rotate on the shipped `/etc/logrotate.d/mariadb`
fragment (create-mode detail in §10) on EL; **Ubuntu has no log files to rotate**
— the error stream goes to journald, bounded by journald defaults. Binlog
retention is neither of those: it is a server variable, and purging needs the
service account or root. None of the three is in any profile — **retention or
frequency changes are an ops request**, handled in a change window.
