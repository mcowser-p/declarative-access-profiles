# nginx — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/nginx/{almalinux-9,almalinux-10,ubuntu-24.04,ubuntu-26.04,amazonlinux-2023}-access.yml`
with their untouched `-raw.yml` siblings. Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-nginx.json` (schema 1.0, captured
2026-08-23 on the KVM golden-image substrate, treadmark 0.11.0):

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Units installed | `nginx.service` (counted twice — `/usr/lib` + `/lib` usr-merge alias) | same + `nginx@.service` template | `nginx.service` (+ enablement symlink — apt auto-started it) | same as 24.04 | `nginx.service` (usr-merge alias only) |
| Accounts created | `nginx` (system, nologin) | `nginx` (system, nologin) | none new (`www-data` pre-exists on Debian) | none new (`www-data` pre-exists) | `nginx` (uid 994, system, nologin, home `/var/lib/nginx`) |
| Key dirs | `/etc/nginx` root:root; `/var/lib/nginx` nginx:root 0770 | same | `/etc/nginx` root:root; `/var/lib/nginx` root:root with `www-data` 0700 buffer subdirs (first-start) | same as 24.04 | `/etc/nginx` root:root; `/var/lib/nginx` nginx:root 0770 |
| Dependency payload | none beyond the nginx packages | none | none (`/etc/ufw/applications.d/nginx` is nginx's own file, not noise) | same | gperftools-libs/libunwind pulled in — 57 library files, 3.1 MB, no grants |
| Vendor sudoers shipped | none | none | none | none | none |

Ubuntu's footprints include first-start side effects (apt auto-starts
services); EL captures do not. That's evidence, not noise — but raw
profiles are not line-comparable across distros. AL2023 boots SELinux
**permissive** by default (the Almas boot enforcing): contexts are applied
and AVCs logged, but nothing blocks — the §5 deny probes test sudo, not
SELinux, so they behave identically; flipping AL2023 to enforcing is a
platform decision outside this profile.

## 2. Raw → reviewed: the decisions

| Change | Tag | Why |
| --- | --- | --- |
| Drop all `files_modify` (2/4/3/3/2 entries — alma9/alma10/u24.04/u26.04/al2023) | REVIEW-DROP | All vendor unit files (Ubuntu adds the enablement symlink from apt auto-start; alma10 adds the `nginx@.service` template); a unit-file write ACL is root-equivalent for that unit. Read-only-units profile. |
| Drop `/etc/systemd/system/nginx.service.d` (EL family: alma9, alma10, al2023) | REVIEW-DROP | Unit drop-in dir — same root-equivalence with granted `daemon-reload`+`restart`. |
| Drop `/var/lib/nginx` from folders (all five) | REVIEW-DROP | Service runtime cache; not team space. Install state kept via `ownership` (EL family). |
| Add pam_group + `nginx`/`www-data` (all five) | REVIEW-ADD | Webserver class rule: identity/read baseline + content-group. Debian caveat: `www-data` is shared — single-app servers only (REVIEW-KEEP note in the profile). |
| Add `/var/log/nginx` read (all five) | REVIEW-ADD | `/var/log` is excluded from footprints by default. |
| Add setgid content dir (`/usr/share/nginx/html` EL / `/var/www/html` Ubuntu, `root:<group>` `2775`) | REVIEW-ADD | Team writes content via the group; new files inherit it. The one intentional vendor-permission deviation — accept-list it (§8). |
| Keep `/var/lib/nginx` ownership (EL family) | as captured | Enforces install-time state; drift stays visible. |

The 2026-08-23 additions changed no decision: ubuntu-26.04's raw grant set
is byte-identical to 24.04's, and amazonlinux-2023's to almalinux-9's, so
each reviewed profile mirrors that sibling (cross-noted in its header).

## 3. Access model for this app class

Webserver: **pam_group** (identity + content-group at SSH login) +
**setgid content dir** (write with zero ongoing upkeep) + **config write
ACL** (the team writes config; the `nginx` account must not) + **log read
ACL**. See the [access model](../../concepts/access-model.md) decision
matrix.

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/nginx/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards: `/etc/sudoers.d/nginx-rg-<host>-app-restricted`
(`visudo -cf` it), the `group.conf` line mapping the AD group to
`nginx`/`www-data`, `getfacl /etc/nginx /var/log/nginx`, and the setgid
content dir. Applying is non-breaking while the team still holds
app-full (group nesting).

## 5. Verify

Verified with `scripts/verify-profile.sh nginx <distro>` (init container)
or `scripts/verify-profile-kvm.sh` (real KVM guest with SELinux/AppArmor
and real PAM — the stamp names the image): real playbook apply, probes,
real `--tags cleanup`. Current state per the profile headers: alma9
re-verified 2026-08-23 on KVM; alma10 and ubuntu 24.04 verified 2026-08-09
(EC2); **ubuntu 26.04 and al2023 are reviewed but `VERIFIED: pending`** —
run the verifier before relying on them. On a live host:

```bash
sudo -l -U <pilot>                          # exactly the scoped grants
sudo systemctl restart nginx                # allow
sudo journalctl -e -u nginx                 # allow (granted spelling)
sudo systemctl restart sshd                 # DENY
echo x | sudo tee /usr/lib/systemd/system/nginx.service   # DENY
# behavioral pam_group — FRESH ssh login:
id                                          # shows nginx / www-data
touch /usr/share/nginx/html/.probe && rm $_ # content write via group
```

A stale session is a false negative — pam_group is per-login.

## 6. Flip

Remove the team from `<hostname>-app_full` (restricted grants are already
live via nesting), `loginctl terminate-user <user>` per user,
`sss_cache -E`. Confirm on a fresh login: `id` shows no wheel, `sudo -l`
shows only the profile.

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time
(`-e '{"declarative_access_local_groups": []}'` for ACL-only); or full
revoke with the same command + `--tags cleanup`. Cleanup removes the
sudoers file, group.conf lines, and ACLs (incl. defaults). It deliberately
leaves parent-directory traverse ACLs (shared across profiles) and **never
reverts ownership** — the setgid content dir stays until you re-chown it
deliberately.

## 8. Drift and patching

`rpm -V nginx` / `dpkg --verify nginx` will flag the setgid content dir —
that is reviewed, intentional drift: record
`/usr/share/nginx/html 2775 root:nginx` (or `/var/www/html` www-data) in
the golden-baseline accept-list. ACLs are invisible to rpm/dpkg
verification. Package upgrades replace files (unit files lose nothing here
— no unit ACLs exist) and may reset package-dir modes: re-run playbook 5
after patching; it is idempotent. authselect runs can drop the pam_group
line from `/etc/pam.d/sshd` — re-run or use a custom authselect profile.

## 9. TLS: key ownership and rotation

Platform owns `/etc/pki/tls/private` / `/etc/ssl/private` (root, 0600 —
in no profile). Rotation: platform places cert+key → the **team** runs
their granted `reload` — the boundary stays clean. nginx's root master
reads the key; the `nginx` account never needs it. If a team must own the
cert dirs (edge case), use the cert-admin opt-in profile pattern from the
collection's examples — not this profile.

## 10. Logs

journalctl grants are per-unit scoping — never substitute
`systemd-journal` group membership (host-global journal read). Pre-flip
test for the rotation mask gotcha:

```bash
logrotate -f /etc/logrotate.d/nginx
getfacl /var/log/nginx/access.log   # team group present, no #effective:---
```

nginx ships a logrotate fragment with `create 0640 nginx adm` (Ubuntu) /
root-based create (EL) — both preserve group-class read for the ACL.
`[needs-runtime-confirmation]` on any host whose fragment was customized.

## 11. Known risks (from `risks[]`)

The nginx footprints carry only low/medium standard entries (root-run
master process is inherent to binding :80; worker processes drop to
`nginx`/`www-data`). No high/critical `risks[]` entries to accept or fix.
`[app-knowledge]`: the master-as-root pattern is nginx's design, not an
install defect.

## 12. Storage and growth

Install-time floor, summed from the `filesystem` block of each
`footprints/<distro>/footprint-nginx.json`:

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Install floor (all added files) | **2.7 MB** | **3.0 MB** | **2.6 MB** | **3.2 MB** | **6.5 MB** |
| Dominated by | 4 binaries, 2.6 MB | 4 binaries, 2.8 MB | 2 binaries, 2.5 MB | 2 binaries, 3.1 MB | 4 binaries, 3.2 MB + 57 gperftools/libunwind dependency libs, 3.1 MB |

Treat that as a **floor, not a forecast** — it answers "will it fit", never
"how fast will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).
`/var/log` is excluded from footprints, so no log volume is priced in here.

Growth drivers, worst first:

| Driver | Bounded? | Detail |
| --- | --- | --- |
| Content root — `/usr/share/nginx/html` (EL) / `/var/www/html` (Ubuntu) | **No** | Whatever the team writes. The unbounded path in a plain install. |
| `/var/lib/nginx` proxy/cache buffers | **No, if proxy caching is configured** | Footprint shows `tmp/` (EL) and `body,proxy,fastcgi,uwsgi,scgi` (Ubuntu). `[needs-runtime-confirmation]` — a `proxy_cache_path` in a team `conf.d` drop-in makes this unbounded, and the dir is REVIEW-DROPped (§2), so the team can neither see nor clear it. |
| `/var/log/nginx/{access,error}.log` | Yes — package fragment | `/etc/logrotate.d/nginx` is in the footprint on all five distros (byte-identical across the EL family, and across both Ubuntus). Verbose access logging still outpaces a weekly rotate. |
| journal | Yes — journald `SystemMaxUse` | nginx writes only start/exit records here. |

**Separate volume: not warranted for a plain static site** — a 3–7 MB floor
with rotated logs fits anywhere. Provision one when the team's content is
large or a `proxy_cache_path` is configured. Mount it at the app's existing
data path — the content root for content, `/var/log/nginx` for a log split.
Never invent a new path: the profile grants the old one.

Both candidate mount points are granted paths (setgid `2775` ownership on
the content root, read ACL + default ACL on `/var/log/nginx`), so a mount
silently revokes the team. Order: mount → restore owner/mode and, on EL,
the SELinux label → **re-apply playbook 5** (§4) → `getfacl` the path to
confirm the team entry is back. Full procedure:
[separate volumes: when and where](../../concepts/storage.md#separate-volumes-when-and-where).

Retention reality: file logs rotate on the shipped
`/etc/logrotate.d/nginx` fragment (create-mode detail in §10); the journal
is bounded by journald defaults. Neither is in any profile — **retention or
frequency changes are an ops request**, handled in a change window.
