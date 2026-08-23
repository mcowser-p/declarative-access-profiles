# MySQL — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/mysql/<distro>-access.yml` — alma9
([reviewed](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/almalinux-9-access.yml),
[raw](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/almalinux-9-raw.yml)),
ubuntu 24.04
([reviewed](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/ubuntu-24.04-access.yml),
[raw](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/ubuntu-24.04-raw.yml)),
ubuntu 26.04
([reviewed](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/ubuntu-26.04-access.yml),
[raw](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/ubuntu-26.04-raw.yml))
— each untouched `-raw.yml` sibling is the review baseline. Role fit and
adopt/wrap decision: [role-eval](../../role-evals/mysql.md). Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

MySQL covers **AlmaLinux 9 + Ubuntu 24.04 + Ubuntu 26.04**: the Ubuntu cells
are the wave-2 flip (the wave-1 "mariadb covers Ubuntu" cut is over). Two cells
stay N/A — **alma10** (`mysql-server` dropped from EL10; mariadb is the
packaged option) and **al2023** (`mysql` not packaged in AL2023 — community RPM
only, out of scope).

This is a **database** profile — config-scoped by class: config + logs via ACL,
**no pam_group**, and the data directory (and its `mysql-files` / `mysql-keyring`
siblings) is never granted. See §3 and
[the database exception](../../concepts/access-model.md).

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-mysql.json` (schema 1.0, all captured
2026-08-23 on the KVM golden images — hosts `dap-alma9`, `dap-ubuntu2404`,
`dap-ubuntu2604`; treadmark 0.11.0). alma10 and al2023 are N/A per the intro;
their cells below read N/A.

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| App package | `mysql-server` (MySQL 8.0) | N/A | `mysql-server` (8.0 — the logcheck fragments are named `mysql-server-8_0`) | `mysql-server` (fragments unversioned) | N/A |
| Files added / modified / deleted | 1895 / 1952 / 0 | N/A | 716 / 45 / 0 (clean-guest re-capture) | 425 / 51 / 197 | N/A |
| Units installed | `mysqld.service` + `mysqld@.service` template, each under `/usr/lib` and `/lib` (usr-merge; 4 paths). No sockets, no timers. | N/A | `mysql.service` (2 usr-merge paths) **+ the enablement symlink** `/etc/systemd/system/multi-user.target.wants/mysql.service` (apt auto-start). **No template unit.** Legacy compat shipped too: `/etc/init.d/mysql` + upstart `/etc/init/mysql.conf`. | `mysql.service` (2 usr-merge paths) **+ the enablement symlink** `/etc/systemd/system/multi-user.target.wants/mysql.service` (apt auto-start enabled it). No legacy init artifacts. | N/A |
| Unit exec / identity | `ExecStart=/usr/libexec/mysqld --basedir=/usr`, `Type=notify`, `User=mysql` `Group=mysql`, `PrivateTmp=true`, `LimitNOFILE=10000`. No `ProtectSystem`/`NoNewPrivileges`/capabilities (`access_hints.hardening` null). | N/A | `ExecStart=/usr/sbin/mysqld`, `ExecStartPre=/usr/share/mysql/mysql-systemd-start pre`, `Type=notify`, `User=mysql` `Group=mysql`, `RuntimeDirectory=mysqld` (mode 755), `PermissionsStartOnly=true`, `TimeoutSec=infinity`, `LimitNOFILE=10000`. **No `PrivateTmp`**, no `ProtectSystem`/`NoNewPrivileges`. | same unit content as 24.04 | N/A |
| Accounts created | none new — `users_added`/`groups_added`/`membership_changes` all 0 (`mysql` pre-existed; shared-image note below). Clean-host: sysusers `mysql` uid/gid 27. | N/A | **`mysql` user + group created, 1 membership** (1/1/1 — clean-guest re-capture) | none new — `mysql` pre-existed (shared-image note) | N/A |
| Data dir (captured) | `/var/lib/mysql` `mysql:mysql 0755` — **present but empty** (dnf does not auto-start; `--initialize` never ran) | N/A | `/var/lib/mysql` `mysql:mysql 0700` — **initialized** (clean-guest re-capture): system tablespace, undo/redo, `binlog.000002` + index, the auto-generated TLS set (§9) | `/var/lib/mysql` `mysql:mysql 0700` — **initialized**: 192 state files incl. system tablespace, undo/redo, `binlog.000001` + `binlog.index` (binary logging live from first boot), the auto-generated TLS set (§9), `mysql_upgrade_history` | N/A |
| Data-adjacent dirs | `/var/lib/mysql-files` `mysql:mysql 0750`; `/var/lib/mysql-keyring` `mysql:mysql 0700` | N/A | `/var/lib/mysql-files` + `/var/lib/mysql-keyring` both `mysql:mysql 0700` (the all-0700 Debian posture); plus `/var/lib/mysql-upgrade` `root:root 0755` (packaging bookkeeping) + `/var/lib/mecab` dictionaries (dependency data) | `/var/lib/mysql-files` `mysql:mysql 0700` (tighter than EL9's 0750); `/var/lib/mysql-keyring` `mysql:mysql 0700`; `/var/lib/mysql-upgrade` `root:root 0755` | N/A |
| Config (captured) | `/etc/my.cnf` (just `!includedir /etc/my.cnf.d`); `/etc/my.cnf.d/` with `client.cnf` + `mysql-server.cnf` (all `root:root`, dirs 0755 files 0644) | N/A | added: `/etc/mysql/` tree with `mysql.conf.d/` (`mysqld.cnf` + `mysql.cnf`), `/etc/mysql/mysql.cnf`, and **`/etc/mysql/debian.cnf` `root:root 0600`** (clean-guest re-capture; no `FROZEN` marker — alternatives handled normally). `debian-start` modified. | added: `/etc/mysql/mysql.conf.d/` + `/etc/mysql/mysql.cnf`; `/etc/alternatives/my.cnf` switched; **`/etc/mysql/debian.cnf` `root:root 0600` rewritten** (the Debian maintenance-credential file, §2) + `debian-start` modified | N/A |
| MAC material | SELinux: policy module store `/var/lib/selinux/targeted/active/modules/200/mysql` (`root:root 0700`); `file_contexts` rebuilt | N/A | AppArmor: `usr.sbin.mysqld` + `local/usr.sbin.mysqld` override stub added | AppArmor: `usr.sbin.mysqld` **+ `local/usr.sbin.mysqld` override stub** added | N/A |
| logrotate fragment | `/etc/logrotate.d/mysqld` | N/A | `/etc/logrotate.d/mysql-server` | `/etc/logrotate.d/mysql-server` | N/A |
| Vendor sudoers shipped | none (`sudoers_files` empty, `sudo_rules` 0) | N/A | none | none | N/A |
| Notable binary | `/usr/libexec/mysqld` carries file capability `cap_sys_nice=ep` — the one `risks[]` entry, §11; `/usr/bin/mysql_ssl_rsa_setup` present (§9) | N/A | `/usr/sbin/mysqld` — **no capability xattr** (`file_capabilities` empty, `risks[]` empty); `mysql_ssl_rsa_setup` present | `/usr/sbin/mysqld` — no capability xattr; the auto-generated TLS set is captured directly (§9) | N/A |

`privilege.sudoers_files[]` is empty on all three — nothing to quote here.

**The shared-image capture artifact, in one place.** Each golden image ran the
**mariadb** capture earlier; the conflicting packages were removed before the
mysql re-baseline (`matrix.yml`). Three visible effects: (a) on the
shared-guest captures (alma9, ubuntu-26.04) the `mysql` account pre-existed,
so those raws show no principals and carry no `pam_group` to drop (§2); (b)
alma9's 1952 `files_modified` is mostly shared libraries/perl re-appearing,
not MySQL rewriting the system; (c) on 26.04 the install **swept out the
leftover mariadb client suite** (`files_deleted` = the `/bin/mariadb-*` tools,
`/usr/share/mariadb`, `libmariadb3`) and **replaced** the `mysql`-named paths
in place (`/usr/sbin/mysqld`, `/usr/bin/mysql*` count as *modified*, which
distorts the §12 install floor). A fourth effect existed and is **resolved**:
the original 24.04 capture ran after a remove-not-purge of mariadb, so the
postinst skipped data-dir initialization. The harness now purges conflicts
(`apt-get purge` + `autoremove --purge`), and the committed 24.04 evidence is
a **clean-guest re-capture** (716/45/0, principals 1/1/1) — the reference
Ubuntu shape alongside 26.04.

## 2. Raw → reviewed: the decisions

One row per delta, one table per reviewed distro.

**alma9** (from `almalinux-9-raw.yml`):

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

**ubuntu 24.04 + ubuntu 26.04** (from `ubuntu-24.04-raw.yml` /
`ubuntu-26.04-raw.yml`; the effective grant set — service `mysql`,
`/etc/mysql/mysql.conf.d`, `/var/log/mysql` — comes out identical on both,
so shared rows are marked *both*):

| Change | Distro | Tag | Why |
| --- | --- | --- | --- |
| Drop all `files_modify` (`mysql.service` under `/lib` + `/usr/lib`, plus `/etc/systemd/system/multi-user.target.wants/mysql.service`) | both | REVIEW-DROP | Vendor unit through the usr-merge symlink — unit-file write is root-equivalent. The third path is the **enablement symlink** apt created on auto-start: writable, it lets the team repoint what boots at `multi-user.target`; `enable`/`disable` are already granted as systemctl verbs. |
| Drop `pam_group` + `local_groups: ['mysql']` | 24.04 | REVIEW-DROP | The clean-guest capture created the `mysql` account, so the exporter emitted the webserver-style group route. Database class grants none — the group owns the raw data files; membership bypasses every SQL `GRANT`. Opt-in stays in §3. |
| No `pam_group` to drop | 26.04 | (note) | Same shared-image pre-existence as alma9 (`groups_added` 0). On a clean host the exporter emits it and the review drops it — exactly what the 24.04 row above shows. |
| Config ACL = `/etc/mysql/mysql.conf.d` — narrowed from the raw's whole `/etc/mysql` on 24.04 (REVIEW-CHANGE), kept as captured on 26.04; never widened to the tree |  both | REVIEW-CHANGE / kept | The Debian server drop-in dir (parallels EL's `/etc/my.cnf.d`). One level up sits `/etc/mysql/debian.cnf` (`root:root 0600`, captured on 26.04) — the historical debian-sys-maint credential file; a tree-wide recursive ACL would hand it to the team. Same reasoning as the mariadb-on-Ubuntu review. |
| Add `/var/log/mysql` to `folders_read` | both | REVIEW-ADD | `/var/log` is excluded from footprints. Unlike mariadb-on-Ubuntu (journald-only; its identical ADD failed apply-verification and was reverted), mysql's packaging ships `log_error = /var/log/mysql/error.log` in `mysqld.cnf` and creates the dir (`mysql:adm`) at install `[app-knowledge]`; the captured `/etc/logrotate.d/mysql-server` rotates exactly that file. `[needs-runtime-confirmation]` until the first KVM verify. |
| Drop `/etc/init` | 24.04 | REVIEW-DROP | Legacy **upstart** job dir (the package still ships `/etc/init/mysql.conf` + `/etc/init.d/mysql` on 24.04). Inert under systemd; vendor compat plumbing, not team config. Gone from the 26.04 package. |
| Drop `/var/lib/mecab` | 24.04 | REVIEW-DROP | mecab-ipadic full-text tokenizer dictionaries (`root:root 0755`, ~90 MiB) pulled in alongside mysql's mecab plugin — another package's read-only data. On 26.04 only the plugin/library landed, no dictionary tree. |
| Drop `/var/lib/mysql-upgrade` | both | REVIEW-DROP | Debian packaging's upgrade-bookkeeping dir (`root:root 0755`). Data-adjacent packaging state, not team space. |
| Drop `/var/lib/mysql` | both | REVIEW-DROP | The data directory (`mysql:mysql 0700` captured — Debian ships it tighter than EL9's 0755), initialized by the apt auto-start: raw tables, **live binlogs**, and the auto-generated TLS keys (§9). Never granted for a database, in any list. |
| Drop `/var/lib/mysql-files`, `/var/lib/mysql-keyring` | both | REVIEW-DROP | `secure_file_priv` import/export dir and the InnoDB encryption keyring (both `mysql:mysql 0700` here). Data-adjacent / at-rest keys — never granted; the keyring is *more* sensitive than the data dir. |
| Add `ownership` for `/var/lib/mysql`, `-files`, `-keyring` — all `mysql:mysql 0700` | both | REVIEW-ADD | Assert the captured all-0700 Debian posture and make drift visible. **Not** a grant. |

## 3. Access model for this app class

Database: **config-scoped**. Config drop-in write **ACL** (`/etc/my.cnf.d`;
Ubuntu: `/etc/mysql/mysql.conf.d`) + log read **ACL** (`/var/log/mysql`), **no
pam_group** into the service group, and
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
  -e @profiles/mysql/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" \
  -e '{"declarative_access_pam_group": true, "declarative_access_local_groups": ["mysql"]}'
```

Treat that as a reviewed exception, not a default — it grants read of every table
file on disk, and (once initialized) read of the `mysql-keyring` encryption keys
and the `ca.pem`/`server-key.pem` TLS material in the data dir.

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/mysql/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/mysql-rg-<host>-app-restricted` — `visudo -cf` it; confirm it
  lists `mysqld` (Ubuntu: `mysql`) bare + `.service`, and the `journalctl -u`
  spellings, and **no** `files_modify` entries.
- **No `group.conf` line** — this profile has no pam_group (database class); if
  you see a `mysql` mapping, someone used the §3 opt-in.
- `getfacl /etc/my.cnf.d` (Ubuntu: `/etc/mysql/mysql.conf.d`) — team group
  `rwx` + a `default:` entry.
- `getfacl /var/log/mysql` — team group `r-x` + `default:` (confirm the dir
  exists: `/usr/lib/tmpfiles.d/mysqld.conf` creates it on EL; the postinst
  creates it `mysql:adm` on Ubuntu `[app-knowledge]`).
- `/var/lib/mysql`, `/var/lib/mysql-files`, `/var/lib/mysql-keyring` — ownership
  asserted (alma9 `mysql:mysql 0755/0750/0700`; ubuntu 26.04 all `0700`; the
  24.04 profile has no ownership block — §2), and **no ACL should appear on any
  of them**; if one does, the profile was applied wrong.
- No linger (no rootless quadlets).

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Verification vehicle: `scripts/verify-profile-kvm.sh mysql <distro>` (KVM
guest, real playbook apply, probes, real `--tags cleanup`) — the authoritative
tier per [conventions §4](../../conventions.md). The alma9 profile carries its
2026-08-09 EC2-era stamp; both Ubuntu profiles are `# VERIFIED: pending` until
the batched KVM pass runs. On a live host (EL spellings; Ubuntu swaps
`mysqld`→`mysql` and `/etc/my.cnf.d`→`/etc/mysql/mysql.conf.d`):

```bash
sudo -l -U <pilot>                          # exactly the scoped grants
sudo systemctl restart mysqld               # allow
sudo journalctl -e -u mysqld                # allow (granted spelling)
: > /etc/my.cnf.d/zz-probe.cnf              # allow — config ACL; then rm
tail -n1 /var/log/mysql/mysqld.log          # allow — log ACL (no sudo; Ubuntu: error.log)
sudo systemctl restart sshd                 # DENY
sudo journalctl -e -u mysql                 # DENY on EL (granted is mysqld — inverts on Ubuntu)
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
  `/etc/my.cnf.d`; on Ubuntu the chain includes `/etc/mysql` itself —
  traverse-only, not the write ACL) — shared across profiles; remove manually
  with `setfacl -x g:<group> <dir>` only if the entity has no other profiles.
- **Ownership is never reverted** — the `/var/lib/mysql*` ownership entries
  (three on alma9 and ubuntu 26.04; none on 24.04, §2) re-assert vendor state
  anyway, so cleanup leaves those dirs exactly as the package shipped them.

## 8. Drift and patching

A nice property of the config-scoped DB profile: it makes **no vendor-permission
deviation**. The only ownership entries re-assert the captured `mysql:mysql`
modes on the data + data-adjacent dirs, so `rpm -V mysql-server` (Ubuntu:
`dpkg --verify` + `debsums`) stays clean — there is **no setgid content dir to
add to the golden-baseline accept-list**
(unlike the webserver profiles). ACLs are invisible to `rpm -V` either way. The
`cap_sys_nice` file capability on `/usr/libexec/mysqld` (§11) is vendor-shipped —
record it in the accept-list so a capability audit doesn't read it as tampering.
That entry is **EL-only**: the Ubuntu `mysqld` carries no capability xattr
(§1), so an Ubuntu capability audit should find nothing to accept.

Package upgrades replace files and **shed file ACLs** — the config drop-in dir
and log dir ACLs vanish after `dnf update` / `apt upgrade`. Remedy: re-run
playbook 5 with the
same inputs (idempotent), then `getfacl` to confirm. On authselect-managed EL
hosts, `authselect apply-changes` can drop a pam_group line from
`/etc/pam.d/sshd` — not a concern for *this* profile (no pam_group), but it still
affects the host-level `app-full → wheel` mapping, so re-run the host access
playbook after authselect changes (Ubuntu's `pam-auth-update` has no such
interaction with this profile).

## 9. TLS: key ownership and rotation

Two MySQL-specific facts, both grounded in the captures:

1. **MySQL auto-generates a self-signed TLS set at first init — captured on
   ubuntu-26.04.** Unlike MariaDB (which ships TLS off), MySQL 8 runs the
   equivalent of `mysql_ssl_rsa_setup` (the tool is in the alma9 and 24.04
   footprints) at its first `--initialize`, creating the certs **inside the
   data directory**. The 26.04 capture shows the whole set in
   `/var/lib/mysql`: `ca.pem`/`server-cert.pem`/`client-cert.pem`/
   `public_key.pem` `mysql:mysql 0644`, and `ca-key.pem`/`server-key.pem`/
   `client-key.pem`/`private_key.pem` `mysql:mysql 0600`. On alma9, dnf did
   not auto-start and the data dir was captured empty — the same files appear
   at first initialization; on 24.04 the init never ran in this capture
   (§1 note). `[app-knowledge]` for the two uninitialized distros, evidence
   on 26.04.
2. **The key lands in the ungranted data dir, and `mysqld` reads it as `mysql`.**
   This is the PostgreSQL-on-EL situation: `server-key.pem` lives inside
   `/var/lib/mysql` (never granted), so **key rotation is always ops**. When
   replacing the self-signed default with a CA-signed pair, ops places the key
   **readable by the `mysql` account** — `root:mysql 0640` under
   `/etc/pki/tls/private` with the correct SELinux label (Ubuntu:
   `/etc/ssl/private`; and since AppArmor confines `mysqld` file access, a key
   outside the profile's allowed paths needs a rule in the shipped
   `/etc/apparmor.d/local/usr.sbin.mysqld` override stub `[app-knowledge]`) —
   `mysqld` runs `User=mysql`, so unlike nginx/httpd it is the service
   account, not root, that reads the key. Point
   `ssl_key`/`ssl_cert`/`ssl_ca` at it via a `[mysqld]` drop-in in the team's
   granted drop-in dir.

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
logrotate -f /etc/logrotate.d/mysqld        # Ubuntu: mysql-server
getfacl /var/log/mysql/mysqld.log           # Ubuntu: error.log — team group present, no #effective:---
```

The `create`-mode in the fragment sets the ACL mask on each fresh
file `[needs-runtime-confirmation on this host]`. Two database-specific caveats:

- **`log-error` may target the journal, not a file — on EL.** If MySQL logs
  errors to stderr/journald rather than `/var/log/mysql/mysqld.log`, the
  log-dir read ACL grants access to an empty or non-existent file — the journal
  grant is what matters. Confirm the effective `log-error` destination before
  relying on file read `[needs-runtime-confirmation]`. On Ubuntu the packaged
  `mysqld.cnf` sets `log_error = /var/log/mysql/error.log`, so the file log is
  the default there `[app-knowledge]`.
- **General/slow query logs can be SQL tables, not files.** With
  `log_output=TABLE` they live in `mysql.general_log` / `mysql.slow_log` inside
  the (ungranted) data dir. Keep `log_output=FILE` to land them in the granted
  log dir; otherwise they are SQL-client-only. This is MySQL's self-logging
  equivalent of the PostgreSQL `log_file_mode` case in
  [logging](../../concepts/logging.md).

## 11. Known risks (from `risks[]`)

The alma9 footprint carries exactly **one** `risks[]` entry; both Ubuntu
footprints carry **none** (`risks: []`, `file_capabilities` empty — the EL
capability xattr below simply does not exist on the Debian build).

| Finding | Severity | Decision | Detail |
| --- | --- | --- | --- |
| `/usr/libexec/mysqld` carries a `security.capability` xattr | **high** | **Accept** | The captured xattr (`0100000200008000…`) decodes to **`cap_sys_nice=ep`** (effective + permitted, VFS caps v2). It lets `mysqld` raise thread scheduling priority / set CPU affinity without running as root — a standard MySQL-on-EL tuning capability, scoped to the daemon binary. Vendor-shipped; the binary (`root:root 0755`, under `/usr/libexec`) is in **no** grant, and the unit adds no further capabilities. Record it in the golden-baseline/capability accept-list; no fix. If thread-priority tuning is unwanted, `setcap -r` it (ops), but that is a hardening choice, not a defect. |

Context (not a `risks[]` entry, but worth an accept-or-fix note): on every
distro the units set **no** `ProtectSystem`, `PrivateDevices`,
`NoNewPrivileges`, or capability confinement (`access_hints.hardening` all
null). alma9's unit at least sets `PrivateTmp=true`; the Ubuntu unit does not
even do that — its MAC compensation is the shipped **AppArmor profile**
`/etc/apparmor.d/usr.sbin.mysqld` (§1), where EL relies on the SELinux policy
module. Adding a systemd hardening drop-in is overlay/platform work — it
belongs in `/etc/systemd/system/mysqld.service.d/` (Ubuntu:
`mysql.service.d`), owned by the overlay, **never** in
the team profile, since a unit-drop-in write ACL is root-equivalent. See the
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

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Install floor (all added files) | **335.3 MB** / 1895 files | N/A — `mysql-server` dropped from EL10 | **710.2 MB** / 716 files (clean-guest re-capture; includes the initialized data dir) | **370.6 MB** / 425 files | N/A — not packaged in AL2023 |
| Largest category | `binary` 216.0 MB, of which `/usr/libexec/mysqld` alone is 53.9 MB; then `library` 102.4 MB | N/A | `state_dir` **~200 MB — the initialized data dir**; then `binary` (incl. `/usr/sbin/mysqld`) and the **mecab tokenizer data** (~144 MB; 90.1 MB of `/var/lib/mecab` dictionaries alone) | `state_dir` **200.3 MB — the initialized data dir**; then `binary` 144.0 MB | N/A |
| Data dir inside that total | **none** — dnf never ran `--initialize`; `/var/lib/mysql` was captured empty (§1) | N/A | **~200 MB** — first-boot state, same shape as 26.04 | **200.3 MB** — first-boot state before a single row exists | N/A |

Per-distro distortions to size around. **alma9**: the floor counts both
usr-merge spellings of every binary and library (`/bin` and `/usr/bin` are the
same inode — the same duplication as the four unit paths in §1), so the
deduplicated allocation is nearer 203 MB; size to the larger number. **26.04's
floor undercounts the server itself**: its shared-image baseline meant
`/usr/sbin/mysqld` (55–62 MB) and the client tools **replaced** existing paths
and count as *modified*, not added (§1 note) — add roughly the binary payload
back. **24.04's clean-guest floor is the honest all-in number** (server +
~144 MB mecab dictionaries 26.04's dependency set didn't pull + the ~200 MB
first-boot data dir). What the alma9 row still lacks is that first data dir:
both Ubuntu captures measure it — the first start writes **~200 MB** of system
tablespace, undo/redo and TLS material before any data
(`innodb_redo_log_capacity` alone reserves 100 MB `[app-knowledge]`). Budget
every host as package payload **plus** ~200 MB of first-boot data dir.

### What grows after install

| Component | Where | Bounded? | Driver |
| --- | --- | --- | --- |
| Dataset | `/var/lib/mysql` | **No** | tables and indexes; InnoDB does not return freed space to the filesystem until a tablespace is rebuilt `[app-knowledge]` |
| Binary logs | `/var/lib/mysql`, `binlog.NNNNNN` — live from first boot (`binlog.000001` is in the 26.04 capture) | Only by `binlog_expire_logs_seconds` (30 days by default) | see below — the fastest and least visible way to fill this volume `[app-knowledge]` |
| Redo / undo | `/var/lib/mysql` | **Yes** — fixed capacity | `innodb_redo_log_capacity`, 100 MB default `[app-knowledge]` |
| Import/export payloads | `/var/lib/mysql-files` (`mysql:mysql` — `0750` on alma9, `0700` on ubuntu 26.04, §1) | **No** | `SELECT ... INTO OUTFILE` / `LOAD DATA` files. REVIEW-DROPped (§2), so the team can neither see nor clear them |
| Dumps / backups | wherever ops points `mysqldump`/`mysqlsh` — **no backup dir ships** in the footprint | **No** | each full copy needs headroom ≈ the dataset |
| Log files | `/var/log/mysql` (EL: created by `/usr/lib/tmpfiles.d/mysqld.conf`; Ubuntu: by the postinst; `/var/log` is excluded from footprints) | **Yes** — the shipped fragment | verbose general/slow query logging |
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

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Mount point | `/var/lib/mysql` — dataset **and** binlogs | N/A | `/var/lib/mysql` | `/var/lib/mysql` | N/A |
| Required state on the new fs root | `mysql:mysql 0755` (captured, §1) | N/A | `mysql:mysql 0700` — no captured state in this footprint (§1 note); the 26.04 capture is the Debian reference | `mysql:mysql 0700` (captured, §1) | N/A |
| Restored by playbook 5? | **Yes** — the profile asserts ownership on exactly this path (§2) | N/A | **No** — the 24.04 profile carries no ownership block (nothing captured to assert, §2); restore by hand or re-capture | **Yes** — ownership asserted (§2) | N/A |
| *Not* covered by that mount | `/var/lib/mysql-files` (0750) and `/var/lib/mysql-keyring` (0700) are **siblings**, not children — mount them separately or leave them on root | N/A | same sibling caveat | same (both 0700 here) | N/A |
| MAC relabel / confinement | SELinux relabel required (EL enforcing); mounting at the app's own path keeps the existing fcontext rules, so `restorecon -Rv /var/lib/mysql` suffices — a *new* path needs `semanage fcontext -a -e` first | N/A | no SELinux step — AppArmor confines by **path**, so mounting *at* `/var/lib/mysql` needs nothing; a *different* data path needs an alias rule in `/etc/apparmor.d/local/usr.sbin.mysqld` (§13) `[app-knowledge]` | same as 24.04 (the local override stub is in the capture) | N/A |

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
  5 restores at `/var/lib/mysql` is the ownership assertion (§2; on ubuntu
  24.04 there is none — restore by hand per the table above). The ACL'd
  paths are `/etc/my.cnf.d` (Ubuntu: `/etc/mysql/mysql.conf.d`) and
  `/var/log/mysql`; a separate **log** volume is
  the realistic case where
  [the mount trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it)
  actually costs the team its access.

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/mysql/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
stat -c '%U:%G %a' /var/lib/mysql     # mysql:mysql 755 (Ubuntu: 700)
getfacl /var/log/mysql                # team entry back, no #effective:---
```

### Log retention

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Rotation fragment shipped | `/etc/logrotate.d/mysqld` `root:root 0644` | N/A | `/etc/logrotate.d/mysql-server` `root:root 0644` | `/etc/logrotate.d/mysql-server` `root:root 0644` | N/A |
| Default sink | `/var/log/mysql/mysqld.log` per the packaged `mysql-server.cnf` `log-error`, plus journald — the effective destination is `[needs-runtime-confirmation]` (§10) | N/A | `/var/log/mysql/error.log` per the packaged `mysqld.cnf` `[app-knowledge]`, plus journald for unit lifecycle | same as 24.04 | N/A |
| Bounded out of the box | yes — the shipped fragment for files, journald `SystemMaxUse` for the journal | N/A | yes — same mechanisms | yes — same | N/A |
| Team can change retention | no — the fragment is `root:root`, outside the grant | N/A | no — same | no — same | N/A |

Two MySQL caveats on top of that: **binlog retention is not logrotate's job**
(it is `binlog_expire_logs_seconds` / `PURGE BINARY LOGS`, superuser SQL,
above), and with `log_output=TABLE` the general/slow query logs move **into**
the data dir as `mysql.general_log` / `mysql.slow_log`, where no fragment
governs them and they grow the dataset instead (§10). Either way, retention
changes are an ops request; whether the team can still *read* a rotated file
is the mask caveat in §10.

## 13. Disk layout & data volume

The database contract, restated once: **`/var/lib/mysql` gets its own volume,
and no profile ever grants it** — the
[database exception](../../concepts/access-model.md) means the team
administers through SQL while the volume underneath it is pure ops territory.
Sizing, the mount-at-the-data-path rule and the per-distro required state are
§12; the doctrine ordering is
[storage](../../concepts/storage.md#separate-volumes-when-and-where). This
section is the KVM-substrate mechanics for getting that volume onto a host.

### Attaching a data disk to a holy-qcow KVM VM

The holy-qcow `vm` module provisions the **root disk only** — a `data_disk_gb`
variable on the upstream module is future work, **not scheduled**. Until then
the data disk is a post-deploy step on the KVM host:

```bash
virsh vol-create-as vmdisks <name>-data.qcow2 <size>G --format qcow2
virsh vol-path --pool vmdisks <name>-data.qcow2                 # prints <path> for the attach
virsh attach-disk <domain> --source <path> --target vdb --persistent --subdriver qcow2
```

Keep the volume in the `vmdisks` pool — the host-side AppArmor accommodation
already covers that pool, so libvirt opens the image without further host
policy work. `--persistent` writes the disk into the domain XML (it survives
reboot); the guest sees `/dev/vdb`.

### Guest-side: mkfs, move, mount

All of it ops — none of these commands exists in any team grant
([storage doctrine](../../concepts/storage.md#storage-is-an-access-problem-not-only-a-capacity-problem)):

```bash
mkfs.xfs /dev/vdb                     # or ext4 — both carry ACLs [app-knowledge]
systemctl stop mysqld                 # Ubuntu: mysql — never copy under a running server
mount /dev/vdb /mnt
cp -a /var/lib/mysql/. /mnt/          # -a preserves owner, mode and ACLs
umount /mnt
echo "UUID=$(blkid -s UUID -o value /dev/vdb) /var/lib/mysql xfs defaults,nofail 0 0" >> /etc/fstab
systemctl daemon-reload
mount /var/lib/mysql
restorecon -R /var/lib/mysql          # EL ONLY — fresh filesystems come up unlabeled (§12 table)
systemctl start mysqld                # Ubuntu: mysql
```

On Ubuntu there is **no relabel step** — AppArmor confines by path, so a
mount *at* `/var/lib/mysql` needs nothing. Only if the data dir **moves to a
new path** does AppArmor bite: add
`alias /var/lib/mysql/ -> /data/mysql/,` to `/etc/apparmor.d/tunables/alias`
(or a rule in the shipped `local/usr.sbin.mysqld` stub) and reload the
profile, or `mysqld` will be denied its own files. `[app-knowledge]`

Then finish per the doctrine: **re-apply playbook 5 and `getfacl`** (§12
Ordering — the mount-hides-ACLs rule; on this app the data path itself holds
no ACL, but the ownership assertion and any log/config mounts do get
restored).

### Growth

In-place growth of an attached volume (grow the qcow2 on the host, then
partition/LVM/filesystem in the guest) is automated by
[mcowser_p.fleet_medic](https://github.com/mcowser-p/fleet-medic)'s
`disk_expand` role — threshold-driven and cleanup-first, per
[growing existing volumes](../../concepts/storage.md#growing-existing-volumes).
Growing in place never remounts, so the ACL grants on the filesystem survive;
only *new* mounts trigger the re-apply rule above.
