# IIS — lockdown runbook

Locking an IIS host down to its application team without making them
administrators. Companion to the team-facing [dev guide](dev.md); the
grants live in the reviewed profile
([windows 2022](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/iis/windows-2022-access.yml))
and the evidence in
[`evidence/windows-2022/inventory-iis.json`](https://github.com/mcowser-p/declarative-access-profiles/blob/main/evidence/windows-2022/inventory-iis.json).

**Scope: single-tenant.** One team owns the host. Where that assumption is
load-bearing, the text says so and names the multi-tenant alternative.

## 1. Evidence — live enumeration, not a footprint

IIS is the one application in this library whose access surface **cannot be
captured by baseline diff**. `Install-WindowsFeature` activates payload
that is already pre-staged in the component store, so W3SVC and WAS are in
the baseline and the diff shows *zero services*. treadmark says so in its
own code — its IIS smoke test asserts only that no **noise** service
appears, never that an IIS service does — and its access-vars exporter
refuses Windows models outright. Diffing cannot produce an IIS principal
model, so evidence here is a **live read** of the running host
(`scripts/iis-inventory.ps1`): same discipline, different instrument.

Captured 2026-08-23 on KVM `windows2022-core-20260823` (host `DAP-2022`,
Server 2022 Standard), deployed by holy-qcow `tofu/roles/iis`:

| | Evidence |
| --- | --- |
| Sites | `app` id 1 → `C:\inetpub\sites\app`, binding `http *:8080`, Started · `www` id 2 → `C:\inetpub\sites\www`, binding `http *:80`, Started |
| App pools | `app`, `www` — both `ApplicationPoolIdentity` → virtual accounts `IIS AppPool\app`, `IIS AppPool\www`. Also present: `DefaultAppPool`, `.NET v4.5`, `.NET v4.5 Classic` (shipped, siteless) |
| Services | `W3SVC` Automatic/Running as **localSystem** · `WAS` Manual/Running as **localSystem** · `WMSVC` Automatic/Running as `NT AUTHORITY\LocalService` |
| WMSVC state | feature installed, `EnableRemoteManagement=1`, `RequiresWindowsCredentials=1`, port 8172 open — **and `authorization` empty** |
| Content ACL | `C:\inetpub\sites\<site>` inherits from `C:\inetpub` only: TrustedInstaller/SYSTEM/Administrators FullControl, `BUILTIN\Users` ReadAndExecute. **No team ACE, no explicit pool ACE** |
| `applicationHost.config` ACL | `NT SERVICE\WMSVC` Read; TrustedInstaller/SYSTEM/Administrators FullControl. No non-admin access |
| Certificates | `CN=WMSvc-SHA2-WIN-3A1K9VK5JMB` (management listener, **exportable**) and `CN=DAP-2022` (WinRM listener). **No site certificate; no HTTPS binding** |
| Local groups | `Administrators` = [`DAP-2022\Administrator`] · `IIS_IUSRS`, `Event Log Readers`, `Remote Management Users` all **empty** |

**The headline finding: WMSVC is fully switched on and authorizes nobody.**
The feature is installed, remote management is enabled, the firewall is
open — and `administration.config` carries an empty authorization list, so
only local administrators can connect. Every element of the vendor
delegation path is present except the delegation itself. That gap is what
this profile closes.

## 2. Live inventory → reviewed: the decisions

| Change | Tag | Why |
| --- | --- | --- |
| Grant WMSVC IIS Manager Permissions per site (`app`, `www`) | REVIEW-ADD | The vendor-native path. Evidence shows the service ready and the authorization list empty. |
| Feature delegation: `defaultDocument`, `directoryBrowse`, `httpErrors`, `httpRedirect`, `staticContent` → Read/Write | REVIEW-ADD | The content-shaped sections. Writes land in the team's own `web.config`. |
| `handlers`, `modules` → **Read only** | REVIEW-KEEP | Both map requests to executable code; write access is arbitrary code execution as the pool identity. The most important lock in the profile. |
| `authentication/*` → **Read only** | REVIEW-KEEP | Decides who reaches the app — a security-posture change, not a content change. |
| NTFS Modify `(OI)(CI)` on both content roots | REVIEW-ADD | The team's deliverable. Inheritance is the default-ACL analog: without it the grant decays to "files that existed on apply day". |
| NTFS Read on `W3SVC1`/`W3SVC2` log dirs, not the `LogFiles` parent | REVIEW-CHANGE | Scoped per site; the parent would expose every other site's request logs on a multi-tenant host, and scoping costs nothing now. |
| Deny-Write for the pool identity on each `web.config` | REVIEW-ADD | The service must not rewrite its own config. On IIS this doubles as web-shell persistence defense. `[needs-runtime-confirmation]`: no `web.config` exists at deploy time, so the ACE lands when the team first deploys one. |
| `W3SVC` + `WAS` service SDDL | REVIEW-ADD | The pool-recycle/restart gap. Whole-service control is correct **because the host is single-tenant**; WAS is included because W3SVC without it leaves pools stopped. |
| Drop `WMSVC` from the service grant | REVIEW-DROP | It is the delegation channel; granting stop lets the team sever their own remote administration with no in-band recovery. |
| Drop `DefaultAppPool`, `.NET v4.5`, `.NET v4.5 Classic` | REVIEW-DROP | Shipped with IIS, siteless, not this team's. |
| `cert_keys` left **empty** | REVIEW-DROP | No site certificate and no HTTPS binding exist in the capture. Granting key access to a certificate that does not exist is guesswork. |
| Drop `local_groups` (no Administrators, no IIS_IUSRS) | REVIEW-DROP | Administrators defeats the exercise; IIS_IUSRS is for worker-process identities, not administrators. Both are empty in evidence and stay that way. |
| Drop `ownership` | REVIEW-DROP | Content is owned by SYSTEM and should stay so — the team gets an ACE, not the deed. Ownership is never reverted on cleanup, so asserting it is a one-way door. |
| JEA: `Restart-AppPool`, `Get-AppPoolStatus`, `Bind-SiteCert` | REVIEW-ADD | The two operations IIS Manager structurally cannot delegate (both server-scope). Constrained by `ValidateSet` to this profile's sites/pools — fails closed like an exact-command sudoers rule. |

## 3. What the vendor path does *not* delegate

Worth stating plainly, because it is the whole reason this profile has
non-WMSVC primitives. A delegated site connection **cannot**:

- recycle its application pool (Application Pools is server-scope — and it
  is the most common day-2 operation);
- edit bindings or bind a certificate (bindings and `http.sys` SSL binds
  are server-scope);
- restart `W3SVC`/`WAS` or run `iisreset`.

This mirrors the standing finding on the Linux side: public tooling makes
software *run*; none of it manages the access model.

## 4. Apply

```powershell
# prerequisite: the team's AD group exists and the host is domain-joined,
# or (single-tenant pilot) a local group stands in for it
ansible-playbook -i inventory playbooks/5_apply_windows_access_profile.yml `
  -e @profiles/iis/windows-2022-access.yml `
  -e "declarative_access_windows_group=<hostname>-app_restricted"
```

## 5. Verify

Probe as a **second identity**, never as Administrator — an admin passes
every check whether or not the grants work:

| Probe | Expect |
| --- | --- |
| Connect IIS Manager to site `app` as the team account | succeeds |
| `Restart-AppPool -Name app` over the JEA endpoint | succeeds |
| `Restart-AppPool -Name DefaultAppPool` | **rejected** (ValidateSet) |
| Write a file in `C:\inetpub\sites\app` | succeeds |
| Write `C:\Windows\system32\inetsrv\config\applicationHost.config` | **denied** |
| Change the `handlers` section in IIS Manager | **denied** (delegation read-only) |
| `sc.exe stop WMSVC` | **denied** |
| Export the site certificate's private key | **denied** |

## 6. Revoke

Windows has no `--tags cleanup` analog for SDDL or DACLs, because both
**replace** rather than merge. The enforcement role therefore snapshots
before it changes anything:

| Primitive | Rollback |
| --- | --- |
| Service SDDL | `sc.exe sdshow` snapshot taken pre-change, restored verbatim |
| NTFS DACLs | `(Get-Acl).Sddl` snapshot per path; normal revoke removes the added ACEs, the snapshot is the catastrophic-case restore |
| WMSVC grants | `ManagementAuthorization::Revoke` per site |
| Feature delegation | sections returned to the shipped default (Deny) |
| JEA | `Unregister-PSSessionConfiguration` |
| Group memberships | removed |
| Ownership | never reverted (by design) |

**The flip is not complete until the token is rebuilt.** Windows builds
group membership into the logon token, so removing the team from
`app_full` changes nothing for a signed-in user: force logoff
(`logoff <session>`) and have them `klist purge`. This is the exact analog
of the Linux `loginctl terminate-user` + `sss_cache -E` step.

## 7. Risk triage

| Risk | Severity | Disposition |
| --- | --- | --- |
| **WMSVC certificate is baked into the golden image** — `CN=WMSvc-SHA2-WIN-3A1K9VK5JMB` was issued 2026-08-20, before this clone existed, and is marked exportable. Every clone shares one private key and no CN ever matches its hostname, so IIS Manager always warns and users are trained to click through. | **High** | **Fix in the image.** The same repo already solves this correctly for WinRM (per-clone cert minted at first boot); WMSVC needs the same treatment. Tracked as a holy-qcow fix. |
| `W3SVC` and `WAS` run as **localSystem** | Medium | Accept — vendor default; worker processes run as the per-pool virtual accounts, which is where the request-handling risk actually lives. |
| `BUILTIN\Users` has ReadAndExecute on content roots (inherited from `C:\inetpub`) | Medium | Accept for single-tenant; on a shared host, break inheritance and grant the pool identity explicitly. Note this is a **deployment** change, not an access grant. |
| Whole-service `W3SVC`/`WAS` control reaches every site on the host | Medium | Accept — single-tenant by definition. On a multi-tenant host, drop the service grant and widen JEA instead. |
| `Event Log Readers` is machine-wide, not per-channel | Low | Accept for single-tenant; `wevtutil sl <channel> /ca:` is the per-channel alternative. |
| No HTTPS binding in the shipped deployment | Low | Deployment gap, not an access gap — recorded so the empty `cert_keys` is not mistaken for an oversight. |
