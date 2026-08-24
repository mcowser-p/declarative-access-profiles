# IIS — deploy least-priv, then lock down

Runnable form of the IIS lockdown. Unlike the Linux examples there is no
public role to adopt: IIS is a Windows Feature, so `deploy.yml` is the thin
native install (mirroring holy-qcow `tofu/roles/iis`).

1. `deploy.yml` — IIS + WMSVC, one application pool per site on its own
   virtual account, content under `C:\inetpub\sites\<site>`.
2. `lockdown.yml` — applies
   [`profiles/iis/<platform>-access.yml`](../../profiles/iis/) to the team
   group: WMSVC per-site delegation, feature-delegation locks, NTFS grants,
   the pool's deny-write on `web.config`, `W3SVC`/`WAS` service SDDL, and
   the JEA endpoint for pool recycle + certificate binding.

**Single-tenant.** The `W3SVC`/`WAS` service grant reaches every site on the
host, which is correct when the host belongs to one team. For a
multi-tenant host, drop `declarative_access_windows_services` from the
profile and widen the JEA functions instead.

Evidence for the profile is a **live inventory**, not a footprint diff —
`Install-WindowsFeature` activates pre-staged payload, so a baseline diff
captures zero services. Re-run `scripts/iis-inventory.ps1` against your host
if your deployment differs from the reviewed one.

After lockdown: [dev.md](../../docs/apps/iis/dev.md) for the team,
[ops.md](../../docs/apps/iis/ops.md) for operations — including the
snapshot-based revoke story (SDDL and DACLs replace rather than merge) and
the force-logoff step that makes the flip real.
