# Review rules — raw profile → reviewed profile

The tighten ruleset. Source of authority: the collection's
`docs/declarative-systemd-access.md` (access-model matrix + security
tradeoffs). Every rule application leaves a `REVIEW-*` comment.

## 1. Unit-file write ACLs

- **DROP** every `declarative_access_files_modify` entry under
  `/usr/lib/systemd/system` or `/lib/systemd/system` — vendor-owned, RPM/deb
  verified, and a write ACL on a unit file is root-equivalent for that unit.
  Most packaged apps end up with a **read-only-units profile** (no
  `files_modify` at all).
- **KEEP** (with `REVIEW-KEEP`) only team-authored units under
  `/etc/systemd/system` or `/etc/containers/systemd`, and say why.

## 2. Dependency noise

- **DROP** units/services pulled in as dependencies that belong to the
  system, not the app (`logrotate.service`/`.timer`, `dnf-makecache`,
  distro housekeeping timers). Test: would the team ever legitimately
  restart it? If unsure, drop — grants are easy to add later, embarrassing
  to revoke.
- Same for folders: `DROP` paths owned by other packages that only appear
  because the dependency closure landed together.

## 3. The class matrix

| Class | pam_group | Content | Config | Logs |
| --- | --- | --- | --- | --- |
| webserver / proxy / app-server | **yes** — into the service group (read/traverse baseline) | setgid `2775` group-owned dir via `ownership` (new files inherit the group) | write **ACL** (the team writes config; the service account must NOT — never group-own config to the service group) | read ACL |
| database | **NO pam_group** (the service group owns raw data — membership = data access) | — | write ACL on config files/dirs only | read ACL |
| cache | usually none needed | — | write ACL on the config file | read ACL |

Databases: `DROP` `declarative_access_pam_group`/`_local_groups` from the
raw profile with the standard comment; note in ops.md that the group option
exists at apply time (`-e enable_pam_group=true ...`) for teams that accept
data-dir exposure. **Never** grant the data dir (`/var/lib/pgsql`,
`/var/lib/mysql`, ...) in any list.

## 4. Reviewer additions (`REVIEW-ADD`)

- `/var/log/<app>` → `folders_read` — footprints exclude `/var/log` by
  default; the grant is still wanted.
- Content dirs outside config that the class needs (`/var/www`,
  `webapps/`) when the footprint shows them but the exporter routed them
  oddly, or the package creates them empty.
- Nothing else without naming a reason.

## 5. Keep as captured

- `ownership` entries for install-created accounts (they enforce the
  install-time state and make drift visible).
- Service/timer/quadlet grants for units the app itself installed.

## 6. Never

- `declarative_access_user` / `_group` / `_login` — apply-time decisions.
- Widening any grant to match `privilege.sudoers_files[]` — vendor-shipped
  sudoers content is ops-doc **evidence** (quote it in ops §1), not a
  reason to grant more.
- Editing the raw sibling file.

## 7. Use the new model keys

- `group_access[]` — if an install-created group already has group-write
  on a needed dir, prefer pam_group + that group over an ACL (zero
  deviation from vendor permissions — the Tomcat webapps case). The
  exporter does this automatically; verify its choice, don't fight it
  without a reason.
- `risks[]` — every high/critical entry gets a row in ops §11 with an
  accept-or-fix decision.

## 7b. Renames and narrowing (`REVIEW-CHANGE`)

Two deltas are neither add nor drop:

- **`declarative_access_profile_name`** — the exporter emits the distro
  package name (`httpd`, `apache2`, `php8.3-fpm`). Reviewed profiles use the
  **distro-neutral app slug** so one app has one identity across distros
  (and the contract check enforces `profile_name == app dir`). Note it as
  `REVIEW-CHANGE`. Consequence to state in ops §4: the sudoers filename
  follows the profile name.
- **Narrowing a granted path** to a subdirectory (e.g. Ubuntu's
  `/etc/postgresql` → `/etc/postgresql/16/main`, keeping the ACL off
  sibling clusters). Also `REVIEW-CHANGE`, with the reason.

## 8. Distro divergence

Apply `references/distro-map.md` before comparing profiles across distros:
unit names, service accounts, config layouts, and cert paths all differ.
When two distros' reviewed profiles end up identical apart from the header,
say so in the header ("identical to almalinux-9 as of this capture").
