# Apache HTTP Server — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/apache/{almalinux-9,almalinux-10,amazonlinux-2023,ubuntu-24.04,ubuntu-26.04}-access.yml`
([alma9 reviewed](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/almalinux-9-access.yml),
[alma10 reviewed](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/almalinux-10-access.yml),
[al2023 reviewed](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/amazonlinux-2023-access.yml),
[ubuntu 24.04 reviewed](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/ubuntu-24.04-access.yml),
[ubuntu 26.04 reviewed](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/ubuntu-26.04-access.yml))
each with an untouched `-raw.yml` sibling
([alma9 raw](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/almalinux-9-raw.yml),
[alma10 raw](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/almalinux-10-raw.yml),
[al2023 raw](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/amazonlinux-2023-raw.yml),
[ubuntu 24.04 raw](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/ubuntu-24.04-raw.yml),
[ubuntu 26.04 raw](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/ubuntu-26.04-raw.yml)).
Should you even hand-install this? See the
[role evaluation](../../role-evals/apache.md). Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-apache.json` (schema 1.0,
`install_time`, captured 2026-08-23 on holy-qcow KVM golden images,
treadmark 0.11.0). Amazon Linux 2023 (`al2023`) is EL-family and captures
the EL shape.

| | alma9 (`httpd`) | alma10 (`httpd`) | al2023 (`httpd`) | ubuntu 24.04 (`apache2`) | ubuntu 26.04 (`apache2`) |
| --- | --- | --- | --- | --- | --- |
| Files added / modified | 846 / 223 | 847 / 234 | 867 / 232 | 887 / 36 | 903 / 38 |
| Units installed | `httpd.service` (root), `httpd@.service` (root, template), `httpd.socket`, `htcacheclean.service` (User=`apache`) | same | same | `apache2.service` (root), `apache2@.service`, `apache-htcacheclean{,@}.service` (User=`www-data`) | same as 24.04 + `ssl-cert.service` (root, one-shot) + `httpd{,@}.service` **compat alias symlinks** of `apache2{,@}.service` |
| Dependency-pulled / first-start | — (dnf does not auto-start) | — | — | apt auto-started: `multi-user.target.wants/apache2.service` enablement symlink (`ssl-cert` pre-exists in this golden image's baseline — no snakeoil generation captured) | apt auto-started: both enablement symlinks + `ssl-cert` dependency landed here — snakeoil pair generated (`/etc/ssl/private/ssl-cert-snakeoil.key` `root:ssl-cert 0640`) |
| Accounts created | `apache` uid/gid 48, home `/usr/share/httpd`, shell `/sbin/nologin`, system | same | same | none (`www-data` and `ssl-cert` pre-exist) | none (`www-data` pre-exists); group `ssl-cert` gid 109 added |
| Config root | `/etc/httpd` `root:root 0755` (+ `conf`, `conf.d`, `conf.modules.d`) | same (+ empty `/etc/systemd/system/httpd.service.d`) | same as alma10 (incl. the empty `httpd.service.d`) | `/etc/apache2/{sites,conf,mods}-{available,enabled}` `root:root 0755` | `/etc/apache2` `root:root 0755` (whole tree new to this baseline) |
| Service state dir | `/var/lib/httpd` `apache:apache 0700` | same | same | `/var/lib/apache2` `root:root` (32 state files) | same as 24.04 |
| Content root (DocumentRoot) | `/var/www/html` — **not captured** (ships/pre-exists empty, uncategorized) | same | same | same | same |
| Log dir | `/var/log/httpd` — excluded from footprints by default | same | same | `/var/log/apache2` — excluded | same |
| logrotate fragment | `/etc/logrotate.d/httpd` `root:root 0644` | same | same | `/etc/logrotate.d/apache2` (+ `/etc/cron.daily/apache2` `@daily` run-as root) | same as 24.04 |
| Vendor sudoers shipped | none (`privilege.sudoers_files` empty) | none | none | none | none |

Ubuntu's footprints include first-start side effects (apt auto-starts
services); EL captures do not. That's evidence, not noise — but raw
profiles are not line-comparable across distros. The two Ubuntu baselines
also differ: the 24.04 golden image pre-installs `ssl-cert` and carries a
leftover `/etc/apache2` skeleton (so its raw enumerated new leaf dirs),
while the 26.04 baseline was clean (its raw grants the `/etc/apache2` root
directly; `ssl-cert` group + snakeoil landed in the capture).

`privilege.file_capabilities` (EL family — alma9, alma10, al2023):
`/usr/sbin/suexec` and `/sbin/suexec`, mode `0510 root:apache`, carrying
`cap_setgid,cap_setuid` as a file-capability xattr (**not** the setuid bit
— see §11).

Vendor unit hardening diverges: EL10's units ship
`ProtectSystem=yes` + `ProtectHome=read-only`; ubuntu 26.04's ship
`ProtectSystem=full`, `ProtectHome=read-only`, `PrivateTmp`, and
`InaccessiblePaths` covering `/root`, sudoers, and `/etc/ssh`. alma9,
al2023, and ubuntu 24.04 units carry no hardening directives. None of it
changes a read-only-units profile.

## 2. Raw → reviewed: the decisions

One row per delta; the tag matches the `REVIEW-*` comment in the reviewed
profile.

| Change | Tag | Why |
| --- | --- | --- |
| `profile_name` `httpd`/`apache2` → `apache` | REVIEW-CHANGE | The library app slug is `apache`; `tools/check_profiles.py` requires `profile_name == app dir`. Artifact names follow the slug; the raw keeps the package name. |
| Drop `htcacheclean` (EL) / `apache-htcacheclean` (Ubuntu) from services | REVIEW-DROP | `mod_cache_disk` cache cleaner, off by default; not the web server. Add back only if disk caching is enabled. |
| Drop `httpd` from services (ubuntu 26.04) | REVIEW-DROP | New in 26.04's `apache2` package: `httpd{,@}.service` are compat **alias symlinks** of `apache2{,@}.service`. Same unit, second sudoers spelling — granting the alias doubles the surface for nothing. |
| Drop `ssl-cert` from services (Ubuntu — captured on 26.04; 24.04's fresh raw no longer lists it because its golden baseline pre-installs `ssl-cert`) | REVIEW-DROP | One-shot `make-ssl-cert generate-default-snakeoil` that ran at apt auto-start; not a service the team operates. |
| Drop all `files_modify` (8 EL / 9 ubuntu 24.04 / 16 ubuntu 26.04) | REVIEW-DROP | All vendor units, the instance template, the socket (EL), the 26.04 alias symlinks, and (Ubuntu) apt's enablement symlinks. A unit-file write ACL is root-equivalent for that unit. Read-only-units profile. |
| Drop `/etc/systemd/system/httpd.service.d` (alma10 + al2023) | REVIEW-DROP | Unit drop-in dir (shipped empty) — same root-equivalence with granted `daemon-reload`+`restart`. |
| Drop `/var/lib/httpd` (EL) / `/var/lib/apache2` (Ubuntu) from folders | REVIEW-DROP | Service/maintainer runtime state; not team space. EL install state kept via `ownership`. |
| Drop `/etc/ufw/applications.d/apache2` (Ubuntu) | REVIEW-DROP | Firewall/ufw is ops, never an app grant; dependency-pulled onto the box. |
| Consolidate Ubuntu config leaf dirs → `/etc/apache2` (24.04 only — 26.04's raw already grants the root, kept as captured) | REVIEW-CHANGE | One write ACL + default ACL on the config root covers editing `*-available` and creating the `*-enabled` symlinks the `a2ensite`/`a2enmod` model needs (matches EL's single `/etc/httpd` grant). |
| Add pam_group + `apache` / `www-data` | REVIEW-ADD | Webserver class: identity/read baseline + content-group. Debian caveat: `www-data` is shared — single-app servers only (REVIEW-KEEP note in the profile). |
| Add `/var/log/httpd` / `/var/log/apache2` read | REVIEW-ADD | `/var/log` is excluded from footprints by default. |
| Add setgid content dir `/var/www/html` (`root:<group> 2775`) | REVIEW-ADD | Team writes content via the group; new files inherit it. Not in the footprint (DocumentRoot uncategorized) — hand-added. The one intentional vendor-permission deviation — accept-list it (§8). |
| Keep `/var/lib/httpd` ownership (EL) | as captured | Enforces install-time state (`apache:apache 0700`); drift stays visible. |

## 3. Access model for this app class

Webserver: **pam_group** (identity + content-group at SSH login) +
**setgid content dir** (write with zero ongoing upkeep) + **config write
ACL** (the team writes config; the `apache`/`www-data` account must not —
config stays `root:root`) + **log read ACL**. See the
[access model decision matrix](../../concepts/access-model.md). This is not
a database, so pam_group is on by default (no data-dir exposure tradeoff to
opt into).

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/apache/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/apache-rg-<host>-app-restricted` — `visudo -cf` it.
- the `group.conf` line mapping the AD group to `apache` / `www-data`.
- `getfacl /etc/httpd /var/log/httpd` (Ubuntu: `/etc/apache2`,
  `/var/log/apache2`) — team group present with a default entry.
- the setgid content dir: `stat -c '%A %U:%G' /var/www/html` → `drwxrwsr-x
  root:apache` (Ubuntu `root:www-data`).

Applying is non-breaking while the team still holds app-full (group
nesting).

## 5. Verify

Verify with `scripts/verify-profile.sh apache <distro>` (init container,
real playbook apply, probes, real `--tags cleanup`). alma9/alma10/ubuntu
24.04 passed on 2026-08-09 (EC2 substrate — their headers carry the line;
the 2026-08-23 KVM re-capture changed no grants). The two new cells
(al2023, ubuntu 26.04) read `VERIFIED: pending` until the KVM verify pass
runs. On a live host:

```bash
sudo -l -U <pilot>                          # exactly the scoped grants
sudo systemctl reload httpd                 # allow (Ubuntu: apache2)
sudo journalctl -e -u httpd                 # allow (granted spelling)
sudo systemctl restart sshd                 # DENY
echo x | sudo tee /usr/lib/systemd/system/httpd.service   # DENY (read-only units)
# behavioral pam_group — FRESH ssh login:
id                                          # shows apache / www-data
touch /var/www/html/.probe && rm $_         # content write via group
```

A stale session is a false negative — pam_group is per-login.

## 6. Flip

Remove the team from `<hostname>-app_full` (restricted grants are already
live via nesting), `loginctl terminate-user <user>` per user,
`sss_cache -E`. Confirm on a fresh login: `id` shows no `wheel` (Ubuntu:
`sudo`), `sudo -l` shows only the profile.

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time
(`-e '{"declarative_access_local_groups": []}'` for an ACL-only posture on
a shared-`www-data` box); or full revoke with the same command +
`--tags cleanup`. Cleanup removes the sudoers file, `group.conf` lines, and
ACLs (incl. defaults). It deliberately leaves parent-directory traverse
ACLs (shared across profiles) and **never reverts ownership** — the setgid
content dir stays `2775` until you re-chown it deliberately.

## 8. Drift and patching

`rpm -V httpd` / `dpkg --verify apache2` will flag the setgid content dir —
that is reviewed, intentional drift: record `/var/www/html 2775 root:apache`
(Ubuntu `root:www-data`) in the golden-baseline accept-list. ACLs are
invisible to rpm/dpkg verification. Package upgrades replace files and may
reset package-dir modes (no unit ACLs exist here, so upgrades shed nothing
of ours): re-run playbook 5 after patching — it is idempotent. authselect
runs can drop the pam_group line from `/etc/pam.d/sshd` (EL) — re-run or use
a custom authselect profile; Ubuntu edits `/etc/pam.d/sshd` directly and is
not subject to authselect.

## 9. TLS: key ownership and rotation

Platform owns `/etc/pki/tls/private` (EL) / `/etc/ssl/private` (Ubuntu,
`0710 root:ssl-cert`) — root, `0600`/`0640`, in no profile. Rotation:
platform places cert+key → the **team** runs their granted `reload` — the
boundary stays clean. Apache's root parent reads the key at startup/reload;
the `apache`/`www-data` workers never touch it. See
[TLS: nginx/httpd exception](../../concepts/tls-ssl.md#per-application-class-exceptions).

Ubuntu ships a **self-signed snakeoil** pair
(`/etc/ssl/certs/ssl-cert-snakeoil.pem`, `/etc/ssl/private/ssl-cert-snakeoil.key`
`root:ssl-cert 0640`, readable by the `ssl-cert` group — the team is **not**
added to `ssl-cert`). The 26.04 capture recorded its generation at install
(`group_access`: `ssl-cert` gid 109, read on the key); on the 24.04 golden
image the pair pre-exists in the baseline. Replace it with a CA-issued
certificate before production. EL-family first-time TLS (alma9/10, al2023)
additionally needs `dnf install mod_ssl` — a change window (footprint
change), not a profile grant. If a team must own
the cert dirs (edge case), use the cert-admin opt-in profile pattern from
the collection's examples — not this profile.

## 10. Logs

journalctl grants are per-unit scoping — never substitute `systemd-journal`
(or `adm`) group membership (host-global journal read), per
[Logs & rotation](../../concepts/logging.md#reading-the-journal-the-granted-spellings).
Pre-flip test for the rotation mask gotcha:

```bash
logrotate -f /etc/logrotate.d/httpd        # Ubuntu: /etc/logrotate.d/apache2
getfacl /var/log/httpd/access_log          # team group present, no #effective:---
```

Debian's `apache2` fragment creates rotated files `create 640 root adm` —
group-class `r--`, so the ACL mask allows read [needs-runtime-confirmation
on customized fragments]. EL's `httpd` fragment rotates with root-based
create and `postrotate systemctl reload httpd`. Ubuntu also ships
`/etc/cron.daily/apache2` (runs as root) — a package housekeeping job, not
a team grant; note it exists but leave it to ops.

## 11. Known risks (from `risks[]`)

| Risk | Severity | Distros | Decision | Owner |
| --- | --- | --- | --- | --- |
| `/usr/sbin/suexec` + `/sbin/suexec` carry a `security.capability` xattr | high | alma9, alma10, al2023 | **Accept as install default.** This is a **file capability** (`cap_setgid,cap_setuid`), not the setuid bit (`mode 0510 root:apache`, `setuid: false`) — suexec drops privilege *into* a target user for CGI and only the `apache` group may execute it. It is inert unless suexec-based CGI is configured. Do not chmod it; if CGI-under-user is not used, leave it (group-restricted) or remove the `mod_suexec`/`httpd-tools` path in a change window. | ops |
| `httpd`/`apache2`/`ssl-cert` run as root (no `User=`) | medium | all five | **Accept as design.** Apache's parent binds `:80`/`:443` (privileged ports) as root then drops workers to `apache`/`www-data`; this is the master-as-root web-server pattern, not an install defect `[app-knowledge]`. (ubuntu 26.04's `risks[]` counts the alias symlinks and `ssl-cert.service` as extra rows — same finding.) | ops |
| Self-signed snakeoil cert active | (not in `risks[]`; evidence) | ubuntu 26.04 (captured at install); ubuntu 24.04 (pair pre-exists in the golden-image baseline) | **Fix before production** — replace with a CA-issued cert (§9). | ops |

No `risks[]` entry justifies widening the profile. suexec's file
capability is the one high-severity item and it is not reachable by the
restricted team (execute is gated to the `apache` group and suexec is off
until CGI is configured).

## 12. Storage and growth

**Install-time floor**, from the same `footprint-apache.json` captures as
§1 — the summed sizes of the files the capture recorded as **added**. Treat
it as a floor, not a forecast: it answers "will it fit," never "how fast
will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).

| | alma9 | alma10 | al2023 | ubuntu 24.04 | ubuntu 26.04 |
| --- | --- | --- | --- | --- | --- |
| Install floor | **10.6 MB** | **10.4 MB** | **12.2 MB** | **13.4 MB** | **13.7 MB** |
| Dominated by | `library` 8.0 MB, `binary` 1.7 MB | `library` 7.9 MB, `binary` 1.7 MB | `library` 9.6 MB, `binary` 1.7 MB | `library` 10.6 MB, `binary` 2.1 MB | `library` 10.8 MB, `binary` 2.2 MB |
| Not in the floor | `/var/log/httpd` (`/var/log` excluded from footprints), `/var/www/html` (uncategorized, ships empty) | same | same | `/var/log/apache2`, `/var/www/html` | same |

The `modified` set is excluded deliberately — it is dominated by the package
database rewrite (61.5 MB of `rpmdb.sqlite`, counted under both `/usr/lib`
and `/lib`, on alma10), which is bookkeeping, not app data. Budget the
working set on top of the floor, never inside it.

**Growth drivers.** Same class as nginx: logs plus content.

| Driver | Bounded? | Notes |
| --- | --- | --- |
| `/var/log/httpd` (Ubuntu `/var/log/apache2`) | yes, by the shipped fragment | the access log is the volume; `LogLevel debug` or per-vhost logs multiply it `[app-knowledge]` |
| `/var/www/html` content | **no** | whatever the team writes into the setgid dir — the only unbounded driver on a stock install |
| journal | yes — journald default cap | startup/exit messages only (§10); not a growth driver here |
| `/var/cache/httpd` disk cache | **no**, once enabled | requires `mod_cache_disk`, off by default `[app-knowledge]`; the `htcacheclean` cleaner unit is installed but **dropped from the profile** (§2) — re-add the cleaner *and* size the cache if caching is turned on |
| `/var/lib/httpd` (Ubuntu `/var/lib/apache2`) | yes | install-time state only (EL: one empty dir `apache:apache 0700`; Ubuntu: the 32 maintainer state entries from §1, near-all zero-byte markers) — does not grow |

**Separate volume: usually not.** A stock web server does not warrant one —
the floor is 10–14 MB and rotated logs stay bounded. Provision a volume when
the team's content is large or user-uploaded, and mount it at
**`/var/www/html`**, the app's own content path and the one already in the
profile. Do not invent a new path and symlink: the profile grants the path
it knows. If disk caching is ever enabled, `/var/cache/httpd` is the second
candidate.

**Ordering: mount, re-apply, `getfacl`.** A mount over `/var/www/html` hides
the team's ACLs *and* the setgid bit in one step. Full procedure in
[separate volumes](../../concepts/storage.md#separate-volumes-when-and-where);
the app-specific tail:

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/apache/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
getfacl /var/www/html                 # team group back, default entry present
stat -c '%A %U:%G' /var/www/html      # drwxrwsr-x root:apache (Ubuntu root:www-data)
```

On EL, relabel before re-applying — a fresh filesystem carries no
`httpd_sys_content_t`, and Apache fails in a way that looks nothing like
SELinux `[app-knowledge]`; use the `semanage fcontext -a -e` /
`restorecon` pair from
[the mount trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it).

**Log retention.** Files, not journald — the journal holds startup/exit only
(§10). Retention comes from the shipped fragment:

| | alma9 | alma10 | al2023 | ubuntu 24.04 | ubuntu 26.04 |
| --- | --- | --- | --- | --- | --- |
| Rotation fragment | `/etc/logrotate.d/httpd` `root:root 0644` | same | same | `/etc/logrotate.d/apache2` `root:root 0644` | same |
| Extra periodic job | N/A on alma9 — no cron fragment (`scheduled.cron_jobs` empty) | N/A on alma10 — same | N/A on al2023 — same | `/etc/cron.daily/apache2` `0755 root:root`, `@daily` as root — package housekeeping, not the rotation and not a team grant (§10) | same as 24.04 |

Neither the fragment nor the cron job is in any profile: **retention and
frequency changes are an ops request in a change window**, and Ubuntu's
cron job must be reviewed alongside the fragment rather than assumed to be
part of it.
