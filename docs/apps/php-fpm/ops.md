# php-fpm — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/php-fpm/{almalinux-9,almalinux-10,ubuntu-24.04}-access.yml` with
their untouched `-raw.yml` siblings. Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

php-fpm is an **app-server** but its reviewed profile comes out
**config-scoped** — closer to a database's shape than a web server's,
because php-fpm owns no content directory of its own (it executes PHP inside
the *web server's* document root). The consequence runs through every
section below: config + log ACLs + service control, and **no pam_group by
default**. See §2/§3.

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-php-fpm.json` (schema 1.0,
`footprint_type: install_time`, captured 2026-08-09 on EC2 AMIs; cairn
0.10.0 feature branch):

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Files added / modified | 102 / 50 | 98 / 54 | 298 / 32 |
| Units installed | `php-fpm.service` (+ vendor `httpd`/`nginx` integration drop-ins) | same | `php8.3-fpm.service` + `phpsessionclean.service`/`.timer` (apt auto-started; enablement symlinks captured) |
| Accounts created | **none** — reuses pre-existing `apache` | none — `apache` | none — reuses `www-data` |
| Pool dir | `/etc/php-fpm.d` `root:root 0755` (`www.conf`) | same | `/etc/php/8.3/fpm/pool.d` `root:root 0755` (`www.conf`) |
| Runtime state | `/var/lib/php/{session,opcache,wsdlcache}` `0770 root:apache` | same | `/var/lib/php/sessions` `1733 root:root` (GC'd by `phpsessionclean`) |
| logrotate | `/etc/logrotate.d/php-fpm` | same | `/etc/logrotate.d/php8.3-fpm` |
| Other | — | ships `tmpfiles.d/php.conf` | `/etc/cron.d/php` (CLI session GC), `/etc/init.d/php8.3-fpm` SysV shim |
| Vendor sudoers shipped | none (`privilege.sudoers_files` empty) | none | none |

**Runs-as evidence.** No unit sets `User=`, so the **master runs as root**
(the source of every `risks[]` entry — §11). The workers drop to the pool
account set in `www.conf`: `apache` on EL (proven by the `root:apache`
state dirs), `www-data` on Debian [app-knowledge on the exact `www.conf`
value; the state-dir group is the captured evidence].

Ubuntu's footprint is larger and includes first-start side effects (apt
auto-starts services); EL captures do not. That's evidence, not noise — but
raw profiles are not line-comparable across distros.

## 2. Raw → reviewed: the decisions

| Change | Tag | Why |
| --- | --- | --- |
| Drop all `files_modify` (6 / 4 / 8 entries) | REVIEW-DROP | Vendor `php-fpm.service`, the `httpd`/`nginx` integration drop-ins (which target *other* apps' units), and Ubuntu's enablement symlinks. A unit-file write ACL is root-equivalent for that unit. Read-only-units profile. |
| Do **not** add `pam_group` + `local_groups: ['apache'/'www-data']` | REVIEW-DROP | The webserver-class default (nginx/apache REVIEW-ADD it), refused here. php-fpm owns no content dir; the shared web-root setgid grant lives in the web server's profile. The group's only local reach is `/var/lib/php/{session,opcache}` (EL `0770 root:apache`, live session state) — and on Debian `www-data` owns *none* of php-fpm's state (sessions dir is `root:root 1733`). Apply-time opt-in kept (§3). |
| Keep `/etc/php-fpm.d` (Ubuntu: narrow `/etc/php` → `/etc/php/8.3/fpm/pool.d`) | REVIEW-KEEP / REVIEW-CHANGE | Config **write ACL** on the FPM pool dir — the team's real knob. Per-pool `php_admin_value` covers PHP tuning, so the shared `php.ini`/`php.d` need not be granted. Ubuntu's raw granted the whole `/etc/php` tree (CLI SAPI + `mods-available` included); narrowed to the FPM pool dir to match EL. |
| Drop `/etc/php.d` (EL) | REVIEW-DROP | php-common's shared extension dir, used by the PHP **CLI** SAPI too — enabling/tuning a module there is host-wide, an ops/change-window act. |
| Drop `/etc/systemd/system/php-fpm.service.d` (EL) | REVIEW-DROP | Unit drop-in dir — root-equivalent with the granted `daemon-reload` + `restart`. |
| Drop `/var/lib/php` (all) | REVIEW-DROP | Service runtime state (session/opcache/wsdlcache). The workers write here, not the team; the session dir holds live user data. Left at vendor defaults, not granted (mirrors nginx's `/var/lib/nginx`). |
| Drop `phpsessionclean` service + timer (Ubuntu) | REVIEW-DROP | php-common's session GC — a timer-driven oneshot, host housekeeping the team never operates. EL has no equivalent unit (session GC is `php.ini` probability), so dropping it keeps the surface parallel. |
| Normalize `profile_name` `php8.3-fpm` → `php-fpm` (Ubuntu) | REVIEW-CHANGE | The library app slug; `check_profiles` requires `profile_name == the app dir`. |
| Add `/var/log/php-fpm` read (EL) | REVIEW-ADD | `/var/log` excluded from footprints by default; the dir gets a read + default ACL. |
| Add `/var/log/php8.3-fpm.log` read (Ubuntu) | REVIEW-ADD | Debian's master log is a single file, not a dir — granted via `files_read`, with the rotation caveat in §10. |
| No `ownership` entries | as reviewed | Unlike nginx/apache there is **no setgid content dir** and **no created account** to pin — so, like the DB profiles, this makes zero vendor-permission deviation (§8). |

## 3. Access model for this app class

app-server, realized **config-scoped**: config **write ACL** on the pool
dir + log **read ACL** + full service control, **no pam_group** into the
service group by default, and **never** the runtime state dir. See the
[access model](../../concepts/access-model.md) decision matrix — this is the
matrix's config + log rows without the content row (php-fpm has no content
of its own) and without the identity/group row (it would buy only session
state).

**The pam_group opt-in.** The group option stays available at apply time for
a co-located LAMP/LEMP host where the same team writes app code into the web
server's setgid document root (on such hosts they typically already hold the
group via the web-server profile):

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/php-fpm/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" \
  -e '{"declarative_access_pam_group": true, "declarative_access_local_groups": ["apache"]}'
```

Use `www-data` on Ubuntu — and note it is **shared** with nginx/apache2, so
that opt-in is for single-app servers only. Treat it as a reviewed
exception, not a default: it grants read of live PHP session files under
`/var/lib/php`.

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/php-fpm/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/php-fpm-rg-<host>-app-restricted` — `visudo -cf` it.
- **No `group.conf` line** — this profile has no pam_group (unless the §3
  opt-in was passed).
- `getfacl /etc/php-fpm.d` (Ubuntu: `/etc/php/8.3/fpm/pool.d`) — team group
  `rwx` + a `default:` entry.
- `getfacl /var/log/php-fpm` (EL) / `getfacl /var/log/php8.3-fpm.log`
  (Ubuntu) — team group read.
- **No ownership changes / no setgid dir** — nothing to accept-list.

Applying is non-breaking while the team still holds app-full (group
nesting).

## 5. Verify

Verify with `scripts/verify-profile.sh php-fpm <distro>` (init container,
real playbook apply, probes, real `--tags cleanup`). On a live host, as a
user holding **only** app-restricted:

```bash
sudo -l -U <pilot>                                # exactly the scoped grants
sudo systemctl reload php-fpm                      # allow (Ubuntu: php8.3-fpm)
sudo journalctl -e -u php-fpm                      # allow (granted spelling)
vi /etc/php-fpm.d/probe.conf && rm $_              # allow (config ACL)
sudo systemctl restart sshd                        # DENY
echo x | sudo tee /usr/lib/systemd/system/php-fpm.service   # DENY (read-only units)
echo x >> /etc/php.ini                             # DENY (shared config not granted)
cat /var/lib/php/session/*                         # DENY (runtime state not granted)
```

Behavioral: after `sudo systemctl restart php-fpm`, confirm the master
returns (`systemctl status`), `php-fpm -t` is clean, and a request routed
through the web server in front still executes PHP (the FastCGI socket is
back). There is **no behavioral pam_group check** for this profile — no
service-group membership is granted (unless the §3 opt-in was applied, in
which case check `id` in a **fresh** SSH login; a stale session is a false
negative — pam_group is per-login).

## 6. Flip

Remove the team from `<hostname>-app_full` (restricted grants are already
live via nesting), `loginctl terminate-user <user>` per user, `sss_cache -E`.
Confirm on a fresh login: `id` shows no wheel, `sudo -l` shows only the
profile. Because this profile grants no pam_group of its own, the only
session-staleness concern at the flip is the host `app-full → wheel`
mapping, which terminate + cache-flush clears (see
[lifecycle](../../concepts/lifecycle.md) step 9).

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; adjust at apply time (the lever
here is the *opt-in* direction in §3 — adding pam_group, not removing it);
or full revoke with the same command + `--tags cleanup`. Cleanup removes the
sudoers file and the ACLs (access **and** default) on the pool dir and log
path. Deliberate exceptions, verbatim from
[lifecycle](../../concepts/lifecycle.md): parent-directory traverse ACLs
remain (shared across profiles — `setfacl -x g:<group> /etc` etc. by hand if
the entity has no other profiles), and ownership is never reverted — but
this profile sets none, so there is nothing to re-chown.

## 8. Drift and patching

A nice property of the config-scoped php-fpm profile: like the DB profiles
it makes **no vendor-permission deviation** — no setgid dir, no ownership
entry — so `rpm -V php-fpm` / `dpkg --verify php8.3-fpm` stay clean with
respect to *this* profile. ACLs are invisible to rpm/dpkg verification
either way.

- **Package updates shed file ACLs.** A `dnf update php-fpm` / `apt upgrade`
  replaces `www.conf` and the pool dir and drops their ACLs — re-run
  playbook 5 (idempotent) after patching; verify with `getfacl`.
- **A PHP *version* bump on Ubuntu is not just a re-apply.** 8.3 → 8.4
  changes the unit name (`php8.4-fpm.service`) **and** the config path
  (`/etc/php/8.4/fpm/pool.d`) — that's a new footprint: **re-capture and
  re-review**, don't just re-run. EL tracks a single `php-fpm` across the
  distro's PHP stream, so a minor bump is a re-apply.
- **authselect** (EL) can drop a pam_group line from `/etc/pam.d/sshd` — not
  a concern for *this* profile (no pam_group unless opted in), but it still
  affects the host `app-full → wheel` mapping, so re-run the host access
  playbook after authselect changes.

## 9. TLS: key ownership and rotation

**php-fpm terminates no TLS**, so there is no key material in this profile
and nothing to rotate here. The certificate, private key, and `listen 443
ssl` belong to the nginx/Apache instance in front; php-fpm receives already-
decrypted requests over a local FastCGI socket (`/run/php-fpm/*.sock` or
`127.0.0.1:9000`). Cert rotation for a PHP site is entirely the web server's
runbook — [nginx ops §9](../nginx/ops.md) / [apache ops §9](../apache/ops.md)
and [tls-ssl.md](../../concepts/tls-ssl.md); php-fpm needs no reload when the
front cert changes. The private-key dirs (`/etc/pki/tls/private`,
`/etc/ssl/private`) are in no profile, this one included. The only TLS-
adjacent php-fpm concern is *outbound* TLS from PHP code, which is system
CA-trust — an ops change (see [tls-ssl.md](../../concepts/tls-ssl.md)).

## 10. Logs

journalctl grants are per-unit scoping — never substitute `systemd-journal`
group membership (host-global journal read). See
[logging.md](../../concepts/logging.md).

- **EL** — `/var/log/php-fpm/` is a real directory; the read + **default**
  ACL keeps rotated files readable. Pre-flip test for the mask gotcha:

  ```bash
  logrotate -f /etc/logrotate.d/php-fpm
  getfacl /var/log/php-fpm/www-error.log   # team group present, no #effective:---
  ```

  php-fpm ships its fragment with a root-based `create` mode; confirm the
  group-class bits allow read `[needs-runtime-confirmation on any host whose
  fragment or pool `error_log` mode was customized]`.
- **Ubuntu** — the master log is the single file `/var/log/php8.3-fpm.log`.
  A `files_read` ACL travels with the file across logrotate's rename, but the
  **fresh** file logrotate creates carries no ACL (there is no default ACL on
  `/var/log` itself), so the grant does not self-heal across rotation the way
  a log-dir default ACL does. Guidance: point the team at
  `journalctl -u php8.3-fpm` for durable health, or have a pool write
  `error_log`/`access.log` into a dedicated `/var/log/php8.3-fpm/` directory
  (set in the granted pool file) and add that dir to `folders_read` so the
  default-ACL mechanism applies.

`/etc/logrotate.d/php-fpm` (Ubuntu: `php8.3-fpm`) is outside the grant —
retention/frequency changes are an ops request.

## 11. Known risks (from `risks[]`)

| Risk | Sev | Distros | Decision |
| --- | --- | --- | --- |
| `php-fpm.service` has no `User=` — master runs as root | medium | all (2 entries EL, via `/lib` + `/usr/lib` unit copies) | **Accept.** This is php-fpm's design: the master runs as root to create the listen socket and manage pools, then forks workers that drop to the pool user (`apache`/`www-data` per `www.conf`). Same pattern as the nginx/httpd master. `[app-knowledge]` |
| `phpsessionclean.service` runs as root | medium | ubuntu (2 entries) | **Accept.** Short-lived session-GC oneshot that must traverse the sticky `1733` sessions dir; not a long-running root daemon. It is also **dropped from the profile** (§2), so the team gets no control over it regardless. |

No high/critical `risks[]` entries. No setuid/setgid binaries, file
capabilities, or vendor sudoers were captured on any distro
(`privilege.*` empty).

## 12. Storage and growth

**Install floor (evidence).** Summed from the same footprints as §1 — the
bytes the installer wrote. Treat it as an install **floor, not a forecast**:
it answers "will it fit," never "how fast will it fill"
([storage.md](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Install floor (all added files) | **30.9 MB** | **26.8 MB** | **42.6 MB** |
| Dominated by | binaries 16.2 MB + libs 14.6 MB | libs 16.9 MB + binaries 9.8 MB | binaries 22.1 MB + libs 20.2 MB |
| Largest single file | `/sbin/php-fpm` 8.1 MB | `fileinfo.so` 7.7 MB | `fileinfo.so` 7.7 MB |
| State dirs created | `/var/lib/php/{session,opcache,wsdlcache}` — empty | same | `/var/lib/php/sessions` — empty |

Two honest caveats on those numbers. The capture enumerates **both
merged-`/usr` path views** (`/sbin/php-fpm` *and* `/usr/sbin/php-fpm`,
`/lib/...` *and* `/usr/lib/...`, identical `sha256`), so each figure roughly
double-counts real blocks — de-duplicated they are ~15.5 / 13.5 / 21.4 MB.
Budget the table's number; it is conservative in the right direction. And
alma10's `files_modified` total is dominated by `rpmdb.sqlite` (32 MB,
counted twice) — package-manager bookkeeping, not php-fpm payload, which is
why the floor is added-files only. `/var/log` is excluded from footprints,
so no log volume is priced in here either.

**Growth drivers.** php-fpm is one of the flattest apps in this library: no
dataset, no transaction log, no content directory of its own.

| Driver | Grows | Bounded by | Who acts |
| --- | --- | --- | --- |
| Journal (`php-fpm.service`) | slowly — master lifecycle + fatals | journald `SystemMaxUse` | ops |
| FPM error log: `/var/log/php-fpm/` (EL) / `/var/log/php8.3-fpm.log` (Ubuntu) | slowly | the shipped logrotate fragment | ops |
| Per-pool `access.log` / `slowlog`, when a pool enables them | **per request** — the only log here that surprises people | the fragment, *if* its glob matches the path the pool writes to `[needs-runtime-confirmation]` | dev enables it, ops sizes for it |
| `/var/lib/php/session` (EL, `0770 root:apache`) | **unbounded if GC is misconfigured** | no GC unit and no cron job captured on EL (`scheduled.cron_jobs` empty) — only `session.gc_probability` / `gc_maxlifetime` `[app-knowledge]` | dev, via `php_value[session.gc_*]` in the granted pool file |
| `/var/lib/php/sessions` (Ubuntu, `1733 root:root`) | bounded in practice | `phpsessionclean.timer`, with `/etc/cron.d/php` (`09,39 * * * *`) as the non-systemd fallback — both **dropped from the profile** (§2) | ops |
| `/var/lib/php/{opcache,wsdlcache}` (EL) | negligible | only written when `opcache.file_cache` / SOAP caching is enabled `[app-knowledge]` | — |
| The document root PHP executes from | **the real growth on a PHP box** | not php-fpm's path — sized under the web server's profile | [nginx ops](../nginx/ops.md) / [apache ops](../apache/ops.md) |

**Separate volume: normally no.** php-fpm owns no data path worth a volume.
On a PHP host the volume belongs to the **web server's document root** —
provision it there, under the front-end's profile. Two php-fpm-specific
exceptions, both mounted at the app's own existing path, never a new one:

- **High session volume on EL** — mount at **`/var/lib/php`** (php-fpm's own
  state path). Fix the GC first; a volume is not a substitute for GC.
- **A separate `/var/log` volume** — common, and the realistic case here: it
  lands *over* the granted `/var/log/php-fpm` (EL) and hides the team's read
  ACL.

**Ordering, whenever a mount lands on or above a granted path.** The granted
paths are `/etc/php-fpm.d` (Ubuntu: `/etc/php/8.3/fpm/pool.d`) and the log
path in §4: mount → restore ownership/mode and, on EL, the SELinux label →
**re-apply playbook 5** (§4) → `getfacl` the path to confirm the team entry
is back. Full procedure:
[separate volumes: when and where](../../concepts/storage.md#separate-volumes-when-and-where);
why skipping it silently revokes the team:
[the mount-hides-ACLs trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it).
Same re-apply reflex as after `dnf update` / `apt upgrade` (§8).

**Log retention.** All three distros ship a fragment — `/etc/logrotate.d/php-fpm`
(EL), `/etc/logrotate.d/php8.3-fpm` (Ubuntu) — so file logs are bounded out
of the box; the fragment's retention values are not captured in the
footprint `[needs-runtime-confirmation]`. Journal volume is bounded by
journald, not by that fragment. Both are outside the profile: retention or
frequency changes are an **ops request**, and after any fragment edit re-run
the EL mask check (`logrotate -f` + `getfacl`) from §10 to confirm the team's
read survived.
