# Ansible role evaluation: Caddy (AlmaLinux 9/10, Ubuntu 24.04/26.04)

## 1. Method

The reviewed caddy profiles (`profiles/caddy/*-access.yml`) and the
[dev](../apps/caddy/dev.md)/[ops](../apps/caddy/ops.md) docs are the
requirement rubric; a public Ansible role is scored on how much of it the
role delivers, reading the role's **actual tasks/defaults**, not its
README. What no role delivers becomes the spec for the org overlay.
Candidates web-checked **2026-08-23**; rows resting on unread code are
marked `[needs-verification 2026-08-23]`. amazonlinux-2023 is outside the
requirement set (matrix N/A — no EPEL support and caddy not in core
repos), but it reappears in §5 as the one place a role earns its keep.

## 2. Candidates

| Role | Backing | Status (checked 2026-08-23) |
|---|---|---|
| [caddy_ansible.caddy_ansible](https://github.com/caddy-ansible/caddy-ansible) | Community org (155★, 336 commits) — the dominant Galaxy result | Not archived, but **last push 2025-04-13 (~16 months)**; molecule/Docker CI whose documented example targets `ubuntu2004` — none of our five cells assured. Installs a **GitHub-release binary**, not a package (§4). |
| [maxhoesel.caddy](https://github.com/maxhoesel-ansible/ansible-collection-caddy) (collection; `caddy_server` role) | Community (24★) | **Active — last push 2026-08-19.** Installs from caddy's **vendor repos** (Cloudsmith apt / Fedora COPR). Platform list stops at "CentOS 8-compatible (Rocky/Alma)" and Ubuntu 18.04+; alma9/10 and ubuntu 24.04/26.04 support plausible but unlisted `[needs-verification 2026-08-23]`. Default config mode is **JSON via the admin API** (§4). |
| geerlingguy.\* / linux-system-roles.\* / vendor-official | — | **None exists for caddy.** Geerling has no caddy role, linux-system-roles has none, and the caddy project's official distribution is packages/binaries only (no Ansible role) — 2026-08-23 search. |
| atosatto, samdoran, angristan, iancleary, simplificator, capitanh caddy roles | Community | Niche/single-maintainer; several Debian-only or binary-download variants of the same patterns; not evaluated in depth. |

## 3. Rubric scoring (requirements from our profile + docs)

| # | Requirement (from the reviewed profile / docs) | caddy_ansible | maxhoesel.caddy |
|---|---|---|---|
| R1 | Four active cells correct — EPEL layout on EL (`/etc/caddy` + `Caddyfile.d`, `caddy:caddy`, vendor units), universe layout on Ubuntu (single `Caddyfile`) | ❌ replaces the packaged layout wholesale: binary in `/usr/local/bin`, **default user `www-data`**, home `/home/caddy`, its own unit in `/etc/systemd/system` | ⚠️ package layout preserved, but from **vendor repos, not EPEL/universe** — different provenance than our footprints (§4) |
| R2 | Install + configure via native package/config mechanisms | ❌ `get_url` from GitHub releases + `setcap` on the binary | ✅ apt/dnf via the vendor's Cloudsmith/COPR repos |
| R3 | Drop-in discipline or deterministic whole-file template (FIM: timestamp-free) | ⚠️ whole-file `Caddyfile` template, no `ansible_managed` (deterministic but unmarked) | ⚠️ Caddyfile mode templates the whole file; the **default JSON-API mode keeps config out of the filesystem baseline entirely** (§4) |
| R4 | systemd hardening drop-ins | ⚠️ its *own* templated unit carries `NoNewPrivileges` + capability controls — hardening exists, but as a replacement unit, not a drop-in on the vendor unit | ❌ none documented `[needs-verification 2026-08-23]` |
| R5 | Env/secret file management | ⚠️ `caddy_environment_files` / `caddy_environment_variables` vars | ❌ none documented `[needs-verification 2026-08-23]` |
| R6 | **Access model** — scoped sudoers, pam_group decision, ACLs | ❌ | ❌ (the standing all-roles-fail row; this library's job) |
| R7 | Verification / idempotence (molecule, our four cells) | ⚠️ molecule/Docker exists; documented distro example is `ubuntu2004`, repo idle since 2025-04 — assume none of our cells covered | ⚠️ CI active; exact matrix unread `[needs-verification 2026-08-23]`; alma10/ubuntu 26.04 certainly unassured |
| R8 | TLS wiring under our doctrine (automatic HTTPS; static keys via user-scoped ACL, ops §9) | ⚠️ relies on caddy's automatic HTTPS (correct); adds its own `/etc/ssl/caddy` 0770 store; no static-key placement opinion | ⚠️ config-level TLS only; no key-placement opinion |
| R9 | Log policy (caddy self-rolls; file logs are an ops re-review, ops §10) | ⚠️ creates `/var/log/caddy` 0775 but defaults `caddy_log_file: stdout` (journald — matches our model); no rotation mgmt (caddy self-rolls) | ❌ nothing |
| R10 | Maintenance & platform assurance for OUR versions (alma9/10, ubuntu 24.04/26.04) | ❌ 16 months idle at eval date; CI era predates all four cells | ⚠️ active (2026-08-19) but our exact versions unlisted `[needs-verification 2026-08-23]` |

R6 fails for both — as for every app in this library. The caddy-specific
result is harsher than usual: **R1/R2 fail or bend for both candidates**,
because neither installs the thing our footprints captured.

## 4. Nuances found

**No public role reproduces the packaged install our footprints capture.**
Our four cells are EPEL (EL) and universe (Ubuntu) packages: vendor units
in `/usr/lib/systemd/system`, `caddy:caddy` account, `/var/lib/caddy`
0750, EL's `Caddyfile.d` and SELinux customizations. caddy_ansible ships a
GitHub binary + its own unit + `www-data` by default; maxhoesel installs
from Cloudsmith/COPR (newer caddy, third-party repo trust, different
package payload). Adopting **either** role produces a *different
footprint* — the profiles in this repo would be applied to evidence they
were not reviewed against. Role adoption therefore forces re-capture and
re-review, for zero install-side gain over one native package task.

**caddy_ansible embodies the config-ownership anti-pattern.** Its tasks
create `/etc/caddy` `0770` and the Caddyfile `0640` **owned by the service
user** — the exact inversion of the class rule (the team writes config;
the service account must NOT). It also `setcap`s
`cap_net_bind_service+eip` onto the binary — a file capability that
travels with the file and privileges *any* invoker, strictly worse than
the packaged units' per-unit `AmbientCapabilities`, and a
`file_capabilities` finding our captures don't have.

**maxhoesel's default mode is the admin API — the surface our review
closed.** The collection's flagship modules (and the role's default
`caddy_config_mode: json`) push config through caddy's unauthenticated
localhost admin endpoint; state persists in caddy's own storage, not in an
FIM-visible, ACL-governed `/etc/caddy` file. That is the same model behind
our `caddy-api` REVIEW-DROP and the admin-socket risk row
([ops §11](../apps/caddy/ops.md#11-known-risks-from-risks)). Only its
Caddyfile mode is compatible with this library's model.

## 5. Verdict: build (thin) — do not adopt a role as the install engine on matrix hosts

1. **The native install is already one task.** `dnf install caddy`
   (EPEL enabled, as the matrix records) / `apt install caddy` reproduces
   byte-for-byte the install these profiles were reviewed against. A
   public role can only deviate from that evidence, and both candidates
   do — provenance (R1/R2), config ownership, or the admin-API model (§4).
2. **Config management under lockdown needs no role either**: one
   `ansible.builtin.template` into the ACL-governed `/etc/caddy` + the
   granted reload handler. Whole-file determinism holds trivially
   (timestamp-free header).
3. **The genuinely missing pieces are org-overlay rows, not role rows**:
   R4 hardening drop-in (including tightening alma10's `CAP_NET_ADMIN`
   back to `CAP_NET_BIND_SERVICE`), the admin-socket lockdown from ops
   §11, R5 env-file templating, R6 (already delivered by this repo's
   profiles). See §7.
4. **Conditional exception — off-matrix hosts.** On amazonlinux-2023 (our
   N/A cell: no EPEL, no core package) or other package-less targets,
   **maxhoesel.caddy pinned, in Caddyfile mode** is the defensible engine
   (active, package-based, vendor repos); caddy_ansible only where a
   GitHub-binary provenance is explicitly accepted. Any such host is a new
   install shape: capture, review, and profile it separately — the four
   reviewed profiles here do **not** cover it.

## 6. Implementing least privilege with this role

"The role" below means the adopted install path from §5: the thin
native-package task set on matrix hosts, or wrapped `maxhoesel.caddy`
(Caddyfile mode) off-matrix.

### 6a. Where the role runs in the lifecycle

During the **setup window** (executor in `<hostname>-app_full`) or via
platform automation — always **before capture**, so its outputs land in
the footprint like a manual install
([lifecycle](../concepts/lifecycle.md)). Mapping:

| Install-path output | Lands as | Profile key |
|---|---|---|
| `caddy` package (EPEL/universe) | vendor units + `caddy:caddy` + `/var/lib/caddy` | `declarative_access_services: [caddy]` (read-only units; `caddy-api` deliberately ungranted) |
| Templated Caddyfile / `Caddyfile.d` drop-ins | config tree under `/etc/caddy` | `declarative_access_folders_modify: [/etc/caddy]` (write ACL) |
| Content deployed to `/usr/share/caddy` | packaged default site root | the profile's setgid `2775 root:caddy` ownership entry |
| reload handler | the verb that matters post-change | granted `systemctl reload caddy` (dev §2) |

Wrap notes: **pin the version** (package version via dnf/apt pinning;
role/collection version if maxhoesel is used) — a bump changes the
footprint → re-capture, re-review. Re-running the install path
post-lockdown is a **platform act**: a re-templated Caddyfile is re-covered
by the directory's default ACL, but re-run playbook 5 afterwards anyway
(idempotent) and diff against the raw profile if the package moved.

### 6b. Configuring the deployment for least privilege

- **Keep config root-owned.** The packages already do; never chown
  `/etc/caddy` to the service account. With caddy_ansible this is **not
  expressible** — its tasks hard-set the conf dir `0770` service-owned
  (§4), one of the reasons it isn't adopted. maxhoesel: use
  `caddy_config_mode: Caddyfile` (never the default `json`) so config
  stays an FIM-visible root-owned file.
- **Run as the packaged system user.** The packaged units pin
  `User=caddy`; leave them. caddy_ansible's `caddy_user` defaults to
  `www-data` — would need `caddy_user: caddy`, and its `/home/caddy` home
  still diverges from the packaged `/var/lib/caddy`.
- **Port/capability posture:** the vendor units' `AmbientCapabilities=`
  `CAP_NET_BIND_SERVICE` is the model — no root phase, no >1024 fallback
  needed. Set `caddy_setcap: false` if caddy_ansible is ever used (no
  file capabilities); org overlay tightens alma10's extra `CAP_NET_ADMIN`
  (ops §11).
- **Log to journald** (packaged default — no `log output file` in config)
  so the profile's journalctl grants hold; file access logs go through the
  ops re-review in [ops §10](../apps/caddy/ops.md#10-logs).
- **Secrets:** the packaged units load no `EnvironmentFile`; if one is
  introduced (systemd drop-in, root-owned `0600`, outside `/etc/caddy`),
  remember Caddyfile-inline secrets are readable via the admin API until
  its socket is locked down (ops §11) — prefer env placeholders.

### 6c. Applying the access profile

Once the install path has run and capture/review is done, lockdown is
playbook 5 with this app's reviewed profile, then verify and flip out of
app-full — the full runbook is
[ops §4–§6](../apps/caddy/ops.md#4-apply):

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/caddy/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

### 6d. Who does what after lockdown

The **application team's** admin surface is
[dev.md — "your life after lockdown"](../apps/caddy/dev.md): the granted
`systemctl`/`journalctl` spellings, the `/etc/caddy` write ACL and content
dir, and caddy's self-managed TLS (what they never touch:
`/var/lib/caddy`). The **operations team's** reference is
[ops.md](../apps/caddy/ops.md): footprint evidence (§1), the raw→reviewed
decisions (§2), apply/verify/flip/revoke (§4–§7), the TLS key-ownership
inversion (§9), and the risk triage (§11).

## 7. If nothing fits

The install half *is* the "nothing": a thin org task file —
`dnf install caddy` with EPEL enabled (EL) / `apt install caddy`
(Ubuntu) + a deterministic Caddyfile template + reload handler — plus the
same fleet-wide hardening overlay every app here needs: R4 drop-in
(`NoNewPrivileges`, `ProtectSystem=strict`, and the alma10
`AmbientCapabilities` tighten), the admin-socket lockdown
(`admin unix//run/caddy/admin.sock` — ops §11), R5 env-file support. R6 is
already delivered by this repo's reviewed profiles. Scope: alma9/10 +
ubuntu 24.04/26.04; molecule across all four cells (no upstream role
tests any of them). **Not scheduled** as a standalone build — it is the
generic overlay pattern, with caddy contributing only the admin-socket
and capability-tighten rows.

## 8. Sources

- https://github.com/caddy-ansible/caddy-ansible — `tasks/main.yml`
  (GitHub-release download, `/usr/local/bin`, conf dir `0770`
  service-owned, own unit template, `setcap`), `defaults/main.yml`
  (`caddy_user: www-data`, `caddy_home: /home/caddy`,
  `caddy_systemd_capabilities`, `caddy_log_file: stdout`); repo API:
  155★, pushed 2025-04-13, not archived — read 2026-08-23
- https://github.com/maxhoesel-ansible/ansible-collection-caddy — repo
  API: 24★, pushed 2026-08-19, not archived — read 2026-08-23
- https://ansible-collection-caddy.readthedocs.io/en/latest/collections/maxhoesel/caddy/caddy_server_role.html
  — install via Cloudsmith apt / COPR, platforms, `caddy_config_mode`
  (json default / Caddyfile), collection 1.1.0 — read 2026-08-23
- https://caddyserver.com/docs/install — official distribution is
  packages/binaries; no vendor Ansible role — read 2026-08-23
- Galaxy/GitHub candidate sweep (atosatto, samdoran, angristan,
  iancleary, simplificator, capitanh) — searched 2026-08-23
- Requirement source: `profiles/caddy/*-access.yml`,
  `docs/apps/caddy/{dev,ops}.md`
