# IIS — your life after lockdown

You deployed your sites; you're now in `<hostname>-app_restricted` and no
longer a local administrator on the web server. This page is everything you
can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile
([windows 2022](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/iis/windows-2022-access.yml)).

The short version: **your day-to-day home is IIS Manager, connected
remotely to your site.** Two things IIS can't delegate — recycling your app
pool and binding a certificate — come to you as PowerShell commands
instead.

## 0. First connection: IIS Manager to *your site*

Install the IIS Management Console on your workstation (Windows feature
`Web-Mgmt-Console`, or the standalone *IIS Manager for Remote
Administration* download), then **File → Connect to a Site** — not
"Connect to a Server", which needs administrator rights you no longer
have.

| Field | Value |
| --- | --- |
| Server name | `<hostname>:8172` |
| Site name | `app` (or `www`) |
| Credentials | your normal AD account |

The first connection warns about the management certificate. That warning
is currently expected — see the [known issue](ops.md#11-risk-triage): the
image ships a shared, hostname-mismatched WMSVC certificate. Confirm the
thumbprint with ops rather than clicking through blind.

## 1. Your grants at a glance

| What | How it's granted | How you use it |
| --- | --- | --- |
| Your sites `app`, `www` | IIS Manager Permissions (WMSVC) per site | connect, browse, start/stop the site |
| Config sections: default document, directory browsing, HTTP errors, HTTP redirect, static content | Feature Delegation set to *Read/Write* | edit them in IIS Manager; they write to your site's `web.config` |
| Content: `C:\inetpub\sites\app`, `...\www` | NTFS **Modify** for your team group, inherited by new files `(OI)(CI)` | deploy files, edit `web.config` |
| Your request logs: `C:\inetpub\logs\LogFiles\W3SVC1` (app), `W3SVC2` (www) | NTFS **Read** | read W3C logs directly |
| Application event log | `Event Log Readers` membership | Event Viewer, `Get-WinEvent -LogName Application` |
| App pool recycle | **JEA** proxy function (IIS Manager cannot do this) | `Restart-AppPool -Name app` |
| Certificate binding | **JEA** proxy function | `Bind-SiteCert -Site app -Thumbprint <hash>` |
| IIS service control | service SDDL on `W3SVC` + `WAS` | `sc.exe start W3SVC` / `Restart-Service W3SVC` |

## 2. Recycling your pool — the one that surprises everyone

IIS Manager will show you the Application Pools node and then refuse you:
pool operations are **server-scope** in IIS, not site-scope, so no amount
of per-site delegation reaches them. That is an IIS design fact, not a
policy choice by your ops team.

Instead, connect to the JEA endpoint and use the proxy function:

```powershell
$s = New-PSSession -ComputerName <hostname> -ConfigurationName iis -UseSSL
Invoke-Command -Session $s { Restart-AppPool -Name app }
```

`-Name` accepts only your pools (`app`, `www`) — it's a `ValidateSet`, so a
typo or someone else's pool name fails immediately rather than doing
something surprising.

## 3. TLS: you bind, the platform issues

You never hold a private key file. The platform issues and renews the
certificate (AD CS autoenrollment or ACME); you get **Read** on your
certificate's private key so IIS can serve it, and a proxy function to
attach it:

```powershell
Invoke-Command -Session $s { Bind-SiteCert -Site app -Thumbprint 'A1B2...' }
```

The current deployment has **no HTTPS binding and no site certificate**, so
your profile grants no key access yet — that's honest, not an oversight
(see [ops §2](ops.md#2-live-inventory--reviewed-the-decisions)). When ops
issues your cert, one entry is added naming that thumbprint.

Diagnosing a handshake problem: the CAPI2 operational channel logs chain
and key errors. If it's not readable for you, ask ops — it's a one-line
addition.

## 4. What you cannot do, and why

| Blocked | Why |
| --- | --- |
| Edit `applicationHost.config` | It is the server-wide config: any pool identity, any physical path, every site. Write access there is administrator-equivalent for the whole box, so it is granted to nobody at any tenancy. |
| Change **handlers** or **modules** | Both map requests to executable code. Write access is arbitrary code execution in your pool's identity — the single most valuable thing an attacker can take from a web server. Read-only by design. |
| Change authentication sections | That decides *who* reaches the app; it's a security-posture change, so it goes through ops. |
| Stop `WMSVC` | It's the remote-management service — the channel you're connecting over. Stopping it locks you (and everyone) out with no in-band way back. |
| Export your certificate's private key | You're granted Read so IIS can use the key, and the cert is imported non-exportable. Keys don't leave the box. |
| Add yourself to Administrators | That would undo the entire arrangement. |

## 5. When your app pool identity can't write something

Your worker process runs as the virtual account `IIS AppPool\app`, which is
**not** you. Files you deploy are readable by it, but there is a deliberate
**deny** on `web.config` writes *by the pool identity* — your app cannot
rewrite its own configuration at runtime. You can edit `web.config` (you
have Modify); your running code cannot. If your application genuinely needs
a writable directory, ask ops for a scoped `App_Data`-style grant rather
than loosening the config deny.

## 6. Cheat sheet

```powershell
# your sites
Get-Website | Where-Object Name -in 'app','www'

# start/stop your site (also available in IIS Manager)
Start-Website  -Name app
Stop-Website   -Name app

# recycle your pool (JEA)
Invoke-Command -Session $s { Restart-AppPool -Name app }

# your request logs
Get-Content C:\inetpub\logs\LogFiles\W3SVC1\u_ex*.log -Tail 50

# your application events
Get-WinEvent -LogName Application -MaxEvents 50

# IIS service (single-tenant host)
Restart-Service W3SVC
```
