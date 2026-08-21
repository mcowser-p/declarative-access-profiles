# Ansible role evaluation: nginx (AlmaLinux 9/10, Ubuntu 24.04)

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
| R1 | Both distro families, correct paths/unit/account | ✅ RedHat + Debian families; installs the vendor/package unit | ✅ broad OS matrix, incl. EL/Debian |
| R2 | Install + configure via native mechanisms | ✅ package install + config template | ✅ package + repo setup + templated config |
| R3 | Drop-in discipline vs whole-file | ⚠️ templates the main `nginx.conf` whole-file (`templates/nginx.conf.j2`) + a vhosts template | ⚠️ directive-level templating, but still renders managed files whole |
| R4 | systemd hardening drop-ins | ❌ none | ❌ none |
| R5 | env/secret file management | ❌ n/a for nginx | ❌ n/a |
| R6 | **Access model (sudoers/pam_group/ACLs)** | ❌ none | ❌ none |
| R7 | Verify / idempotence quality | ✅ molecule, multi-distro | ✅ molecule, extensive |
| R8 | TLS wiring | ⚠️ passes ssl directives through vhost config; no key lifecycle | ✅ richer TLS templating; still no key ownership/rotation model |
| R9 | logrotate policy management | ❌ relies on the package's fragment | ❌ same |
| R10 | Maintenance/assurance for our versions | ✅ covers EL9/10 + noble | ✅ vendor-tracked |

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
(+ `nginx_config`) when you need NGINX Plus or fine-grained config. Wrap
either with our access lifecycle — neither delivers R4/R6/R9, and that gap
is not a role defect, it's the job this library does. As with every app so
far, R6 (access model) is a clean miss across all public roles.

## 6. Running the adopted role inside our access lifecycle

- **When it runs:** during the setup window (the executor holds
  `<hostname>-app_full`) or via platform automation — always **before**
  capture, so everything the role creates lands in the footprint exactly as
  a manual install would.
- **Mapping (role output → profile key):** the installed `nginx.service` →
  `declarative_access_services`; the templated `/etc/nginx` tree → the
  config-write ACL in `folders_modify`; the content root the role serves →
  the setgid `ownership` entry; the role's reload handler confirms the
  `reload` verb belongs in the grant.
- **Wrap notes:** pin the role version — a version bump can change the
  rendered config set and therefore the footprint, so re-capture and
  re-review on upgrade. Disable any role option that chowns the config tree
  to the `nginx` service account (it would let the service rewrite its own
  config, which our model deliberately prevents). Re-running the role
  post-lockdown is a platform act; if it replaces ACL'd files, re-run
  playbook 5 afterward (it's idempotent).

## 7. Sources

- [geerlingguy/ansible-role-nginx (GitHub)](https://github.com/geerlingguy/ansible-role-nginx)
- [geerlingguy.nginx (Ansible Galaxy)](https://galaxy.ansible.com/geerlingguy/nginx/)
