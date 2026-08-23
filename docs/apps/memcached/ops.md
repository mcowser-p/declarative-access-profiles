# memcached — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/memcached/{almalinux-9,almalinux-10,amazonlinux-2023,ubuntu-24.04,ubuntu-26.04}-access.yml`
with their untouched `-raw.yml` siblings. Role evaluation:
[docs/role-evals/memcached.md](../../role-evals/memcached.md). Lifecycle
mechanics: [concepts/lifecycle.md](../../concepts/lifecycle.md).

memcached is the library's **minimal-case** profile: a pure in-memory cache with
no data dir, no content dir, and no log dir. The review is mostly subtraction —
the raw profile is all vendor units and SELinux/enablement noise — leaving one
service grant and one config-file ACL.

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-memcached.json` (schema 1.0,
`footprint_type: install_time`, captured 2026-08-23 on KVM golden-image VMs,
treadmark 0.11.0):

| | alma9 | alma10 | AL2023 | ubuntu 24.04 | ubuntu 26.04 |
| --- | --- | --- | --- | --- | --- |
| files added / modified | 1508 / 1856 | 1520 / 1572 | 30 / 1776 | 30 / 33 | 30 / 33 |
| Units shipped | `memcached.service` (vendor `/usr/lib` + `/lib` usr-merge symlink) | same | same | `memcached.service` (`/usr/lib` + `/lib` + apt enablement symlink in `multi-user.target.wants`) | same as 24.04 |
| Dependency-pulled units | none | none | none | none | none |
| Account created (uid/gid, shell, home) | `memcached` 992/992, `/usr/sbin/nologin`, `/` | `memcached` 991/991, `/usr/sbin/nologin`, `/` | `memcached` 992/992, `/usr/sbin/nologin`, `/` | **`memcache` 112/117**, `/bin/false`, `/nonexistent` | **`memcache` 104/111**, `/bin/false`, `/nonexistent` |
| Config file (owner:mode) | `/etc/sysconfig/memcached` `root:root 0644` (unit `EnvironmentFile`) | same | same | `/etc/memcached.conf` `root:root 0644` (wrapper reads it); also `/etc/default/memcached` (vestigial SysV) + `/etc/init.d` + `rc?.d` symlinks | same as 24.04 |
| Data dir | none (in-memory) | none | none | none | none |
| Log dir | none — logs to journal | none | none | none | none |
| Unit hardening (declared) | `PrivateTmp`, `ProtectSystem=full`, `NoNewPrivileges`, `PrivateDevices`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`; caps `CAP_SETGID,SETUID,SYS_RESOURCE`; **no `User=`** | same | same | above **plus** `MemoryDenyWriteExecute`, `ProtectKernelModules/Tunables/ControlGroups`, `RestrictRealtime`, `RestrictNamespaces`, `PIDFile=/run/memcached/memcached.pid`, `Restart=always`; **no `User=`** | same as 24.04 |
| Other install artifacts | SELinux policy module `/var/lib/selinux/…/modules/200/memcached` (`memcached-selinux`) + SELinux python tooling (`semanage`, `audit2allow`, `chcat`) + the **perl runtime** pulled for `memcached-tool` (~41 MB — the golden image ships without perl) | same **+** `…/modules/400/extra_varrun` (perl ~32 MB) | same SELinux module + tooling; **no perl payload** (already on the AL2023 golden image) | `tmpfiles.d/memcached.conf` (creates `/run/memcached`); wrapper scripts under `/usr/share/memcached` | same as 24.04 |
| `group_access` (install-created group) | **empty** — the `memcached` group owns nothing | empty | empty | empty — the `memcache` group owns nothing | empty |
| Vendor sudoers shipped | none (`privilege.sudoers_files: []`) | none | none | none | none |
| `risks[]` | 2 × `service_runs_as_root` (medium) | 2 × same | 2 × same | 3 × same | 3 × same |

The empty `group_access` is the load-bearing evidence for the **no-pam_group**
decision: on redis the service group can read the data dir, so pam_group is
dropped to avoid exposure; on memcached the service group owns *nothing* — on
any of the five distros — so pam_group is dropped because it would grant
*nothing*. Either way, no group.

Two capture notes on the numbers. The EL-family `files modified` counts
(1856/1572/1776) are the SELinux policy-store rebuild that installing
`memcached-selinux` triggers — store internals, not grants (§2). And the
alma9/alma10 `files added` counts ballooned versus the AL2023/Ubuntu cells
because those golden images ship without perl, so `memcached-tool`'s perl
dependency lands in the footprint (the earlier EC2 AMIs, like AL2023's image,
already carried it). Baseline difference, not a memcached change — and none of
it is grant-relevant (§12 for the disk cost).

## 2. Raw → reviewed: the decisions

| Change | Tag | Why |
| --- | --- | --- |
| Drop all `files_modify` (vendor units: 2 on the EL family / 3 on Ubuntu) | REVIEW-DROP | All vendor unit files + (Ubuntu) apt's `multi-user.target.wants` enablement symlink; the `/lib` path is the usr-merge symlink of the same unit. A unit-file write ACL is root-equivalent for that unit. Read-only-units profile. |
| Drop the SELinux policy-store dirs from `folders_modify` — `/var/lib/selinux/…/modules/200` + `…/modules/disabled` on all three EL-family cells, plus `…/modules/400` on alma10 only | REVIEW-DROP | The store dirs the `memcached-selinux` module landed in (the module payload is `…/200/memcached`; treadmark 0.11.0 emits the store's priority dirs where 0.10.0 emitted the module dir — same store, coarser path, same decision). A system-owned SELinux store, not team space; editing a compiled policy module by hand is never a team action (that's `semodule`/ops). |
| Add the config file to `files_modify` (`/etc/sysconfig/memcached` EL, `/etc/memcached.conf` Ubuntu) | REVIEW-ADD | Cache-class config write. The raw omitted it — the file is `root:root` with no `group_access`, so the exporter routed no grant. A file-scoped `rw` ACL for the team group (no default ACL — it's a single file). The service account gets no config write. |
| Do **not** add `/var/log/memcached` to `folders_read` | REVIEW note (no delta) | Memcached logs to the journal only; the install creates no log dir. The generic `/var/log/<app>` REVIEW-ADD rule is deliberately skipped — there is nothing to grant. Journal reads come via the `journalctl -u` sudoers grants. |
| Do **not** add pam_group | REVIEW note (no delta) | Cache class; the `memcached`/`memcache` group owns nothing on disk, so membership grants nothing. Opt-in remains at apply time (§3) for a future need. |
| No `ownership` entries | as captured | The install creates no memcached-owned directories (account + group only; config is `root:root`, no data/log dir), so there is no install-time owner/mode state to pin. |

Result: a four-key profile (`profile_name`, `sudo`, `services: [memcached]`,
`files_modify: [<the one config file>]`). The three EL-family reviewed grant
sets (alma9, alma10, AL2023) are identical (`/etc/sysconfig/memcached`), as are
the two Ubuntu ones (`/etc/memcached.conf`); within each family the files
differ only in provenance and the per-capture drop comments.

## 3. Access model for this app class

**cache** — and memcached is the degenerate, most-minimal instance of it:

- **scoped service control** (sudoers) on the one unit `memcached.service`;
- **config write ACL** on the single tuning file — the team edits config, the
  service account does not gain config write;
- **journal reads** via the `journalctl -u memcached` sudoers grants (no log-file
  ACL — there is no log file);
- **NO pam_group**, **NO content dir**, **NO data dir**. See the [access model
  decision matrix](../../concepts/access-model.md) — memcached exercises only the
  service-control + config-ACL rows.

The group option is available for a team that later finds a concrete need (there
is none today), enabled at apply time:

```bash
ansible-playbook ... -e @profiles/memcached/<distro>-access.yml \
  -e enable_pam_group=true \
  -e '{"declarative_access_local_groups":["memcached"]}' \
  -e "group_name=<hostname>-app_restricted"      # use "memcache" on Ubuntu
```

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/memcached/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/memcached-rg-<host>-app-restricted` — `visudo -cf` it;
- `getfacl /etc/sysconfig/memcached` (`/etc/memcached.conf` on Ubuntu) — team
  group present with `rw-`; **no `default:` entries** (it's a file, not a dir);
- **no `group.conf` line** — this profile has no pam_group (unless the §3 opt-in
  was used);
- **no ownership changes** — nothing was re-chowned.

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Verify with `scripts/verify-profile.sh memcached <distro>` (init container) or
`scripts/verify-profile-kvm.sh --app memcached` (real KVM golden-image guests —
the substrate the `# VERIFIED:` stamps name); both do a real playbook apply,
probes, and a real `--tags cleanup`. All five profiles are **pending** against
the 2026-08-23 KVM capture. On a live host, as a user holding only
app-restricted:

```bash
sudo -l -U <pilot>                              # exactly the scoped grants
sudo systemctl restart memcached                # allow (WARNING: flushes the cache)
sudo journalctl -e -u memcached                 # allow (granted spelling)
echo "# probe" >> /etc/sysconfig/memcached      # allow — config write via ACL (Ubuntu: /etc/memcached.conf)
sudo systemctl restart sshd                     # DENY
echo x | sudo tee /usr/lib/systemd/system/memcached.service   # DENY (read-only units)
```

There is **no behavioral pam_group check** — this profile grants no group
membership, so the "fresh SSH login / `id`" step and its stale-session false
negative do not apply. The behavioral check that matters: after a profile-scoped
`restart`, memcached serves again (`echo -e 'stats\r' | nc 127.0.0.1 11211 | head`
returns stats, or `memcached-tool 127.0.0.1:11211` on Ubuntu). Confirm the
privilege drop actually happened: `ps -o user= -C memcached` shows
`memcached`/`memcache`, not `root` (see §11).

## 6. Flip

Remove the team from `<hostname>-app_full` (restricted grants are already live via
nesting), `loginctl terminate-user <user>` per user, `sss_cache -E`. Both are
required — the host-level `app-full → wheel` (Ubuntu: `sudo`) pam_group mapping
persists in open sessions and the SSSD cache otherwise. Confirm on a fresh login:
`id` shows no `wheel`/`sudo`, `sudo -l` shows only the profile.

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time (e.g.
`-e '{"declarative_access_services":[]}'` to revoke service control, or add the
pam_group opt-in from §3); or full revoke with the same command +
`--tags cleanup`. Cleanup removes the sudoers file and the file ACL on the config
file. It deliberately leaves parent-directory traverse ACLs (shared across
profiles) and **never reverts ownership** — but this profile changed no ownership,
so there is nothing to un-revert. No linger and (barring the §3 opt-in) no
`group.conf` line exist to clean up.

## 8. Drift and patching

This profile introduces **no ownership deviation** from vendor packaging (no
setgid dir, no re-chown), so `rpm -V memcached` / `dpkg --verify memcached` flag
**nothing new from us** — unlike the webserver profiles' setgid content root. The
only grant that exists is a single file ACL, and ACLs are invisible to
`rpm -V`/`dpkg --verify`.

Package upgrades replace the config file and reset its mode, **shedding the file
ACL** — re-run playbook 5 after patching; it is idempotent. `authselect
apply-changes` can drop the host-level pam_group line from `/etc/pam.d/sshd` (the
`app-full → wheel` mapping, not this app — this app has no pam_group) — re-run or
use a custom authselect profile.

## 9. TLS: key ownership and rotation

memcached ships **no TLS** in its default configuration `[app-knowledge]`, and
whether the packaged binary even supports it (`-Z` / `--enable-ssl`) depends on
build flags — confirm with `memcached -h | grep -i ssl`
`[needs-runtime-confirmation]`. If a deployment does enable TLS:

- the cert/key are referenced from the config file via `-o ssl_chain_cert=…,ssl_key=…`
  and live in the platform key dir (`/etc/pki/tls/private` / `/etc/ssl/private`),
  **never in this profile**;
- memcached drops to the `memcached`/`memcache` account at startup, so it reads
  the key as that service account — the key must be made readable by it (group or
  ACL), not left `0600 root:root`, or TLS start-up fails;
- rotation stays split: **platform** places the new cert+key readable by the
  service account; **the team** runs their granted `systemctl restart` (no
  graceful reload — expect the cache-flush outage from the dev guide §2). No
  cert-admin opt-in profile is needed; the team never owns the cert dirs. See
  [tls-ssl.md](../../concepts/tls-ssl.md).

For most memcached deployments the operative "TLS-equivalent" control is the bind
address (`-l`) plus a firewall, not certificates — see §11.

## 10. Logs

journalctl grants are per-unit scoping — never substitute `systemd-journal` group
membership (host-global journal read).

- **Default (all five distros):** memcached logs to **stderr → the journal**;
  there is **no log file and no `/etc/logrotate.d/memcached` fragment**, so the
  file-ACL + logrotate-`create`-mode mask machinery in
  [concepts/logging.md](../../concepts/logging.md) does not apply. This profile
  correctly grants no `/var/log` read.
- **If an install role turned file logging on:** both geerlingguy.memcached and
  robertdebock.memcached template `logfile /var/log/memcached.log` by default
  (see [role-evals/memcached.md §6b](../../role-evals/memcached.md)). That creates
  a plain `root:root` file at `/var/log/memcached.log` (a *file* in `/var/log`,
  not a `/var/log/memcached` dir) with **no logrotate** — it grows unbounded and
  is not in this profile. If you accept that model, re-review to add a
  `files_read` ACL on the file and a logrotate policy; otherwise strip the role's
  `logfile` default (§6b of the eval) and keep journald logging.

## 11. Known risks (from `risks[]`)

Every capture reports the same finding — `service_runs_as_root` (severity
**medium**), one per unit path (2 on each EL-family capture, 3 on each Ubuntu
capture, which also counts the enablement symlink):

| Risk | Severity | Decision | Owner |
| --- | --- | --- | --- |
| `memcached.service` has **no `User=` directive; runs as root** | medium | **Accept** — this is memcached's standard privilege-drop design, not an install defect. systemd starts the process as root; memcached then drops to `${USER}` (`memcached`/`memcache`) via its own `-u` flag using `CAP_SETUID`/`CAP_SETGID` after binding the port. Do **not** "fix" by adding `User=` to the vendor unit — that fights the `-u` drop and is a root-equivalent unit edit outside the team's (read-only-units) grant. | platform |

Install-time capture cannot observe the *running* uid, so the effective drop is
`[needs-runtime-confirmation]`: verify on the host with `ps -o user= -C memcached`
(expect `memcached`/`memcache`, not `root`). If it shows `root`, the config's
`USER`/`-u` was cleared — that is a real finding to fix in the config file.

Two standing `[app-knowledge]` notes for the reviewer's record (not in `risks[]`):

- **No authentication in the classic protocol.** memcached has no auth by default
  (SASL is an optional, non-default build/config feature), so the **bind address
  is the security boundary** — keep `-l` on `127.0.0.1`/a firewalled interface.
  The default bind depends on the shipped config `[needs-runtime-confirmation]`
  (EL's default `OPTIONS` vs Debian's `-l 127.0.0.1` in `/etc/memcached.conf`).
- **Restart flushes the cache.** memcached has no persistence; any
  config-change restart discards all cached data and returns cold.

## 12. Storage and growth

**Install floor (evidence).** Summed added-file sizes from
`footprints/<distro>/footprint-memcached.json` (§1). Treat it as a **floor, not
a forecast** — the sizing rule in
[Storage & growth](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)
applies in full: the capture sees what the installer wrote, never what the
service accumulates.

| | alma9 | alma10 | AL2023 | ubuntu 24.04 | ubuntu 26.04 |
| --- | --- | --- | --- | --- | --- |
| Install floor (all added files) | **42.4 MB** (1508 files) | **33.3 MB** (1520 files) | **0.8 MB** (30 files) | **1.2 MB** (30 files) | **1.7 MB** (30 files) |
| Dominated by | **the perl runtime** (41.6 MB — pulled for `memcached-tool`); `memcached` itself 0.25 MB | **perl** (32.5 MB); `memcached` 0.27 MB | `memcached` 0.29 MB + SELinux python tooling 0.19 MB | **`libevent` 0.33 MB** + `memcached` 0.26 MB | `memcached` **0.49 MB** + `libevent` 0.33 MB |
| Data directory | **N/A on alma9 — none (in-memory)** | **N/A on alma10 — same** | **N/A on AL2023 — same** | **N/A on ubuntu 24.04 — same** | **N/A on ubuntu 26.04 — same** |
| Bytes under `/var/log` | 0 | 0 | 0 | 0 — no log dir, no log file | 0 |

memcached itself is still the **smallest app in the library** — on AL2023 and
Ubuntu the whole install is 0.8–1.7 MB, well under nginx's ~2.8 MB — but the
alma9/alma10 cells now carry a **dependency tail ~100× the app**: those golden
images ship without perl, so `memcached-tool`'s perl requirement drags the full
runtime into the footprint (the earlier EC2 AMIs and the AL2023 image already
had perl in the baseline, which is why AL2023 stays at 30 files). A floor is a
property of app **and** baseline; quote the pair, not the app alone. Two more
things inside the numbers: each usr-merge alias is counted separately
(`/bin/memcached` and `/usr/bin/memcached` are the same file — likewise the
perl `.so`s), so the de-duplicated cost is roughly half; and ubuntu 26.04 is
larger than 24.04 only because its `memcached` binary roughly doubled. The EL
`/var/lib/selinux/...` entries are the compiled policy module and its store
dirs, REVIEW-DROPped in §2 — **not** a data dir, and static.

**What grows.**

| Driver | Grows? | Detail |
| --- | --- | --- |
| Cache contents | **Nothing on disk** | Pure RAM, no persistence. The bound is `CACHESIZE` (EL) / `-m` (Ubuntu); at the ceiling memcached evicts LRU rather than growing `[app-knowledge]`. Capacity planning here is a **memory** exercise, not a disk one. |
| Journal (`memcached.service`) | Bounded | journald's `SystemMaxUse` default; unbounded only if an operator raised the cap. |
| App log files | **None by default** | No log file and **no `/etc/logrotate.d/memcached`** in any of the five captures (§1, §10). |
| `/var/log/memcached.log`, if an install role enabled file logging | **Unbounded** | `root:root`, no logrotate, not in the profile (§10). The **only realistic way memcached fills a disk** — and it comes from the role, not the package. |
| `/run/memcached` (Ubuntu `tmpfiles.d`) | None on disk | tmpfs; PID file only. |

**Do not provision a data volume for memcached.** There is no data path to
mount one at — no data dir, no content root, nothing on disk to separate. The
only disk this app can consume belongs to a log sink that does not exist by
default:

| Situation | Mount at | Why |
| --- | --- | --- |
| Default, all five distros | **Nothing — no volume warranted** | Journal-only; the app writes no files after install |
| A role enabled file logging (§10) | the host's `/var/log`, if anything | A host-wide sizing decision, not a memcached one — a single flat file is not a mount point. Prefer fixing the role default. |
| extstore in use (`-o ext_path=…`) | the path named in `ext_path` — and add it to the profile | `[app-knowledge]` memcached's SSD-backed extstore is the one configuration that gives it a real data path. Whether the packaged binary supports it is `[needs-runtime-confirmation]`. Note the access consequence: `ext_path` is set in the team's **granted config file**, so a team can point extstore at a disk with no ops involvement — re-review if it is ever enabled. |

**Mount → re-apply → `getfacl`, in that order.** The full ordering is in
[the mount trap in Storage & growth](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it).
For memcached the trap is close to theoretical — the only granted path is a
single config **file** under `/etc`, and nobody mounts a volume there. The same
ACL is genuinely fragile for a different reason, though: a **package upgrade**
replaces the config file and sheds the ACL (§8). The fix is identical and
idempotent either way:

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/memcached/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
getfacl /etc/sysconfig/memcached   # EL — team group rw-, no default: entries
getfacl /etc/memcached.conf        # Ubuntu
```

**Retention reality.** No logrotate fragment ships on any distro, because there
is no log file to rotate (§10) — retention here is entirely **journald's**
(`SystemMaxUse` and friends in `/etc/systemd/journald.conf`, host-global and in
no profile). A host built with the role's `logfile` default instead gets a file
with **no** rotation policy at all, and needs one written. Either way — a
journald limit or a new logrotate fragment — **retention changes are an ops
request**, handled in a change window.
