# Ansible role evaluation: nginx (AlmaLinux 9/10, Ubuntu 24.04/26.04, Amazon Linux 2023)

## 1. Method

The reviewed nginx profiles and the [dev](../apps/nginx/dev.md) /
[ops](../apps/nginx/ops.md) docs are the requirement rubric; each public
role is scored on how much of that it delivers, and the shortfall becomes
the spec for our overlay. Candidates and their status were checked
2026-08-09 — Galaxy maintenance state decays, so re-verify before relying on
this.

## 2. Candidates

| Role | Backing | Status (2026-08-09) |
| --- | --- | --- |
| `geerlingguy.nginx` | Community (Jeff Geerling) | Actively maintained; ~12.6M downloads; last release 2024-09; 3 open issues |
| `nginxinc.nginx` | Vendor-official (F5/NGINX) | Maintained; supports OSS + NGINX Plus; template-driven config |
| `nginxinc.nginx_config` | Vendor-official | Companion config-only role (directive-level templating) |

## 3. Rubric scoring

| # | Requirement | geerlingguy.nginx | nginxinc.nginx |
| --- | --- | --- | --- |
| R1 | Both distro families across our five distros (EL9/10 + AL2023; Ubuntu 24.04/26.04), correct paths/unit/account | ✅ RedHat + Debian family logic; installs the vendor/package unit — the same family branches our AL2023 and 26.04 footprints confirm | ✅ broad OS matrix, incl. EL/Debian families |
| R2 | Install + configure via native mechanisms | ✅ package install + config template | ✅ package + repo setup + templated config |
| R3 | Drop-in discipline vs whole-file | ⚠️ templates the main `nginx.conf` whole-file (`templates/nginx.conf.j2`) + a vhosts template | ⚠️ directive-level templating, but still renders managed files whole |
| R4 | systemd hardening drop-ins | ❌ none | ❌ none |
| R5 | env/secret file management | ❌ n/a for nginx | ❌ n/a |
| R6 | **Access model (sudoers/pam_group/ACLs)** | ❌ none | ❌ none |
| R7 | Verify / idempotence quality | ✅ molecule, multi-distro at the family level (AL2023 / Ubuntu 26.04 were not pinned platforms at the 2026-08-09 check) | ✅ molecule, extensive (same family-level caveat) |
| R8 | TLS wiring | ⚠️ passes ssl directives through vhost config; no key lifecycle | ✅ richer TLS templating; still no key ownership/rotation model |
| R9 | logrotate policy management | ❌ relies on the package's fragment | ❌ same |
| R10 | Maintenance/assurance for our versions (EL9/10, Ubuntu 24.04/26.04, AL2023) | ✅ covers EL9/10 + noble; AL2023 and 26.04 ride the family logic — not explicitly asserted at the 2026-08-09 check | ✅ vendor-tracked; same explicit-assertion caveat for AL2023/26.04 |

## 4. Nuances

Both roles render config as managed files. Under our FIM baseline that's
acceptable **if** the rendered output is deterministic — keep
`ansible_managed` timestamp-free so the golden baseline accepts the file.
`geerlingguy.nginx`'s whole-file `nginx.conf` is the bigger footprint (any
directive change rewrites the whole file); `nginxinc.nginx_config`'s
directive model produces smaller, more reviewable diffs. Neither changes the
access story — both leave `/etc/nginx` root-owned, which is exactly what our
config-write ACL then grants the team on top of.

## 5. Verdict: **adopt + wrap**

Adopt `geerlingguy.nginx` for a simple deployment, or `nginxinc.nginx`
(+ `nginx_config`) when you need NGINX Plus or fine-grained config.

**Mandatory action before rollout on EL: set `nginx_yum_repo_enabled: false`.**
The role defaults it to `true` and installs F5's nginx.org build rather than
the AppStream package these profiles were captured against; lockdown then
fails on a path that build does not create. Ubuntu is unaffected
(`nginx_ppa_use` already defaults to `false`) — see §6b.

Wrap either with our access lifecycle — neither delivers R4/R6/R9, and that gap
is not a role defect, it's the job this library does. As with every app so
far, R6 (access model) is a clean miss across all public roles.

## 6. Implementing least privilege with this role

### 6a. Where the role runs in the lifecycle

The role runs during the **setup window** (the executor holds
`<hostname>-app_full`) or via platform automation — always **before**
capture, so everything it creates lands in the footprint exactly as a
manual install would.

| Role output | Profile key it lands in |
| --- | --- |
| Installed/enabled `nginx.service` | `declarative_access_services` |
| Templated `/etc/nginx` tree (`nginx.conf.j2`, vhost files) | config-write ACL via `declarative_access_folders_modify` |
| Content root the role serves (vhost `root:`) | the setgid `declarative_access_ownership` entry |
| Reload handler (`service: nginx state: reloaded`) | confirms `reload` belongs in the sudoers verb set |
| No timers/quadlets installed | `_timers` / `_quadlets` stay absent |

Wrap notes: **pin the role version** — a version bump can change the
rendered config set and therefore the footprint, so re-capture and
re-review on upgrade. Re-running the role post-lockdown is a platform act;
if it replaces ACL'd files, re-run playbook 5 afterward (it's idempotent).

### 6b. Configuring the deployment for least privilege

From `geerlingguy.nginx`'s own defaults and templates (2026-08-09 check;
install-source bullet added 2026-08-24 after a live lockdown failure):

- **`nginx_yum_repo_enabled: false` — set it, on EL.** This one comes first
  because it decides *which nginx you get*, and every other bullet here
  assumes the distro package. The role's default is **`true`**
  (`defaults/main.yml:6`), which adds F5's nginx.org repo in
  `tasks/setup-RedHat.yml:9` and installs
  `nginx-1.30.4-1.el10.ngx` (vendor "NGINX Packaging", 33 files) instead of
  AppStream's `nginx-1.26.3`. That is a **different install shape**, and our
  footprint was captured from the distro package — applying this profile to
  the vendor build fails on `file (/var/lib/nginx) is absent, cannot
  continue`, because the nginx.org package does not create it. Same hazard
  the [caddy eval](caddy.md) §4 names for Cloudsmith/COPR, reached by a
  default rather than a choice. Verified on alma10, 2026-08-24.
  **Ubuntu needs nothing**: `nginx_ppa_use` already defaults to `false`
  (`defaults/main.yml:12`), so the Debian family gets the archive package
  out of the box. The asymmetry is the trap — a playbook that works on
  Ubuntu will silently install a different nginx on EL.
- **Keep config root-owned.** The role renders `nginx.conf` and vhost files
  as root and never chowns `/etc/nginx` to the service account or writes
  sudoers — there is nothing to disable; just don't add your own
  `owner:`/`group:` overrides on top.
- **`nginx_user`** — leave at the family default (`nginx` on EL/AL2023,
  `www-data` on Ubuntu). The packaged system accounts are exactly what the
  profiles' pam_group and setgid grants name; a custom or login user breaks
  that mapping.
- **`nginx_vhosts[].root`** — point at the content root the profile grants
  (`/usr/share/nginx/html` EL / `/var/www/html` Ubuntu). A novel docroot
  needs a profile edit and re-review before lockdown.
- **`nginx_error_log` / `nginx_access_log`** — keep the defaults under
  `/var/log/nginx/` so the profile's log-read ACL holds; relocating logs
  silently un-grants the team.
- **`nginx_proxy_cache_path`** — leave empty (the default) unless you
  accept unbounded `/var/lib/nginx` growth: that dir is REVIEW-DROPped, so
  the team can neither see nor clear it (ops §12).
- **Determinism** — keep `ansible_managed` timestamp-free so the rendered
  whole-file config passes the FIM baseline (§4).
- **TLS** — vhost `listen: "443 ssl"` and certificate paths pass through
  role config, but the role has no key lifecycle (R8): key files stay
  root-owned in the platform dirs, which is the boundary our model wants.
- **Not expressible with this role**: systemd hardening drop-ins (R4), any
  sudoers/pam_group/ACL access model (R6 — this library's job), and
  port/capability posture beyond vhost `listen` values (nginx's root
  master binding :80 is inherent — accepted in ops §11).

`nginxinc.nginx` equivalents exist for install-source and config templating
(directive-level via `nginx_config`); the same rules apply — root-owned
rendering, packaged service account, packaged log dir.

### 6c. Applying the access profile

Once the role has deployed and capture/review is done, lockdown is one
playbook run with the distro's reviewed profile, then the verify pass and
the flip out of app-full — the full runbook is
[ops §4–§6](../apps/nginx/ops.md#4-apply).

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/nginx/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted"
# <distro>: almalinux-9 | almalinux-10 | ubuntu-24.04 | ubuntu-26.04 | amazonlinux-2023
```

### 6d. Who does what after lockdown

The **application team's** admin surface is the
[dev guide](../apps/nginx/dev.md) — "your life after lockdown": the granted
systemctl verbs and journalctl spellings, the `/etc/nginx` config-edit
paths with drop-in discipline, content and log access, and the
denied-command playbook.

The **operations team's** reference is the
[ops runbook](../apps/nginx/ops.md) — the footprint evidence, the
raw→reviewed decisions, apply/verify/revoke including the flip out of
app-full, drift handling after patching, and the `risks[]` triage.

## 7. Sources

- [geerlingguy/ansible-role-nginx (GitHub)](https://github.com/geerlingguy/ansible-role-nginx)
- [geerlingguy.nginx (Ansible Galaxy)](https://galaxy.ansible.com/geerlingguy/nginx/)
