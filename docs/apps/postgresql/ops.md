# PostgreSQL — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/postgresql/{almalinux-9,almalinux-10,ubuntu-24.04}-access.yml`
([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/almalinux-10-access.yml),
[ubuntu](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/ubuntu-24.04-access.yml))
with their untouched `-raw.yml` siblings. Role choice:
[the postgresql role evaluation](../../role-evals/postgresql.md). Lifecycle
mechanics: [concepts/lifecycle.md](../../concepts/lifecycle.md).

PostgreSQL is a **database**: the profile is config-scoped, grants **no**
`pam_group`, and **never** grants the data directory. The reasoning is in
[§3](#3-access-model-for-this-app-class) and
[the database exception](../../concepts/access-model.md).

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-postgresql.json` (schema 1.0, captured
2026-08-09, cairn 0.10.0 feature branch):

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| files added / modified | 344 / 137 | 347 / 151 | 3954 / 46 |
| systemd units | 4 (`postgresql.service` + `postgresql@.service`, usr-merge ×2) | 4 (same) | 19 (umbrella + cluster template + backup automation) |
| Units the team operates | `postgresql.service` | `postgresql.service` | `postgresql.service` (umbrella) + `postgresql@16-main` (cluster instance) |
| Dependency/feature units | none | none | `pg_basebackup@`, `pg_compresswal@`, `pg_dump@`, `pg_receivewal@` (`.service`/`.timer`) — postgresql-common backup automation, not started by default |
| Accounts created | `postgres` uid 26 gid 26, home `/var/lib/pgsql`, shell `/bin/bash` | same | `postgres` uid 112 gid 115, home `/var/lib/postgresql`, shell `/bin/bash`, **added to `ssl-cert`** (gid 113) |
| Config (captured owner:mode) | only `/etc/postgresql-setup` root:root 0755 (upgrade tooling — the DB config does not exist until `initdb`) | same | `/etc/postgresql/16/main` postgres:postgres 0755; `postgresql.conf` 0644; `pg_hba.conf` 0640; `/etc/postgresql-common` root:root 0755 |
| Data dir (captured) | `/var/lib/pgsql` (+`/data`, `/backups`) **drwx------ postgres:postgres 0700** | same | `/var/lib/postgresql/16/main` **drwx------ postgres:postgres 0700** (parent `/var/lib/postgresql` 0755) |
| Log dir | none (logs to journal; collector, if enabled, writes into the 0700 data dir) | none | `/var/log/postgresql` (+ `/etc/logrotate.d/postgresql-common` root:root 0644) |
| Vendor sudoers shipped | none (`privilege.sudoers_files` empty) | none | none |
| PAM touched | **`/etc/pam.d/postgresql`** (see §11) | same | none |

Ubuntu's footprint is an order of magnitude larger because the `postgresql`
meta-package pulls postgresql-16 and **apt ran `initdb` + auto-started the
cluster** — so the live config tree and the populated data dir are in the
capture (995 `state_dir` entries). EL captures have no data dir at all: `dnf`
does not start the service and `postgresql-setup --initdb` had not run. Raw
profiles are therefore not line-comparable across the families.

## 2. Raw → reviewed: the decisions

| Change | Distro | Tag | Why |
| --- | --- | --- | --- |
| Drop all `files_modify` (EL: 4 unit paths; Ubuntu: 19) | all | REVIEW-DROP | Vendor units incl. the umbrella, the cluster template, Ubuntu's backup automation and the enablement symlink. A unit-file write ACL is root-equivalent for that unit. Read-only-units profile. |
| Drop `pam_group` + `local_groups: [postgres]` | EL | REVIEW-DROP | Database class: `postgres` is the data-owning group. See §3. (Ubuntu's raw had no pam_group to drop.) |
| Drop `folders_modify: /etc/postgresql-setup` | EL | REVIEW-DROP | root:root postgresql-setup **upgrade** tooling, not team config. |
| Drop `folders_modify: /var/lib/pgsql` | EL | REVIEW-DROP | The 0700 data dir; config lives inside it. **Never grant the data dir.** |
| Narrow `folders_modify: /etc/postgresql` → `/etc/postgresql/16/main` | Ubuntu | REVIEW (narrow) | Config split out of the data dir; the write ACL (+ default ACL for new `conf.d` drop-ins) reaches the cluster config without touching `/var/lib/postgresql/16/main`. |
| Drop `folders_modify: /etc/postgresql-common` | Ubuntu | REVIEW-DROP | root:root postgresql-common package tooling (upgrade hooks, logrotate, pg_ctl defaults). |
| Drop `folders_modify: /var/lib/postgresql` | Ubuntu | REVIEW-DROP | Data-dir root (contains the 0700 16/main data dir). Never grant the data dir. |
| Add `postgresql@16-main` to `services` | Ubuntu | REVIEW-ADD | The umbrella `postgresql.service` is a `/bin/true` oneshot; `postgresql@16-main` is the real cluster unit (evidence: the `postgresql@.service` template + the 16/main config and data dir). Lets the team act on just their cluster. |
| Add `folders_read: /var/log/postgresql` | Ubuntu | REVIEW-ADD | `/var/log` is excluded from footprints by default; Debian's cluster logs there. |
| Keep `ownership` entries as captured | all | as captured | Enforce install-time ownership of the data dir (EL) and the config-tree/data-root (Ubuntu). Assertions, not ACLs — they grant nothing and keep drift visible. |

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
  `/etc/postgresql/16/main`). On EL there is no on-disk config to ACL until
  `initdb`, and it then lives inside the 0700 data dir — so EL config changes
  are `ALTER SYSTEM` (SQL) or an ops edit as `postgres`.
- **Logs** — read **ACL** (Ubuntu: `/var/log/postgresql`); journal via the
  scoped `journalctl` grants on both.
- **Never** the data dir (`/var/lib/pgsql/data`, `/var/lib/postgresql/16/main`).

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
  confirm it lists `postgresql` (Ubuntu also `postgresql@16-main`) and the
  `journalctl -u` spellings, and **no** `files_modify` entries.
- **No** `group.conf` line and **no** `local_groups` — this is a database
  profile; if you see a pam_group mapping, someone used the §3 opt-in.
- `getfacl /etc/postgresql/16/main` and `getfacl /var/log/postgresql`
  (Ubuntu) — team group present with the default ACL. On EL there are no ACL
  targets; the profile is sudoers + the data-dir ownership assertion.

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Verified with `scripts/verify-profile.sh postgresql <distro>` (init
container, real playbook apply, probes, real `--tags cleanup`). On a live
host, as a user holding **only** app-restricted:

```bash
sudo -l -U <pilot>                              # exactly the scoped grants
sudo systemctl reload postgresql                # allow (Ubuntu: @16-main)
sudo journalctl -e -u postgresql                # allow (granted spelling)
sudo systemctl restart sshd                     # DENY
echo x | sudo tee /usr/lib/systemd/system/postgresql.service   # DENY
# Ubuntu — config write via ACL (no fresh login needed; ACLs are immediate):
touch /etc/postgresql/16/main/conf.d/.probe && rm $_            # allow
tail -n1 /var/log/postgresql/postgresql-16-main.log            # allow (ACL)
# both — the data dir stays closed:
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
file and the ACLs (access + default) on `/etc/postgresql/16/main` and
`/var/log/postgresql`. Two deliberate exceptions
([revocation](../../concepts/lifecycle.md#revocation)): **parent traverse
ACLs remain** (`/etc/postgresql`, `/etc/postgresql/16` — shared across
profiles) and **ownership is never reverted** — the data-dir and config-tree
ownership assertions stay as applied.

## 8. Drift and patching

`rpm -V postgresql-server` / `dpkg --verify postgresql-16` will **not** flag
this profile's changes: there is no setgid content dir (unlike a web server),
and ACLs are invisible to package verification. The ownership entries only
re-assert vendor state, so they produce no drift. Package updates replace
files and shed file ACLs `[app-knowledge]`; a minor-version update that
rewrites `/etc/postgresql/16/main/postgresql.conf` drops the ACL on that file
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
  footprint's membership changes). The team is **not** in `ssl-cert` and the
  directory is in no profile. Ops rotates the file in `/etc/ssl/private` (or
  repoints `ssl_key_file`); the team runs the granted `reload`.

The boundary is the same either way: platform places key material, the team
picks it up with their granted verb.

## 10. Logs

`journalctl` grants are per-unit scoping — never substitute `systemd-journal`
or `adm` group membership (host-global journal read). On Ubuntu the useful
unit is the cluster: `sudo journalctl -e -u postgresql@16-main`.

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
```

On EL there is no `/var/log/postgresql` to grant: with the default config the
server logs to the journal, and a hand-enabled collector writes into the 0700
data dir (unreadable to the team by design). Log-read there is the
`journalctl` grant.

## 11. Known risks (from `risks[]`)

| Risk (severity) | Distro | Decision | Detail |
| --- | --- | --- | --- |
| `pam_modified`: `/etc/pam.d/postgresql` (**high**) | alma9, alma10 | **Accept** | The postgresql-server package ships this PAM **service** file for the optional `pam` authentication method in `pg_hba.conf`. It is inert unless a `pg_hba.conf` line selects `pam`, and it is **not** the `pam_group` access mechanism (which this profile does not use). Record it in the golden-baseline accept-list; no fix needed. If the `pam` HBA method is never used, leaving the file is harmless. |
| `service_runs_as_root` × 5 (**medium**) | ubuntu | **Accept** | `postgresql.service` (a `/bin/true` oneshot umbrella) and `postgresql@.service` carry no `User=`. Debian's design: `pg_ctlcluster` starts as root and drops privileges — the actual `postmaster` runs as `postgres` `[app-knowledge]`. Contrast EL, whose unit sets `User=postgres` directly. Not a defect; no action. |

No other high/critical `risks[]` entries. The EL `postgres` account has a
real login shell (`/bin/bash`, login not disabled) so ops can `sudo -u
postgres -i` to run `initdb`/`psql` — expected for the DB admin path, and
outside the restricted team's grant.

## 12. Storage and growth

Doctrine — who may provision, the mount trap, the separate-volume rule —
lives in [storage, disks, and growth](../../concepts/storage.md). This
section is the PostgreSQL instantiation only.

### Install-time floor

Summed added-file bytes from the same footprints as §1. Treat these as a
**floor, not a forecast**: they record what the installer wrote, so they
answer "will it fit," never "how fast will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Install floor (all added files) | **95.4 MB** / 344 files | **103.6 MB** / 347 files | **360.7 MB** / 3954 files |
| Largest category | `library` 71.2 MB | `library` 76.5 MB | `library` 319.5 MB |
| Data dir inside that total | none — `dnf` never ran `initdb` | none — same | **38.4 MB** at `/var/lib/postgresql/16/main` (`base/` 21.7 MB, `pg_wal/` 16.0 MB) |
| Package payload, data dir excluded | 95.4 MB | 103.6 MB | 322.3 MB |

**The three totals are not like-for-like.** Ubuntu's already contains an
empty cluster because apt ran `initdb` at install (§1); the EL captures
contain no cluster at all. Size EL hosts as package payload **plus** a first
cluster of the same order as Ubuntu's 38.4 MB — 16 MB of which is one WAL
segment allocated before a single row exists.
`[needs-runtime-confirmation]`

### What grows after install

| Component | Where | Bounded? | Driver |
| --- | --- | --- | --- |
| Dataset | data dir, `base/` | **No** | tables and indexes; bloat whenever autovacuum falls behind `[app-knowledge]` |
| WAL | data dir, `pg_wal/` | **No** | see below — the fastest and least visible way to fill this volume |
| Backups / dumps | EL `/var/lib/pgsql/backups` (ships empty in the footprint); Ubuntu wherever the postgresql-common timers point `[needs-runtime-confirmation]` | **No** | each full copy needs headroom ≈ the dataset |
| Log files | Ubuntu `/var/log/postgresql`; **N/A on alma9/alma10** — no log dir ships | Ubuntu: yes, via the shipped fragment | verbose `log_statement` / `log_min_duration_statement` |
| journald | all three | **Yes** — `SystemMaxUse` default | only unbounded if an operator raised the cap |

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

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Mount point | `/var/lib/pgsql` | `/var/lib/pgsql` | `/var/lib/postgresql/16/main` |
| Required state on the new fs root | `postgres:postgres 0700` | same | `postgres:postgres 0700` |
| Restored by playbook 5? | **Yes** — the profile asserts ownership on exactly this path | **Yes** — same | **No** — the assertion sits on the `0755` parent `/var/lib/postgresql`; set the mount root by hand |
| Else on that volume | `data/` **and** `backups/` — repoint backups elsewhere if surviving volume loss is the point | same | the cluster only |
| SELinux relabel | required (enforcing) | required (enforcing) | N/A on ubuntu — AppArmor, no `fcontext` step |

EL gotcha: `/var/lib/pgsql` is also `postgres`'s home, and mounting over it
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
  5 restores is the ownership assertion, and only on EL (see the table). The
  ACL'd paths are Ubuntu's `/etc/postgresql/16/main` and
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

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Rotation fragment shipped | **none** in the footprint | **none** | `/etc/logrotate.d/postgresql-common` root:root 0644 |
| Default sink | journald (server logs to stderr) | same | files in `/var/log/postgresql`, plus journald |
| Bounded out of the box | yes — journald `SystemMaxUse` | yes — same | yes — by the shipped fragment |
| Team can change retention | N/A on alma9 — nothing to edit; journald limits are host-global | N/A on alma10 — same | no — the fragment is root:root, outside the grant |

Enable the logging collector on EL and the files land inside the 0700 data
dir with **no logrotate fragment governing them** — retention then comes
only from `log_rotation_age` / `log_rotation_size` /
`log_truncate_on_rotation`, set by ops via `ALTER SYSTEM`. `[app-knowledge]`
Either way, retention changes are an ops request; whether the team can still
*read* a rotated file is the mask caveat in §10.
