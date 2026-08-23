# PostgreSQL — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/postgresql/{almalinux-9,almalinux-10,ubuntu-24.04,ubuntu-26.04,amazonlinux-2023}-access.yml`
([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/almalinux-10-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/ubuntu-24.04-access.yml),
[ubuntu 26.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/ubuntu-26.04-access.yml),
[al2023](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/amazonlinux-2023-access.yml))
with their untouched `-raw.yml` siblings. Role choice:
[the postgresql role evaluation](../../role-evals/postgresql.md). Lifecycle
mechanics: [concepts/lifecycle.md](../../concepts/lifecycle.md).

PostgreSQL is a **database**: the profile is config-scoped, grants **no**
`pam_group`, and **never** grants the data directory. The reasoning is in
[§3](#3-access-model-for-this-app-class) and
[the database exception](../../concepts/access-model.md).

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-postgresql.json` (schema 1.0, captured
2026-08-23 on holy-qcow KVM golden images, host `ansible@192.168.1.238`;
treadmark 0.11.0). The KVM re-capture reproduced the 2026-08-09 EC2
captures' raw profiles grant-for-grant on the three original cells (only
the generator/date header lines differ), so those reviews stand unchanged.

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| files added / modified | 344 / 132 | 347 / 148 | 3954 / 45 | 4043 / 47 | 348 / 136 |
| systemd units | 4 (`postgresql.service` + `postgresql@.service`, usr-merge ×2) | 4 (same) | 19 (umbrella + cluster template + backup automation) | 22 (24.04's 19 + `ssl-cert.service` ×3: unit under `/lib` + `/usr/lib` and its enablement symlink) | 4 (same as alma9) |
| Units the team operates | `postgresql.service` | `postgresql.service` | `postgresql.service` (umbrella) + `postgresql@16-main` (cluster instance) | `postgresql.service` (umbrella) + `postgresql@18-main` (cluster instance) | `postgresql.service` |
| Dependency/feature units | none | none | `pg_basebackup@`, `pg_compresswal@`, `pg_dump@`, `pg_receivewal@` (`.service`/`.timer`) — postgresql-common backup automation, not started by default | same, plus `ssl-cert.service` — root oneshot, enabled, `ConditionPathExists=!/etc/ssl/private/ssl-cert-snakeoil.key` ((re)creates the snakeoil pair when the key is absent) | none |
| Accounts created | `postgres` uid 26 gid 26, home `/var/lib/pgsql`, shell `/bin/bash` | same | `postgres` uid 111 gid 116, home `/var/lib/postgresql`, shell `/bin/bash`, **added to `ssl-cert`** (gid 113, pre-existing) | `postgres` uid 103 gid 110, home `/var/lib/postgresql`, shell `/bin/bash`, **added to `ssl-cert`** (gid 109, created by this install) | `postgres` uid 26 gid 26, home `/var/lib/pgsql`, shell `/bin/bash` — same identity as alma9 |
| Config (captured owner:mode) | only `/etc/postgresql-setup` root:root 0755 (upgrade tooling — the DB config does not exist until `initdb`) | same | `/etc/postgresql/16/main` postgres:postgres 0755; `postgresql.conf` 0644; `pg_hba.conf` 0640; `/etc/postgresql-common` root:root 0755 | identical tree and modes at `/etc/postgresql/18/main` | same as alma9 |
| Data dir (captured) | `/var/lib/pgsql` (+ empty `/data`, `/backups` skeletons) **drwx------ postgres:postgres 0700** | same | `/var/lib/postgresql/16/main` **drwx------ postgres:postgres 0700** (parent `/var/lib/postgresql` 0755) | `/var/lib/postgresql/18/main` **drwx------ postgres:postgres 0700** (parent 0755) | same as alma9 |
| Log dir | none (logs to journal; collector, if enabled, writes into the 0700 data dir) | none | `/var/log/postgresql` (+ `/etc/logrotate.d/postgresql-common` root:root 0644) | same | none |
| Vendor sudoers shipped | none (`privilege.sudoers_files` empty) | none | none | none | none |
| PAM touched | **`/etc/pam.d/postgresql`** (see §11) | same | none | none | same file as alma9 (see §11) |

The Ubuntu footprints are an order of magnitude larger because the
`postgresql` meta-package pulls a versioned server — postgresql-16 on 24.04,
**postgresql-18 on 26.04** — and **apt ran `initdb` + auto-started the
cluster**, so the live config tree and the populated data dir are in the
capture (995 / 998 `state_dir` entries). EL-family captures have no
*populated* data dir: `dnf` does not start the service, `postgresql-setup
--initdb` has not run, and `/var/lib/pgsql/{data,backups}` ship as empty
0700 skeletons with no `postgresql.conf` on disk. Raw profiles are therefore
not line-comparable across the families. **al2023 evidence note:** the
package is versioned (`postgresql17-server`) but every captured path is
unversioned and alma-identical — `postgresql.service`, `/usr/bin/postgres`,
`/usr/share/pgsql`, `/var/lib/pgsql` — so the reviewed profile is identical
to alma9/alma10 (see §2); the version lives only in the package name.

## 2. Raw → reviewed: the decisions

| Change | Distro | Tag | Why |
| --- | --- | --- | --- |
| Drop all `files_modify` (EL family: 4 unit paths; ubuntu 24.04: 19; ubuntu 26.04: 22) | all | REVIEW-DROP | Vendor units incl. the umbrella, the cluster template, Ubuntu's backup automation and the enablement symlink(s); 26.04's count adds `ssl-cert.service` under `/lib` + `/usr/lib` and its own enablement symlink. A unit-file write ACL is root-equivalent for that unit. Read-only-units profile. |
| Drop `pam_group` + `local_groups: [postgres]` | EL family (alma9, alma10, al2023) | REVIEW-DROP | Database class: `postgres` is the data-owning group. See §3. (Neither Ubuntu raw had a pam_group to drop.) |
| Drop `folders_modify: /etc/postgresql-setup` | EL family | REVIEW-DROP | root:root postgresql-setup **upgrade** tooling, not team config. |
| Drop `folders_modify: /var/lib/pgsql` | EL family | REVIEW-DROP | The 0700 data dir; config lives inside it. **Never grant the data dir.** |
| Drop `ssl-cert` from `services` | ubuntu 26.04 | REVIEW-DROP | Dependency noise, not the app: the ssl-cert package's root oneshot ((re)creates the host-wide snakeoil pair when the key is absent, `ConditionPathExists` guard). Host key material shared by every service is never a team surface. New unit on 26.04 — 24.04's raw never listed it. |
| Narrow `folders_modify: /etc/postgresql` → `/etc/postgresql/16/main` (26.04: `/etc/postgresql/18/main`) | Ubuntu | REVIEW-CHANGE | Config split out of the data dir; the write ACL (+ default ACL for new `conf.d` drop-ins) reaches the cluster config without touching `/var/lib/postgresql/16/main` (26.04: `18/main`). |
| Drop `folders_modify: /etc/postgresql-common` | Ubuntu | REVIEW-DROP | root:root postgresql-common package tooling (upgrade hooks, logrotate, pg_ctl defaults). |
| Drop `folders_modify: /var/lib/postgresql` | Ubuntu | REVIEW-DROP | Data-dir root (contains the 0700 `16/main` / `18/main` data dir). Never grant the data dir. |
| Add the cluster unit to `services`: `postgresql@16-main` (26.04: `postgresql@18-main`) | Ubuntu | REVIEW-ADD | The umbrella `postgresql.service` is a `/bin/true` oneshot; the `postgresql@<ver>-main` instance is the real cluster unit (evidence: the `postgresql@.service` template + the versioned config and data dirs). Lets the team act on just their cluster. |
| Add `folders_read: /var/log/postgresql` | Ubuntu | REVIEW-ADD | `/var/log` is excluded from footprints by default; Debian's cluster logs there. |
| Keep `ownership` entries as captured | all | as captured | Enforce install-time ownership of the data dir (EL family) and the config-tree/data-root (Ubuntu). Assertions, not ACLs — they grant nothing and keep drift visible. |

The amazonlinux-2023 raw is byte-identical to alma9/alma10's, so its reviewed
profile applies the same drops and is identical to theirs apart from the
header (the profile says so, per the review rules).

## 3. Access model for this app class

**Database — config-scoped, not group-scoped.** The reduced decision table
([access model](../../concepts/access-model.md)):

- **No `pam_group`.** The `postgres` group owns the raw data. Membership is
  the standing boundary a database keeps closed, and — because the data dir
  is `0700 postgres:postgres` — it also buys the team nothing they need
  (config is handled by an ACL on Ubuntu and by SQL on EL; logs by an ACL).
  Filesystem access to data files would bypass every SQL `GRANT` the server
  enforces `[app-knowledge]`, so administration is by SQL client +
  `systemctl`, never by editing the data tree.
- **Config** — write **ACL** on the config *files/dirs only* (Ubuntu:
  `/etc/postgresql/16/main` on 24.04, `/etc/postgresql/18/main` on 26.04).
  On EL — alma9, alma10 and al2023 alike — there is no on-disk config to ACL
  until `initdb`, and it then lives inside the 0700 data dir — so EL config
  changes are `ALTER SYSTEM` (SQL) or an ops edit as `postgres`.
- **Logs** — read **ACL** (Ubuntu: `/var/log/postgresql`); journal via the
  scoped `journalctl` grants on both families.
- **Never** the data dir (`/var/lib/pgsql/data`;
  `/var/lib/postgresql/16/main` / `18/main`).

**The pam_group apply-time opt-in.** A team that knowingly accepts the
tradeoff can request group membership at apply time without editing the
profile:

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/postgresql/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" \
  -e declarative_access_pam_group=true \
  -e '{"declarative_access_local_groups": ["postgres"]}'
```

On stock modes this grants little beyond config-tree *read* on Ubuntu (the
data dir stays 0700), but it is a standing membership in the data-owning
group — grant it only with a recorded reason, and never as the default.

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/postgresql/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/postgresql-rg-<host>-app-restricted` — `visudo -cf` it;
  confirm it lists `postgresql` (Ubuntu also the cluster unit —
  `postgresql@16-main` on 24.04, `postgresql@18-main` on 26.04) and the
  `journalctl -u` spellings, and **no** `files_modify` entries. On 26.04 also
  confirm **no** `ssl-cert` service lines (dropped in review, §2).
- **No** `group.conf` line and **no** `local_groups` — this is a database
  profile; if you see a pam_group mapping, someone used the §3 opt-in.
- `getfacl /etc/postgresql/16/main` (26.04: `18/main`) and
  `getfacl /var/log/postgresql`
  (Ubuntu) — team group present with the default ACL. On EL — al2023
  included — there are no ACL
  targets; the profile is sudoers + the data-dir ownership assertion.

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Runner: `scripts/verify-profile.sh postgresql <distro>` (init container) or
`scripts/verify-profile-kvm.sh --app postgresql` (real holy-qcow guests —
authselect, real PAM/sshd, SELinux or AppArmor; the stamp records the exact
image). Status: alma9, alma10 and ubuntu-24.04 hold `VERIFIED: 2026-08-09`
stamps (EC2); the ubuntu-26.04 and amazonlinux-2023 profiles are reviewed
but `VERIFIED: pending` until a KVM run passes. On a live
host, as a user holding **only** app-restricted:

```bash
sudo -l -U <pilot>                              # exactly the scoped grants
sudo systemctl reload postgresql                # allow (Ubuntu: @16-main / @18-main)
sudo journalctl -e -u postgresql                # allow (granted spelling)
sudo systemctl restart sshd                     # DENY
echo x | sudo tee /usr/lib/systemd/system/postgresql.service   # DENY
sudo systemctl restart ssl-cert                 # 26.04: DENY (dropped in review)
# Ubuntu — config write via ACL (24.04 shown; 18/main on 26.04.
# No fresh login needed; ACLs are immediate):
touch /etc/postgresql/16/main/conf.d/.probe && rm $_            # allow
tail -n1 /var/log/postgresql/postgresql-16-main.log            # allow (ACL)
# both families — the data dir stays closed:
sudo -u '#0' true 2>/dev/null; ls /var/lib/pgsql/data 2>&1     # EL: DENY
ls /var/lib/postgresql/16/main 2>&1                            # Ubuntu: DENY
```

**No behavioral pam_group check** here — this profile grants no group
membership, so there is no fresh-login false-negative to worry about (that
caveat is a webserver concern). The database-specific behavioral check is
that a profile-scoped `reload`/`restart` leaves the cluster serving:
`psql -c 'SELECT 1'` after the restart.

## 6. Flip

Remove the team from `<hostname>-app_full` (restricted grants are already live
via nesting), `loginctl terminate-user <user>` per user, `sss_cache -E`.
Confirm on a fresh login: `id` shows no `wheel`/`sudo` and **not** `postgres`;
`sudo -l` shows only the profile. Full mechanics:
[the flip](../../concepts/lifecycle.md).

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time; or full
revoke with the same command + `--tags cleanup`. Cleanup removes the sudoers
file and the ACLs (access + default) on the cluster config dir
(`/etc/postgresql/16/main` on 24.04, `/etc/postgresql/18/main` on 26.04) and
`/var/log/postgresql`. Two deliberate exceptions
([revocation](../../concepts/lifecycle.md#revocation)): **parent traverse
ACLs remain** (`/etc/postgresql`, `/etc/postgresql/16` or `/18` — shared
across profiles) and **ownership is never reverted** — the data-dir and
config-tree ownership assertions stay as applied.

## 8. Drift and patching

`rpm -V postgresql-server` (al2023: `rpm -V postgresql17-server`) /
`dpkg --verify postgresql-16` (26.04: `postgresql-18`) will **not** flag
this profile's changes: there is no setgid content dir (unlike a web server),
and ACLs are invisible to package verification. The ownership entries only
re-assert vendor state, so they produce no drift. Package updates replace
files and shed file ACLs `[app-knowledge]`; a minor-version update that
rewrites `/etc/postgresql/16/main/postgresql.conf` (or `18/main` on 26.04)
drops the ACL on that file
— re-run playbook 5 after patching (idempotent), then `getfacl` to confirm.
On authselect-managed EL hosts, `authselect apply-changes` can rewrite
`/etc/pam.d/sshd`; it does not affect this profile (no pam_group line), but it
would drop a §3 opt-in mapping if one was applied — re-run the role or wire a
custom authselect profile.

## 9. TLS: key ownership and rotation

PostgreSQL is a named exception in
[TLS under the access model](../../concepts/tls-ssl.md#per-application-class-exceptions):
**key rotation is always ops**, on both families, and there is no clean
cert-admin opt-in because the key is never in a grantable location.

- **EL:** the server reads `server.crt`/`server.key` from inside the `0700`
  data dir (`/var/lib/pgsql/data/`), and requires `server.key` mode `0600`.
  Making rotation self-service would mean granting the data dir, which the
  model refuses. Ops places/rotates the key as `postgres`; the team runs the
  granted `reload`.
- **Ubuntu:** TLS is **on by default** against the snakeoil pair; the key
  stays `root:ssl-cert 0640` in `/etc/ssl/private`, and the service reads it
  because the installer added `postgres` to `ssl-cert` (captured in the
  footprint's membership changes, both releases). The team is **not** in
  `ssl-cert` and the
  directory is in no profile. On 26.04 the snakeoil pair itself is minted by
  the new `ssl-cert.service` root oneshot (only when the key is absent —
  `ConditionPathExists` guard); that unit was dropped from the profile in
  review (§2), so re-minting a deleted snakeoil key is also ops. Ops rotates
  the file in `/etc/ssl/private` (or
  repoints `ssl_key_file`); the team runs the granted `reload`.

The boundary is the same either way: platform places key material, the team
picks it up with their granted verb.

## 10. Logs

`journalctl` grants are per-unit scoping — never substitute `systemd-journal`
or `adm` group membership (host-global journal read). On Ubuntu the useful
unit is the cluster: `sudo journalctl -e -u postgresql@16-main` (26.04:
`postgresql@18-main`).

PostgreSQL is **the** self-rotating app (see
[self-rotating applications](../../concepts/logging.md#self-rotating-applications)):
when the logging collector rotates, file mode comes from `log_file_mode`,
default `0600` `[needs-runtime-confirmation]`, whose group-class bits become
the ACL mask and cap the read grant to nothing. On Ubuntu, where
`/etc/logrotate.d/postgresql-common` handles rotation, the same rule lives in
that fragment's `create` mode. Pre-flip test (Ubuntu):

```bash
logrotate -f /etc/logrotate.d/postgresql-common
getfacl /var/log/postgresql/postgresql-16-main.log   # team group, no #effective:---
# 26.04: same test against postgresql-18-main.log
```

On EL — al2023 included — there is no `/var/log/postgresql` to grant: with
the default config the
server logs to the journal, and a hand-enabled collector writes into the 0700
data dir (unreadable to the team by design). Log-read there is the
`journalctl` grant.

## 11. Known risks (from `risks[]`)

| Risk (severity) | Distro | Decision | Detail |
| --- | --- | --- | --- |
| `pam_modified`: `/etc/pam.d/postgresql` (**high**) | alma9, alma10, al2023 | **Accept** | The postgresql-server package (al2023: postgresql17-server — same file) ships this PAM **service** file for the optional `pam` authentication method in `pg_hba.conf`. It is inert unless a `pg_hba.conf` line selects `pam`, and it is **not** the `pam_group` access mechanism (which this profile does not use). Record it in the golden-baseline accept-list; no fix needed. If the `pam` HBA method is never used, leaving the file is harmless. |
| `service_runs_as_root` × 5 (**medium**) | ubuntu 24.04 | **Accept** | `postgresql.service` (a `/bin/true` oneshot umbrella) and `postgresql@.service` carry no `User=`. Debian's design: `pg_ctlcluster` starts as root and drops privileges — the actual `postmaster` runs as `postgres` `[app-knowledge]`. Contrast EL, whose unit sets `User=postgres` directly. Not a defect; no action. |
| `service_runs_as_root` × 8 (**medium**) | ubuntu 26.04 | **Accept** | 24.04's five, plus `ssl-cert.service` ×3 (unit under `/lib` + `/usr/lib` + the enablement symlink). The ssl-cert oneshot legitimately runs as root: it writes `root:ssl-cert 0640` key material into `/etc/ssl/private`, guarded by `ConditionPathExists` so it only acts when the snakeoil key is absent. Dropped from the profile in review (§2); no action. |

No other high/critical `risks[]` entries. On all three EL-family cells the
`postgres` account has a
real login shell (`/bin/bash`, login not disabled) so ops can `sudo -u
postgres -i` to run `initdb`/`psql` — expected for the DB admin path, and
outside the restricted team's grant.

**al2023 MAC evidence note.** The AlmaLinux golden images verify with
SELinux **enforcing**; Amazon Linux 2023 ships SELinux **permissive** by
default `[app-knowledge]` — policy is loaded and denials are logged, but
nothing is blocked, so on al2023 the 0700 data-dir DAC boundary (and this
profile's scoped sudoers) is doing all of the enforcement work that Alma
hosts back with SELinux. Check `getenforce` at apply time and record it;
flipping al2023 to enforcing is a platform decision outside this profile,
but the profile needs no change if you do — the labels the relabel step in
§13 preserves are the same ones enforcing mode consults.

## 12. Storage and growth

Doctrine — who may provision, the mount trap, the separate-volume rule —
lives in [storage, disks, and growth](../../concepts/storage.md). This
section is the PostgreSQL instantiation only.

### Install-time floor

Summed added-file bytes from the same footprints as §1. Treat these as a
**floor, not a forecast**: they record what the installer wrote, so they
answer "will it fit," never "how fast will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Install floor (all added files) | **95.4 MB** / 344 files | **103.6 MB** / 347 files | **359.4 MB** / 3954 files | **129.0 MB** / 4043 files | **101.1 MB** / 348 files |
| Largest category | `library` 71.2 MB | `library` 76.5 MB | `library` 318.5 MB | `library` 87.7 MB | `library` 72.0 MB |
| Data dir inside that total | none — `dnf` never ran `initdb` | none — same | **38.3 MB** at `/var/lib/postgresql/16/main` (`base/` 21.7 MB, `pg_wal/` 16.0 MB) | **38.8 MB** at `/var/lib/postgresql/18/main` (`base/` 22.2 MB, `pg_wal/` 16.0 MB) | none — same as alma9 |
| Package payload, data dir excluded | 95.4 MB | 103.6 MB | 321.2 MB | 90.2 MB | 101.1 MB |

**The five totals are not like-for-like.** The Ubuntu cells already contain
an empty cluster because apt ran `initdb` at install (§1); the EL-family
captures contain no cluster at all. And every floor is a **delta against
that golden image's clean baseline**, not an absolute package cost — that is
why 26.04's payload (90.2 MB) is a quarter of 24.04's (321.2 MB) for the
same meta-package: the newer image's baseline already carries most of the
library weight the 24.04 install had to pull in. Compare cells to budget a
host, never to compare packages. Size EL-family hosts as package payload
**plus** a first
cluster of the same order as Ubuntu's ~38 MB — 16 MB of which is one WAL
segment allocated before a single row exists.
`[needs-runtime-confirmation]`

### What grows after install

| Component | Where | Bounded? | Driver |
| --- | --- | --- | --- |
| Dataset | data dir, `base/` | **No** | tables and indexes; bloat whenever autovacuum falls behind `[app-knowledge]` |
| WAL | data dir, `pg_wal/` | **No** | see below — the fastest and least visible way to fill this volume |
| Backups / dumps | EL family `/var/lib/pgsql/backups` (ships empty in the footprint, al2023 included); Ubuntu wherever the postgresql-common timers point `[needs-runtime-confirmation]` | **No** | each full copy needs headroom ≈ the dataset |
| Log files | Ubuntu `/var/log/postgresql` (both releases); **N/A on alma9/alma10/al2023** — no log dir ships | Ubuntu: yes, via the shipped fragment | verbose `log_statement` / `log_min_duration_statement` |
| journald | all five | **Yes** — `SystemMaxUse` default | only unbounded if an operator raised the cap |

**WAL deserves its own check.** Log rotation never touches it, and the
classic cause is the one
[the doctrine names](../../concepts/storage.md#what-actually-grows): a
replication slot nobody consumes pins segments forever. A failing
`archive_command` does the same. `[app-knowledge]` Look before it bites:

```sql
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS pinned
FROM pg_replication_slots ORDER BY 3 DESC;
```

Then `SELECT pg_drop_replication_slot('<name>');`, or set
`max_slot_wal_keep_size` so a stalled consumer loses its slot instead of the
host losing its disk. `[app-knowledge]` Both are superuser work — neither is
in the team's grant, so both arrive as ops requests.

### Separate volume: yes — and mount it at the data path

PostgreSQL is the case the doctrine calls out by name: unbounded growth
whose failure mode is "fills the root filesystem". Give it its own volume,
mounted at the app's existing data path
([separate volumes](../../concepts/storage.md#separate-volumes-when-and-where)).

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Mount point | `/var/lib/pgsql` | `/var/lib/pgsql` | `/var/lib/postgresql/16/main` | `/var/lib/postgresql/18/main` | `/var/lib/pgsql` |
| Required state on the new fs root | `postgres:postgres 0700` | same | `postgres:postgres 0700` | same | same |
| Restored by playbook 5? | **Yes** — the profile asserts ownership on exactly this path | **Yes** — same | **No** — the assertion sits on the `0755` parent `/var/lib/postgresql`; set the mount root by hand | **No** — same | **Yes** — same assertion as alma9 |
| Else on that volume | `data/` **and** `backups/` — repoint backups elsewhere if surviving volume loss is the point | same | the cluster only | the cluster only | same as alma9 |
| SELinux relabel | required (enforcing) | required (enforcing) | N/A on ubuntu — AppArmor, no `fcontext` step | N/A on ubuntu — same | required — label even though al2023 defaults to permissive (§11 note): `restorecon` costs nothing now and an enforcing flip later finds the contexts in place |

EL-family gotcha (al2023 included): `/var/lib/pgsql` is also `postgres`'s
home, and mounting over it
hides the shipped `.bash_profile` (which sets `PGDATA` `[app-knowledge]`),
breaking the `sudo -u postgres -i` admin path from §11. Copy it onto the new
volume, or mount at `/var/lib/pgsql/data` and set ownership by hand there.

### Ordering

Follow [the ops ordering](../../concepts/storage.md#separate-volumes-when-and-where)
— attach, `mkfs`, `fstab` by UUID, mount at the data path, restore
ownership/mode and the SELinux label, **re-apply, then `getfacl`**. Two
PostgreSQL specifics on top of it:

- **Stop the cluster and copy the data across first.** A mount over a
  populated data dir hides it; the server then finds no `PG_VERSION` and
  refuses to start rather than serving an empty database.
- **Re-apply even though no ACL lives on the data path.** This profile never
  grants the data dir, so there is no team ACL there to lose — what playbook
  5 restores is the ownership assertion, and only on the EL family (see the
  table). The
  ACL'd paths are Ubuntu's `/etc/postgresql/16/main` (26.04: `18/main`) and
  `/var/log/postgresql`; a separate **log** volume is the realistic case
  where [the mount trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it)
  actually costs the team its access.

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/postgresql/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
getfacl /var/log/postgresql          # Ubuntu: team entry back, no #effective:---
stat -c '%U:%G %a' /var/lib/pgsql    # EL: postgres:postgres 700
```

### Log retention

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Rotation fragment shipped | **none** in the footprint | **none** | `/etc/logrotate.d/postgresql-common` root:root 0644 | same fragment, same owner:mode | **none** |
| Default sink | journald (server logs to stderr) | same | files in `/var/log/postgresql`, plus journald | same | same as alma9 |
| Bounded out of the box | yes — journald `SystemMaxUse` | yes — same | yes — by the shipped fragment | yes — same | yes — journald |
| Team can change retention | N/A on alma9 — nothing to edit; journald limits are host-global | N/A on alma10 — same | no — the fragment is root:root, outside the grant | no — same | N/A on al2023 — same as alma9 |

Enable the logging collector on EL and the files land inside the 0700 data
dir with **no logrotate fragment governing them** — retention then comes
only from `log_rotation_age` / `log_rotation_size` /
`log_truncate_on_rotation`, set by ops via `ALTER SYSTEM`. `[app-knowledge]`
Either way, retention changes are an ops request; whether the team can still
*read* a rotated file is the mask caveat in §10.

## 13. Disk layout & data volume

Where the database lives on disk, and how to give it its own disk on the
holy-qcow KVM substrate this matrix is captured and verified on (the guest
side applies to any libvirt host). Doctrine — who provisions, the mount
trap, the six-step ordering — is
[storage, disks, and growth](../../concepts/storage.md); per-cell mount
points and sizes are §12. This section adds only what those don't carry:
the substrate mechanics and the per-family first-mount sequence.

### The data directory: own volume, never granted

The data directory — `/var/lib/pgsql` on the EL family (alma9, alma10,
al2023), `/var/lib/postgresql` with the cluster at `16/main` / `18/main` on
Ubuntu — is this app's unbounded-growth path (§12) and belongs on its
**own volume**, so a full database degrades the database and not the root
filesystem. It is also the path this library never hands out: it appears in
**no grant list in any of the five reviewed profiles** — not
`folders_modify`, not `folders_read` — only in `ownership` assertions,
which grant nothing. That is
[the database exception](../../concepts/access-model.md): a filesystem path
into the data dir bypasses every SQL `GRANT` the server enforces, so the
DBA surface is the **database protocol** — `psql`, `ALTER SYSTEM`, SQL
roles and grants — plus the profile's `systemctl`/`journalctl` verbs. A
data volume changes where the closed directory lives, never who can enter
it.

### Attaching a data disk to a holy-qcow VM

Guests come from holy-qcow golden images via its `tofu/modules/vm` module,
which today provisions the **root disk only** (`disk_gb`) — there is no
data-disk input. Attach a second disk post-deploy on the KVM host
(`ansible@192.168.1.238`):

```bash
# on the KVM host — create the volume in the vmdisks pool, then attach it
virsh vol-create-as vmdisks <name>-data.qcow2 <size>G --format qcow2
virsh attach-disk <domain> \
  --source "$(virsh vol-path <name>-data.qcow2 --pool vmdisks)" \
  --target vdb --persistent --subdriver qcow2
```

`--persistent` writes the disk into the domain XML so it survives reboot;
the guest sees `/dev/vdb`. No AppArmor work is needed: the host's
golden-image accommodation already covers the vmdisks pool path (holy-qcow
grants the pool tree because libvirt's virt-aa-helper cannot resolve its
pool-backed disks). A `data_disk_gb` variable on the vm module is the clean
upstream extension — **not scheduled**; until it lands, the two `virsh`
commands above are the procedure.

### Guest-side: filesystem, first mount, growth

Two starting states (§1): on the EL family `initdb` has not run, so mount
**before the first service start** and the cluster is born on the new
volume — nothing to migrate; on Ubuntu apt initialized and started the
cluster at install, so it is stop → copy → mount. Both end the same way:
`fstab` by UUID, then the §12 ordering's **re-apply playbook 5 +
`getfacl`** — [the mount trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it)
applies to any mount under a granted path even though the data dir itself
carries no ACL.

**EL family (alma9 / alma10 / al2023) — fresh cluster:**

```bash
mkfs.xfs /dev/vdb
mount /dev/vdb /mnt && cp -a /var/lib/pgsql/. /mnt/ && umount /mnt   # keep the 0700 skeleton + .bash_profile (§12 gotcha)
echo "UUID=$(blkid -s UUID -o value /dev/vdb) /var/lib/pgsql xfs defaults,nofail 0 2" >> /etc/fstab
mount /var/lib/pgsql
restorecon -R /var/lib/pgsql     # SELinux contexts follow the move; skip it and an enforcing host strands the daemon
postgresql-setup --initdb
systemctl enable --now postgresql
```

Run the `restorecon` on al2023 too, permissive default notwithstanding
(§11 note): labeling now costs nothing and an enforcing flip later finds
the contexts already correct.

**Ubuntu — populated cluster (24.04 shown; substitute `18` on 26.04):**

```bash
systemctl stop postgresql@16-main
mkfs.ext4 /dev/vdb
mount /dev/vdb /mnt && cp -a /var/lib/postgresql/16/main/. /mnt/ && umount /mnt
echo "UUID=$(blkid -s UUID -o value /dev/vdb) /var/lib/postgresql/16/main ext4 defaults,nofail 0 2" >> /etc/fstab
mount /var/lib/postgresql/16/main
chown postgres:postgres /var/lib/postgresql/16/main && chmod 0700 /var/lib/postgresql/16/main
systemctl start postgresql@16-main
```

No relabel step — AppArmor (§12 table). The copy-before-mount matters: a
mount over the populated cluster hides it, and the server then finds no
`PG_VERSION` and refuses to start rather than serving an empty database
(§12).

**Growth.** In-place growth of the data volume (disk → partition → LVM →
filesystem) is automated by the
[mcowser_p.fleet_medic](https://github.com/mcowser-p/fleet-medic)
collection's `disk_expand` role — threshold-driven, capped, and
cleanup-first; growing in place never remounts, so the profile's ACL
grants survive
([growing existing volumes](../../concepts/storage.md#growing-existing-volumes)).
On this substrate the disk itself grows on the KVM host first —
`virsh vol-resize <name>-data.qcow2 <new-size>G --pool vmdisks` — then the
guest-side chain (fleet_medic or the manual steps) takes it from there.
Attaching a **second** new volume instead is the six-step procedure above,
mount-trap rule included.
