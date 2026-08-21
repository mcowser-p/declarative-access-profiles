# redis — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/redis/{almalinux-9,almalinux-10,ubuntu-24.04}-access.yml` with their
untouched `-raw.yml` siblings. Role evaluation:
[docs/role-evals/redis.md](../../role-evals/redis.md). Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

AlmaLinux 10 ships **valkey**, not redis (redis relicensed off OSI-approved
terms; EL10 replaced it with the valkey fork). The row keeps the `redis` slug;
alma10's units, account, and paths are all `valkey`.

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-redis.json` (schema 1.0,
`footprint_type: install_time`, captured 2026-08-09 on EC2 AMIs,
cairn 0.10.0 feature branch):

| | alma9 (redis) | alma10 (valkey) | ubuntu 24.04 (redis-server) |
| --- | --- | --- | --- |
| Services shipped | `redis.service` + `redis-sentinel.service` | `valkey.service` + `valkey-sentinel.service` | `redis-server.service` + `redis.service` alias + `redis-server@.service` template |
| Account created (uid/gid, shell) | `redis` 992/992, `/sbin/nologin`, home `/var/lib/redis` | `valkey` 991/991, `/sbin/nologin`, home `/dev/null` | `redis` 115/117, `/usr/sbin/nologin`, home `/var/lib/redis` |
| Config dir | `/etc/redis` `redis:root 0750`; `redis.conf`+`sentinel.conf` `redis:root 0640` | `/etc/valkey` `valkey:root 0750`; `valkey.conf`+`sentinel.conf` `valkey:root 0640` | `/etc/redis` **`redis:redis 2770`**; `redis.conf` `redis:redis 0640` |
| Data dir | `/var/lib/redis` `redis:redis 0750` | `/var/lib/valkey` `valkey:valkey 0750` | `/var/lib/redis` `redis:redis 0750` |
| Unit hardening | none declared (logs to journal) | none declared (logs to journal) | heavy: `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`, `ReadWritePaths=/var/lib/redis /var/log/redis /var/run/redis` |
| Log destination | journal (no `logfile`) | journal (no `logfile`) | **file** `/var/log/redis/` (unit ReadWritePath) + journal |
| Env file | none | `-/etc/sysconfig/valkey` (optional, not created) | `/etc/default/redis-server` `root:root 0644` |
| logrotate fragment | `/etc/logrotate.d/redis` | `/etc/logrotate.d/valkey` | `/etc/logrotate.d/redis-server` |
| `group_access` (install-created group) | `redis` group: **read** `/var/lib/redis` | `valkey` group: **read** `/var/lib/valkey` | `redis` group: **write** `/etc/redis`, **read** `/etc/redis/redis.conf` + `/var/lib/redis` |
| Vendor sudoers shipped | none (`privilege.sudoers_files: []`) | none | none |
| `risks[]` | 0 | 0 | 0 |

The `group_access` row is the load-bearing evidence for the pam_group decision:
the service group can **read the data dir** on every distro (and additionally
**write config** on Debian). That is exactly why this profile does not put the
team in that group — see §2 and §3.

Ubuntu's footprint includes first-start side effects (apt auto-starts services);
EL captures do not. Raw profiles are therefore not line-comparable across
distros.

## 2. Raw → reviewed: the decisions

| Change | Tag | Why |
| --- | --- | --- |
| Drop Sentinel service (`redis-sentinel`/`valkey-sentinel`) | REVIEW-DROP | Optional HA failover-monitor daemon, shipped by the package but disabled by default and unused on a single-node cache. "Would the team ever restart it?" — not here. Re-add on request (its `sentinel.conf` is already inside the config ACL). |
| Drop the `redis` alias service (Ubuntu) | REVIEW-DROP | `redis.service` is a vendor `Install.Alias` symlink for `redis-server.service`; grant the canonical unit only. |
| Drop all `files_modify` (vendor units, 4/4/6 entries) | REVIEW-DROP | All vendor unit files + apt's enablement/alias symlinks; a unit-file write ACL is root-equivalent for that unit. Read-only-units profile. |
| Drop `/etc/systemd/system/{redis,redis-sentinel}.service.d` (alma9) | REVIEW-DROP | Vendor unit drop-in dirs (`limit.conf`: `LimitNOFILE=10240`) — same root-equivalence with granted `daemon-reload`+`restart`. |
| Drop `pam_group` + `local_groups` (`redis`/`valkey`) | REVIEW-DROP | Cache class, DB-style data exposure: the service group **owns the data dir** (`group_access` read), so membership grants read of `dump.rdb`/`appendonly.aof` beneath every redis AUTH/ACL. Config write is granted by ACL instead. Group option stays available at apply time (§3). |
| Drop `/var/lib/redis`/`/var/lib/valkey` from `folders_modify` | REVIEW-DROP | The data dir. Cache/DB rule: never grant the data dir; the service group owns it and filesystem write corrupts persisted state. Install-time state kept via `ownership`. |
| Add `/etc/redis` to `folders_modify` (Ubuntu) | REVIEW-ADD | The raw omitted it — the exporter saw `/etc/redis` group-writable (`2770`) and routed config write through pam_group. We drop pam_group (data exposure), so config write returns as an ACL on `/etc/redis`. |
| Add `/var/log/<app>` read | REVIEW-ADD | `/var/log` is excluded from footprints by default. Populated by default on Ubuntu (file logging); on EL only if `logfile` is set — logs otherwise go to the journal (`[needs-runtime-confirmation]`). |
| Change `profile_name` `valkey` → `redis` (alma10) | REVIEW-CHANGE | The reviewed profile must satisfy the `profile_name == app-dir` contract check (`tools/check_profiles.py`). Cosmetic: names the rendered sudoers file / group.conf label, not any unit or path. |
| Keep `ownership` (`/etc/redis`+`/var/lib/redis`; Ubuntu `/var/lib/redis`) | as captured | Enforces install-time owner/mode; drift stays visible. Config on EL stays `<user>:root 0750` — the team writes via the ACL, the service account is not in the config group. |

## 3. Access model for this app class

**cache** — config-scoped, like a database with the pam_group option off:

- **scoped service control** (sudoers) on the one primary unit;
- **config write ACL** on `/etc/redis` (`/etc/valkey`) — the team edits config,
  the service account does not gain config write;
- **log read ACL** on `/var/log/<app>` (+ journal via `journalctl -u`);
- **NO pam_group** and **NEVER the data dir** — the [access model's database
  exception](../../concepts/access-model.md) applies: the service group owns the
  raw data, and filesystem access bypasses every redis GRANT/AUTH. Cache
  administration happens through `redis-cli`, not the filesystem.

The group option remains available for teams that knowingly accept data-dir
exposure (e.g. filesystem backups of `dump.rdb`), enabled at apply time:

```bash
ansible-playbook ... -e @profiles/redis/<distro>-access.yml \
  -e enable_pam_group=true -e '{"declarative_access_local_groups":["redis"]}' \
  -e "group_name=<hostname>-app_restricted"
```

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/redis/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/redis-rg-<host>-app-restricted` — `visudo -cf` it;
- `getfacl /etc/redis /var/log/redis` (`/etc/valkey` / `/var/log/valkey`) — team
  group present with `rwx` (config) / `r-x` (logs) **and** matching `default:`
  entries;
- ownership on `/etc/redis` + `/var/lib/redis` unchanged from capture;
- **no `group.conf` line** — this profile has no pam_group (unless the §3 opt-in
  was used).

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Verified with `scripts/verify-profile.sh redis <distro>` (init container, real
playbook apply, probes, real `--tags cleanup`) — **pending** for this capture.
On a live host, as a user holding only app-restricted:

```bash
sudo -l -U <pilot>                              # exactly the scoped grants
sudo systemctl restart redis                    # allow (valkey / redis-server per distro)
sudo journalctl -e -u redis                     # allow (granted spelling)
echo "# probe" >> /etc/redis/redis.conf         # allow — config write via ACL
sudo systemctl restart sshd                     # DENY
echo x | sudo tee /usr/lib/systemd/system/redis.service      # DENY (read-only units)
touch /var/lib/redis/.probe                      # DENY — data dir not granted
sudo systemctl restart redis-sentinel            # DENY — Sentinel dropped
```

There is **no behavioral pam_group check** — this profile grants no group
membership, so the "fresh SSH login / `id`" step and its stale-session false
negative do not apply. The one behavioral check that matters: after a
profile-scoped `restart`, redis comes back up and serves (`redis-cli ping` →
`PONG`).

## 6. Flip

Remove the team from `<hostname>-app_full` (restricted grants are already live via
nesting), `loginctl terminate-user <user>` per user, `sss_cache -E`. Both are
required — the host-level `app-full → wheel` pam_group mapping persists in open
sessions and the SSSD cache otherwise. Confirm on a fresh login: `id` shows no
`wheel`, `sudo -l` shows only the profile.

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time
(e.g. add the pam_group opt-in from §3, or `-e '{"declarative_access_services":[]}'`
to revoke service control); or full revoke with the same command +
`--tags cleanup`. Cleanup removes the sudoers file and the ACLs (access **and**
default) on `/etc/redis` and `/var/log/<app>`. It deliberately leaves
parent-directory traverse ACLs (shared across profiles) and **never reverts
ownership** — the captured `/etc/redis` + `/var/lib/redis` owner/modes stay as
they were. No linger and (barring the §3 opt-in) no `group.conf` line exist to
clean up.

## 8. Drift and patching

This profile introduces **no ownership deviation** from vendor packaging (no
setgid content dir; captured ownership is kept as-is), so `rpm -V redis` /
`rpm -V valkey` / `dpkg --verify redis-server` flag **nothing new from us** —
unlike the webserver profiles' setgid web root. The only grants that exist are
ACLs, and ACLs are invisible to `rpm -V`/`dpkg --verify`.

Package upgrades replace `/etc/redis/redis.conf` and reset package-dir modes,
**shedding the config ACL** — re-run playbook 5 after patching; it is
idempotent. `authselect apply-changes` can drop the host-level pam_group line
from `/etc/pam.d/sshd` (the `app-full → wheel` mapping, not this app) — re-run or
use a custom authselect profile.

## 9. TLS: key ownership and rotation

redis differs from nginx/httpd here and it changes who may read the key. redis
runs as the unprivileged **`redis`/`valkey` user from process start** (`User=`
in the unit; no root phase), so **redis reads its TLS key as that service
account**, not as root [app-knowledge]. Consequences:

- The key still lives in the platform key dir (`/etc/pki/tls/private` /
  `/etc/ssl/private`) and is **never in this profile** — but it must be made
  readable by the `redis`/`valkey` account (group or ACL for the service user),
  not left `0600 root:root`, or redis cannot start TLS.
- Rotation stays split: **platform** places the new cert+key readable by the
  service account; **the team** runs their granted `systemctl restart` (redis
  has no graceful reload — brief outage). No cert-admin opt-in profile is needed;
  the team never owns the cert dirs. See [tls-ssl.md](../../concepts/tls-ssl.md).

## 10. Logs

journalctl grants are per-unit scoping — never substitute `systemd-journal`
group membership (host-global journal read). The log-read ACL + default ACL keep
rotated files readable ([concepts/logging.md](../../concepts/logging.md)).

- **EL (redis/valkey):** default logging is the **journal** (`logfile` unset), so
  the file-log mask gotcha is moot until an operator sets `logfile`. If they do,
  run the pre-flip test on the target file.
- **Ubuntu (redis-server):** file logging is on by default. Pre-flip test:

  ```bash
  logrotate -f /etc/logrotate.d/redis-server
  getfacl /var/log/redis/redis-server.log   # team group present, no #effective:---
  ```

Note the **self-logging** case: if `logfile` is set, redis writes and may rotate
its own file, and the file's mode (its `umask`, `007` in the Debian unit) sets
the ACL mask — verify the fresh file shows no `#effective:---` cap before relying
on the grant ([logging.md](../../concepts/logging.md)).

## 11. Known risks (from `risks[]`)

`risks[]` is **empty** for all three captures — no high/critical entries to
accept or fix. Standing `[app-knowledge]` notes for the reviewer's record:

- **Data-dir read via the service group** is the reason pam_group is dropped
  (§2/§3); it is a design property of redis persistence, not an install defect.
- redis ships **`bind 127.0.0.1` + protected-mode on** by default — safe until an
  operator widens `bind`. `requirepass` is **empty by default**; setting a
  password (or ACL user) before exposing the port is an operator responsibility,
  not something this profile can enforce `[needs-runtime-confirmation]`.

## 12. Storage and growth

Doctrine — who may provision, the mount trap, the separate-volume rule — lives in
[storage, disks, and growth](../../concepts/storage.md). This section is the
redis/valkey instantiation only.

**Install floor (evidence).** Summed added-file sizes from the same footprints as
§1. Treat it as an install **floor, not a forecast**: it answers "will it fit,"
never "how fast will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).

| | alma9 (redis) | alma10 (valkey) | ubuntu 24.04 (redis-server) |
| --- | --- | --- | --- |
| Install floor (all added files) | **9.3 MB** / 45 files | **10.8 MB** / 43 files | **14.0 MB** / 36 files |
| Nearly all of it | binaries 9.2 MB (12 paths) | binaries 10.6 MB (12 paths) | binaries 12.2 MB (10 paths) + libraries 1.6 MB |
| Config | `/etc/redis` 0.10 MB (`redis.conf` 92 KB + `sentinel.conf` 13 KB) | `/etc/valkey` 0.12 MB (`valkey.conf` 110 KB + `sentinel.conf` 14 KB) | `/etc/redis` 0.11 MB (`redis.conf` 104 KB) |
| Dataset inside that total | **none** — `/var/lib/redis` ships empty (`redis:redis 0750`) | **none** — `/var/lib/valkey` empty (`valkey:valkey 0750`) | **none** — `/var/lib/redis` empty, even though apt started the service (§1) |

Two things to know about those figures. They **double-count the merged-`/usr`
path views** — `/bin/redis-server` and `/usr/bin/redis-server` carry the same
`sha256`, and on Ubuntu `redis-check-aof`/`redis-check-rdb` are one file behind
four paths — so the de-duplicated on-disk cost is roughly **4.7 / 5.5 / 4.5 MB**.
Quote the table's number anyway: it is conservative in the right direction. And
no capture contains a `dump.rdb` or an AOF file, so **the floor prices in zero
data**; `/var/log` is excluded from footprints, so no log volume is priced in
either. Size a host as this floor plus the dataset budget below.

**What grows.**

| Driver | Bounded? | Detail |
| --- | --- | --- |
| Persisted dataset — RDB `dump.rdb` and/or AOF, under the data dir | **No** — but the ceiling is RAM, not the disk | it tracks the in-memory dataset, so `maxmemory` is the real limit — and unusually for this library, that limit is a setting the team can change themselves (dev §3) `[app-knowledge]` |
| Rewrite headroom | transient, and the reason a "just big enough" volume fails | an AOF rewrite transiently needs roughly **double** the AOF size; a `BGSAVE` forks and writes a temp RDB before renaming, so budget ≈ one extra dataset on top `[app-knowledge]` |
| Persistence disabled | N/A — memory-only, disk growth nil | the shipped `save` / `appendonly` values are **not** in the footprint (it records size and sha256, not content) — read them on the host with `redis-cli CONFIG GET save appendonly` before sizing `[needs-runtime-confirmation]` |
| Log files | ubuntu: **yes** — the shipped fragment; **N/A on alma9/alma10** until an operator sets `logfile` | on Ubuntu `/var/log/redis/redis-server.log` sits on the **root filesystem**; EL writes nothing there by default (§10) |
| journald | **Yes** — `SystemMaxUse` default | the default sink on EL; only unbounded if an operator raised the cap |

**Separate volume: only if persistence is on — and then mount it at the data
path.** A memory-only cache needs no volume at all; that is the first thing to
establish. With RDB or AOF enabled, redis behaves like the doctrine's
[cache-with-persistence row](../../concepts/storage.md#what-actually-grows):
unbounded in principle, but pinned in practice to `maxmemory`. Size the volume at
**a multiple of `maxmemory`** — live snapshot plus rewrite temp copy, so ≥2×, more
if AOF and RDB are both on `[app-knowledge]` — and mount it at the app's own data
path, never a new one
([separate volumes](../../concepts/storage.md#separate-volumes-when-and-where)).

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Mount point | `/var/lib/redis` | `/var/lib/valkey` | `/var/lib/redis` |
| Required state on the new fs root | `redis:redis 0750` | `valkey:valkey 0750` | `redis:redis 0750` |
| Restored by playbook 5? | **Yes** — the profile asserts ownership on exactly this path | **Yes** — same | **Yes** — same |
| SELinux relabel | required (enforcing) | required (enforcing) | N/A on ubuntu — AppArmor, no `fcontext` step |
| Unit-level constraint | none — no hardening declared (§1) | none — same | `ProtectSystem=strict` with `ReadWritePaths=/var/lib/redis` (§1): mount at **that** path and the daemon still writes; point `dir` at an invented path instead and it hits a read-only filesystem no matter who owns it |

Redis gotcha before you mount: **stop the service and copy the data across
first.** A mount over a populated data dir hides the existing `dump.rdb`/AOF;
redis then starts with an empty dataset and writes a fresh snapshot onto the new
volume, so the old one is not lost so much as invisible — and looks exactly like
data loss to the team `[app-knowledge]`.

**Mount → re-apply → `getfacl`, in that order.** Follow
[the ops ordering](../../concepts/storage.md#separate-volumes-when-and-where) as
written; two redis specifics sit on top of it:

- **Re-apply even though the data dir carries no team ACL.** This profile never
  grants `/var/lib/redis` (§2), so a mount there costs the team nothing — what it
  hides is the profile's **ownership assertion**, and playbook 5 restores exactly
  that on all three distros (table above).
- **The mount that does cost the team its access** is a `/var/log` volume landing
  over the granted `/var/log/redis` (`/var/log/valkey`) read ACL — the realistic
  case for [the mount trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it)
  here, since nobody mounts over `/etc/redis`.

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/redis/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
stat -c '%U:%G %a' /var/lib/redis   # redis:redis 750 (valkey:valkey on alma10)
getfacl /var/log/redis              # team entry back, no #effective:---
```

**Log retention.** All three distros ship a fragment, but only Ubuntu writes a
file for it to rotate:

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Fragment shipped | `/etc/logrotate.d/redis` `root:root 0644` | `/etc/logrotate.d/valkey` `root:root 0644` | `/etc/logrotate.d/redis-server` `root:root 0644` |
| Default sink | journald (`logfile` unset) | journald (same) | **file** `/var/log/redis/redis-server.log` + journald |
| Bounded out of the box | yes — journald `SystemMaxUse`; the fragment rotates a file nothing writes until an operator sets `logfile` | yes — same | yes — by the shipped fragment (create-mode/`UMask=007` detail in §10) |
| Team can change retention | no — `root:root`, outside the grant | no — same | no — same |

The footprint records each fragment's existence and size, not its contents, so
the actual `rotate`/`size` values are `[needs-runtime-confirmation]` — read the
file on the host before promising a retention number. The fragment, journald's
limits, and alert thresholds are in **no** profile: retention changes are an ops
request, handled in the change window from
[lifecycle](../../concepts/lifecycle.md).
