# HAProxy — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/haproxy/{almalinux-9,almalinux-10,ubuntu-24.04}-access.yml` with
their untouched `-raw.yml` siblings. Role evaluation:
[docs/role-evals/haproxy.md](../../role-evals/haproxy.md). Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

The one-line summary: HAProxy's proxy-class defaults collapse under the
evidence. It runs as **root**, its service group owns **nothing**, and it serves
**no content**, so the reviewed profile is just **service control + a config
write ACL on `/etc/haproxy`** — the cache/minimal shape, not the full
webserver/proxy shape. The reasoning is §2/§3.

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-haproxy.json` (schema 1.0, `install_time`,
captured 2026-08-09 on EC2 AMIs, treadmark 0.10.0 feature branch):

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| files added / modified | 39 / 37 | 39 / 43 | 36 / 33 |
| Units installed | `haproxy.service` (vendor: `/usr/lib` + `/lib`) | same | `haproxy.service` (vendor `/usr/lib`+`/lib` + enablement symlink — apt auto-started it) |
| Runs as | root (no `User=` in unit) | root (no `User=`) | root (no `User=`) |
| Account created | `haproxy` uid 993, gid 993, `/usr/sbin/nologin` | `haproxy` uid 992, gid 992, nologin | `haproxy` uid 111, gid 114, nologin |
| Group created | `haproxy` gid 993 — **0 members** | `haproxy` gid 992 — **0 members** | `haproxy` gid 114 — **0 members** |
| `group_access[]` | **`[]`** (group owns nothing) | **`[]`** | **`[]`** |
| Config | `/etc/haproxy` (root:root 0755) → `haproxy.cfg` 0644 + `conf.d/` 0755 | same | `/etc/haproxy` → `haproxy.cfg` 0644 + `errors/` (vendor pages); **no `conf.d`** |
| State dir | `/var/lib/haproxy` root:root 0755 | same | `/var/lib/haproxy` + `dev/log` 0666 (chroot syslog socket) |
| Env file | `/etc/sysconfig/haproxy` | `/etc/sysconfig/haproxy` | `/etc/default/haproxy` |
| Logging install | logrotate frag only; **no rsyslog fragment** | same | logrotate + **`/etc/rsyslog.d/49-haproxy.conf` → `/var/log/haproxy.log`** |
| Vendor sudoers shipped | none (`sudoers_files: []`) | none | none |
| `risks[]` | 2 × `service_runs_as_root` (medium) | 2 × `service_runs_as_root` | 3 × `service_runs_as_root` |

Two evidence facts drive the whole review: the `haproxy` **group has no members
and an empty `group_access[]`** (nothing on disk is group-owned to it), and the
unit has **no `User=`** so the daemon is root. Ubuntu's footprint carries
first-start side effects (apt auto-starts; EL/dnf does not) — the enablement
symlink, the `init.d` + `rc?.d` SysV compat shims, and `/var/lib/haproxy/dev/log`
— which is better evidence, not noise, but means the raw profiles aren't
line-comparable across distros.

## 2. Raw → reviewed: the decisions

| Change | Tag | Why |
| --- | --- | --- |
| Drop all `files_modify` (EL: 2 unit paths; Ubuntu: 3 incl. enablement symlink) | REVIEW-DROP | Vendor units + apt's symlink; a unit-file write ACL is root-equivalent for the unit — and here literally so: no `User=`, so the daemon is root. Read-only-units profile. |
| Drop proxy-class **pam_group** + `local_groups: [haproxy]` | REVIEW-DROP | The `haproxy` group has 0 members and `group_access: []`; `/etc/haproxy` and `/var/lib/haproxy` are both `root:root`. Membership grants a human nothing. Omitted rather than granting a no-op. |
| Drop proxy-class **setgid content dir** | REVIEW-DROP | HAProxy serves no content root. Error pages (`/usr/share/haproxy/*.http` EL; `/etc/haproxy/errors/` Ubuntu) are `root:root` package files, not team content. |
| Keep `/etc/haproxy` in `folders_modify` | REVIEW-KEEP | Config write ACL — the one grant the team actually needs. Kept despite the TLS caveat (§9): a PEM bundle under `/etc/haproxy/certs` would fall inside it. |
| Drop `/var/lib/haproxy` from `folders_modify` | REVIEW-DROP | HAProxy's chroot/state dir (`root:root`); the daemon owns it, the team never writes here. |
| Drop class-default `/var/log/haproxy` read grant | REVIEW-DROP | No app log dir exists — HAProxy logs via syslog (Ubuntu → flat file `/var/log/haproxy.log`; EL → nothing shipped). A flat-file ACL wouldn't survive rotation; the journal covers health (§10). |

Result: a four-key profile (`profile_name`, `sudo`, `services: [haproxy]`,
`folders_modify: [/etc/haproxy]`). EL9 and EL10 reviewed files are identical;
Ubuntu differs only in provenance and the enablement-symlink drop.

## 3. Access model for this app class

Nominally **proxy**, but read the [access model](../../concepts/access-model.md)
decision matrix against the evidence and every row but config collapses:

| Class default (proxy) | Applied here? | Evidence |
| --- | --- | --- |
| pam_group into service group | **No** | `haproxy` group: 0 members, `group_access: []` |
| setgid content dir (`2775`) | **No** | no content root; error pages are vendor `root:root` |
| config write ACL | **Yes** | `/etc/haproxy` `root:root` → team ACL |
| log read ACL | **No** (default) | syslog-routed; no app log dir; ops adds a dir grant if a site configures one |

So HAProxy lands on the **config-scoped / cache-minimal** model: scoped sudoers
for the unit + the journal, one config ACL, read-only units. The pam_group
option still exists at apply time
(`-e '{"declarative_access_pam_group": true, "declarative_access_local_groups": ["haproxy"]}'`)
for a team that wants group identity, but on stock HAProxy it buys nothing —
prefer to leave it off.

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/haproxy/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/haproxy-rg-<host>-app-restricted` — `visudo -cf` it; expect the
  `systemctl` verb set + `journalctl -u haproxy` spellings + `daemon-reload`.
- `getfacl /etc/haproxy` — team group has `rwx` and a matching `default:` entry.
- **No** `group.conf` line, **no** ownership changes, **no** setgid dir — this
  profile has none. If you see a `group.conf` fragment for haproxy, someone
  applied the pam_group opt-in; confirm that was intended (§3).

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Verify with `scripts/verify-profile.sh haproxy <distro>` (init container, real
playbook apply, probes, real `--tags cleanup`). On a live host, as a user who
holds **only** app-restricted:

```bash
sudo -l -U <pilot>                              # exactly the scoped grants, no more
sudo systemctl reload haproxy                   # allow (seamless)
sudo journalctl -e -u haproxy                   # allow (granted spelling)
vi /etc/haproxy/conf.d/probe.cfg                # allow — config ACL (EL); Ubuntu: haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg          # allow (no sudo; parses only)
sudo systemctl restart sshd                     # DENY
echo x | sudo tee /usr/lib/systemd/system/haproxy.service   # DENY (read-only units)
id                                              # should NOT list haproxy (no pam_group)
```

The config ACL is a direct AD-group ACL, not pam_group, so there is **no
per-login false-negative** for config writes — but confirm `id` does *not* show
the `haproxy` group, which proves the pam_group drop took (a stray group.conf
line would show up here after a fresh login). Behavioral check: after a
profile-scoped `reload`, HAProxy comes back and answers on its frontends.

## 6. Flip

Remove the team from `<hostname>-app_full` (restricted grants are already live
via nesting), `loginctl terminate-user <user>` per user, `sss_cache -E`. Confirm
on a fresh login: `id` shows no `wheel`, `sudo -l` shows only the haproxy
profile. See [lifecycle](../../concepts/lifecycle.md) for why both the session
terminate and the cache flush are required.

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time; or full revoke
with the same command + `--tags cleanup`. Cleanup removes the sudoers file and
the ACLs (access + default) on `/etc/haproxy`. This profile sets **no**
ownership and **no** pam_group, so the two usual cleanup exceptions barely
apply here — but the general rules hold: parent-directory traverse ACLs (e.g.
on `/etc`) are shared across profiles and are left in place, and ownership is
never reverted (there's none to revert). If you *did* apply the pam_group
opt-in, cleanup also removes its `group.conf` line.

## 8. Drift and patching

`rpm -V haproxy` / `dpkg --verify haproxy` find nothing to flag from this
profile — it makes **no** ownership or setgid changes (the one place web-server
profiles create reviewed drift). The config ACL is invisible to rpm/dpkg
verification (ACLs aren't packaged metadata). Package upgrades replace files and
**shed the config ACL** on `/etc/haproxy` — re-run playbook 5 after patching; it
is idempotent. There is no pam_group line to worry about, so the authselect
caveat (regeneration dropping the `pam_group.so` line) does not apply to this
profile as written; it *would* apply if you enable the pam_group opt-in.

## 9. TLS: key ownership and rotation

HAProxy reads a **single PEM bundle** (cert + chain + **private key**
concatenated) — unlike nginx/httpd, the key is inside the file the process
reads. The boundary still holds, but placement is the trap:

- Keep the bundle in the platform key dir — `/etc/pki/tls/private/` (EL) /
  `/etc/ssl/private/` (Ubuntu), `root:root 0600` — referenced by absolute path
  from the config. It stays in **no** profile.
- Do **not** let it land under `/etc/haproxy/certs`: that path is inside the
  team's config write ACL (§2, REVIEW-KEEP), which would make the private key
  team-readable — the one grant the model refuses to make implicitly.

Rotation keeps the standard split: **platform places** the new PEM in the key
dir, **the team runs** their granted `systemctl reload haproxy` (seamless
master-worker reload — no outage). If a site genuinely must keep certs under
`/etc/haproxy`, that's a cert-admin boundary decision — exclude the cert subdir
from the team ACL at review; do not fold it into this profile. See
[concepts/tls-ssl.md](../../concepts/tls-ssl.md).

## 10. Logs

journalctl grants are per-unit scoping — never substitute `systemd-journal`
group membership (host-global journal read). What's different about HAProxy: it
has **no application log directory**, so there is usually **no log-dir ACL to
test**.

- **Health** is in the journal (`journalctl -u haproxy`) — granted.
- **Traffic logs** depend on syslog routing:
  - **Ubuntu:** the package's `/etc/rsyslog.d/49-haproxy.conf` writes the flat
    file `/var/log/haproxy.log`. This profile does **not** grant it: a file ACL
    there dies on the first rotation, because logrotate creates the fresh
    `/var/log/haproxy.log` in `/var/log`, which has no default ACL for the team
    (the inheritance mechanic in [concepts/logging.md](../../concepts/logging.md)
    needs a *directory* grant).
  - **EL:** no rsyslog fragment ships — traffic logging is unconfigured until a
    site sets it up.
- **To grant file reads rotation-safely,** a site routes HAProxy to a dedicated
  log **dir** (e.g. rsyslog target `/var/log/haproxy/haproxy.log`), and ops adds
  that dir to `folders_read`. Then run the standard pre-flip test:

  ```bash
  logrotate -f /etc/logrotate.d/haproxy
  getfacl /var/log/haproxy/haproxy.log   # team group present, no #effective:---
  ```

  `/etc/logrotate.d/haproxy` stays outside the grant — retention changes are an
  ops request.

## 11. Known risks (from `risks[]`)

| Risk | Severity | Decision | Owner |
| --- | --- | --- | --- |
| `service_runs_as_root` — `haproxy.service` has no `User=` (one entry per unit-file path: 2 on EL, 3 on Ubuntu) | medium | **Accept** — this is HAProxy's design, not an install defect. The master runs as root to bind privileged ports and `chroot`, then drops workers to the `haproxy` user/group via the `user`/`group` directives in `haproxy.cfg`'s `global` section `[app-knowledge]`. | app team + ops |

The review consequence of "runs as root" is already baked in: dropping every
`files_modify` on the unit files (§2) matters *more* here than for a
privilege-dropping daemon, because a unit-file write ACL on a root service is
unqualified root. No high/critical `risks[]` entries to remediate. To *reduce*
the accepted risk, a site can add a systemd hardening drop-in
(`NoNewPrivileges`, `ProtectSystem`, capability bounding) — that's a change-window
task and a candidate for the org overlay in
[the role evaluation](../../role-evals/haproxy.md).

## 12. Storage and growth

**Install floor (evidence).** Summed added-file sizes from
`footprints/<distro>/footprint-haproxy.json` (§1). Treat it as a **floor, not a
forecast** — the sizing rule in [Storage & growth](../../concepts/storage.md)
applies in full: the capture sees what the installer wrote, never what the
service accumulates.

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Install floor | **6.7 MB** (39 files added) | **6.8 MB** (39 added) | **7.5 MB** (36 added) |
| Nearly all of it | 8 binary paths — `haproxy` 3.3 MB, plus `halog`/`iprange`/`ip6range` | 8 binary paths — `haproxy` 3.3 MB | 6 binary paths — `haproxy` 3.6 MB, plus `halog` |
| Data directory | **N/A on alma9 — none; `/var/lib/haproxy` is an empty chroot dir** | **N/A on alma10 — same** | **N/A on ubuntu — `/var/lib/haproxy` holds only `dev/log`, the 0666 chroot syslog socket** |
| Bytes under `/var/log` | 0 | 0 | 0 — the rsyslog fragment ships, the log file does not exist until traffic |

Quote those numbers as-is, but know what is inside them: each usr-merge alias is
counted separately (`/sbin/haproxy` and `/usr/sbin/haproxy` carry the same
sha256), so the de-duplicated on-disk cost is roughly half. The floor is the
conservative figure — and the thing that actually grows contributes **zero** to
it.

**What grows.**

| Driver | Grows? | Detail |
| --- | --- | --- |
| Journal (`haproxy.service`) | Bounded | journald's `SystemMaxUse` default; unbounded only if an operator raised the cap |
| Traffic log — Ubuntu | **Unbounded between rotations** | `/etc/rsyslog.d/49-haproxy.conf` → `/var/log/haproxy.log`, on the **root filesystem**; `option httplog` on a busy frontend is the volume driver `[app-knowledge]` |
| Traffic log — EL | Not yet | **N/A on alma9/alma10 — no rsyslog fragment ships (§1)**; journal only until a site configures a syslog target |
| Data / content | **None** | no data dir, no content root (§2) — HAProxy proxies, it does not store |
| State dir `/var/lib/haproxy` | **None by default** | chroot dir, empty at install; grows only if a site enables a server-state file or stick-table persistence `[app-knowledge]` |
| Sockets, stats, stick tables | None on disk | `/run` is tmpfs; stick tables live in memory `[app-knowledge]` |

**Do not provision a data volume for HAProxy.** There is no data path to mount
one at. `/var/lib/haproxy` is the chroot, not a dataset — mounting over it hides
the `dev/log` socket the chroot needs on Ubuntu and buys nothing on EL. The only
thing that grows here is the log sink, so the only volume question is a **log**
volume, and only where a site configured file logging:

| Situation | Mount at | Why |
| --- | --- | --- |
| Ubuntu default (flat `/var/log/haproxy.log`) | the host's `/var/log`, if anything | a host-wide sizing decision, not an HAProxy one — a single file is not a mount point |
| Site routed HAProxy to a dedicated log dir (§10) | `/var/log/haproxy` — that directory | it is the path in `folders_read`, so the grant keeps working |
| EL default | **N/A on alma9/alma10 — no file logging configured; nothing to mount** | — |

**Mount → re-apply → `getfacl`, in that order.** Any mount at or above a granted
path (`/etc/haproxy`, or a `/var/log/haproxy` dir grant if §10 added one) hides
the ACLs beneath it with no error anywhere. Follow the ordering in
[the mount trap in Storage & growth](../../concepts/storage.md) — mount, restore
ownership/mode and, on EL, the SELinux label, then re-apply, then verify. The
realistic version for HAProxy is a `/var/log` volume added after handover, which
silently kills a log-dir grant:

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/haproxy/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
getfacl /etc/haproxy       # team group rwx + matching default: entry
getfacl /var/log/haproxy   # only if §10 added the dir grant
```

**Retention is an ops request.** All three distros ship
`/etc/logrotate.d/haproxy` (307 B on EL, 221 B on Ubuntu), but on EL it rotates
a file nothing writes — no rsyslog fragment ships. The footprint records the
fragment, not its contents, so its `rotate`/`size` values are
`[needs-runtime-confirmation]`: read the file on the host before promising a
retention number. The fragment, journald's limits, and alert thresholds are all
`root:root`, in **no** profile, and change only through the window in
[lifecycle](../../concepts/lifecycle.md). What the team owes back is early
warning and an honest growth estimate at handover.
