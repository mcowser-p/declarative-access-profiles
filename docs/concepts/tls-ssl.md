# TLS/SSL under the restricted access model

This page is the canonical reference for TLS certificate and key handling on hosts
managed under the declarative access model. It covers the three files every TLS setup
comes down to, how certificates are issued and renewed, where key material lives on
EL versus Ubuntu, and — the part every application page links here for — exactly which
TLS tasks belong to the team in `<hostname>-app_restricted` and which stay with
platform/ops. Application docs state their own paths and file names in a sentence or
two and link here for the mechanics; the doctrine below is written once, on this page.

## What TLS does (and why the name "SSL" survives)

**TLS** (Transport Layer Security) does two things at once: it **encrypts** traffic
between a client and the server so nothing in between can read or tamper with it, and
it **proves the server's identity** with a certificate signed by a trusted authority.
"SSL" is TLS's obsolete predecessor, but the old name lives on in tool and config
vocabulary (`mod_ssl`, `ssl_certificate`, the `ssl-cert` group) — everything modern is
really TLS.

## The three files

Every TLS setup, regardless of application, reduces to:

| File | What it is | Who may read it |
|---|---|---|
| **Certificate** (`.crt`, `.pem`) | Public proof of identity, signed by a CA | Anyone — it is public |
| **Private key** (`.key`) | The secret half; proves you own the certificate | Only root and the service |
| **Chain / intermediate** (`.crt`) | Links your certificate to a trusted root CA | Anyone — public |

The one rule everything else on this page follows from: **protect the private key.**
Whoever holds it can impersonate the server, and unlike a password it cannot be
"changed quietly" — a leaked key means reissuing the certificate. The certificate and
chain, by contrast, are broadcast to every client during the handshake; there is
nothing secret about them.

## Where private keys live — and why no profile grants them

Private keys live in the platform's dedicated key directory, root-owned and mode
`0600`:

- **EL (AlmaLinux/RHEL):** `/etc/pki/tls/private/`
- **Ubuntu:** `/etc/ssl/private/` (a `0710 root:ssl-cert` directory; the `ssl-cert`
  group exists so individual services can be granted key access without making
  anything world-readable [app-knowledge])

These directories are deliberately in **no access profile**. Playbook 5
(`5_apply_access_profile.yml`) in the `mcowser_p.declarative_access` collection never
writes an ACL into a private-key directory, and a profile submitted with one should
fail review. The reasoning: the [access model](access-model.md) grants a team what it
needs to *operate* its application, and no routine operation requires reading a key —
the service reads its own key, and everything the team does (config edits, reloads,
expiry checks) works without it. A key grant is the single grant that converts
read access into host impersonation, so it is never an install default and never
part of the steady-state `<hostname>-app_restricted` posture.

Key placement and rotation is therefore **platform/ops work** — done by an operator
with elevated access, or by an automated agent such as certbot running as root.
Whether such an agent is already managing renewal on a given host is a site fact you
must check, not assume [needs-runtime-confirmation].

## EL vs Ubuntu locations

The two platform families keep TLS material in different standard places
[app-knowledge]:

| | EL (AlmaLinux/RHEL) | Ubuntu |
|---|---|---|
| Certificates + chains | `/etc/pki/tls/certs/` | `/etc/ssl/certs/` |
| **Private keys** | `/etc/pki/tls/private/` | `/etc/ssl/private/` (`ssl-cert` group) |
| Add a private CA to system trust | drop in `/etc/pki/ca-trust/source/anchors/`, then `update-ca-trust` | drop in `/usr/local/share/ca-certificates/` (as `.crt`), then `update-ca-certificates` |

On EL, files under `/etc/pki/tls` already carry the right SELinux label (`cert_t`);
keys stored anywhere custom must be relabeled or the service will be denied access.

## Getting a certificate: CSR → CA → cert

You do not make a trusted certificate yourself — a **Certificate Authority (CA)**
signs it. The flow is always the same:

```bash
# 1. Generate a private key plus a Certificate Signing Request (CSR):
openssl req -newkey rsa:2048 -nodes \
  -keyout myservice.example.edu.key \
  -out myservice.example.edu.csr \
  -subj "/CN=myservice.example.edu"

# 2. Submit the .csr to your CA (or let an ACME client like certbot do
#    steps 1-2 automatically). You get back a signed .crt plus chain.
# 3. The .key never leaves the host. Ops installs it root:root 0600 in the
#    platform key directory.
```

For throwaway internal testing a **self-signed** certificate works (clients warn,
because no CA vouches for it):

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout test.key -out test.crt -subj "/CN=test.local"
```

Which CA issues for your domain, and through what request process, is
site-specific — the mechanics above do not change.

## Renewal: the split between ops and the team

Certificates expire (often yearly). When one does, the service keeps running but every
client gets a security error — so renewal is the TLS task that actually recurs, and
the access model splits it cleanly in two:

1. **Ops (or the automated agent) rotates the key material.** New key and/or
   certificate land in the platform directories with the same root-owned permissions
   as before. The team's profile gives them no write access there, and none is needed.
2. **The team picks it up.** Loading the new files just means the service re-reads
   them, and the team's granted `systemctl reload`/`restart` verb — applied by
   playbook 5 (`5_apply_access_profile.yml`) as part of their profile — is exactly
   that. Web servers reload gracefully with zero downtime; some services need a full
   restart (see the exceptions below).

This split is why renewal never requires escalating anyone back into
`<hostname>-app_full`: the privileged half is ops routine, the unprivileged half is
already granted. See [lifecycle](lifecycle.md) for how the full/restricted flip works
in general.

**Monitoring expiry needs no privileges at all.** Certificates are public, so anyone
on the host — including the restricted team account — can check:

```bash
openssl x509 -enddate -noout -in /etc/pki/tls/certs/NAME.crt
# notAfter=Jun  1 12:00:00 2027 GMT

# or ask the running server itself, from any machine:
openssl s_client -connect myservice.example.edu:443 \
  -servername myservice.example.edu </dev/null 2>/dev/null \
  | openssl x509 -noout -dates
```

Expiry tracking is therefore squarely a team responsibility; "we couldn't see the
cert" is never true. A failed reload after rotation shows up in the service's journal,
which the team can read — see [logging](logging.md).

## Per-application-class exceptions

Three application classes bend the default split. They are stated once, here — the
application pages link to this section rather than restating it.

**Tomcat: keystore rotation is team self-service.** Java does not read PEM files;
Tomcat's certificate and key are packed together into a PKCS12 keystore, and that
keystore lives *inside the granted config tree* (e.g. `/etc/tomcat/`, `root:tomcat
0640`) rather than in the platform key directory. Because the team's profile already
covers that tree, rebuilding the keystore from ops-supplied PEM files and swapping it
in is something the team can do themselves:

```bash
openssl pkcs12 -export -in myapp.crt -inkey myapp.key   -certfile chain.crt -out /etc/tomcat/myapp.p12 -passout pass:changeit
```

(or, with the [mcowser_p.ssl_sleuth](https://github.com/mcowser-p/ssl-sleuth)
collection, the `pem_to_pkcs12` conversion job — which also verifies the
cert/key pair matches and can check the resulting endpoint's chain and
expiry). The catch: Tomcat has no graceful reload,
so picking up a new keystore means their granted `systemctl restart tomcat` and a
brief outage [app-knowledge].

**PostgreSQL: key rotation is always ops.** PostgreSQL requires `server.key` to be
mode `0600` (or it refuses to start) and expects it inside the data directory —
which is `0700 postgres:postgres` and thus a directory the team cannot enter under
the access model [app-knowledge]. There is no way to make PostgreSQL key rotation
self-service without granting the team the data directory, which the
[access model](access-model.md) rules out. Ops rotates; the team runs their granted
reload.

**nginx / httpd: the team never needs key read.** Both servers read the private key
as **root** during startup and reload, before dropping privileges to their worker
user [app-knowledge]. The running workers never touch the key, and neither does the
team — their granted reload triggers the root-side re-read. This is the cleanest
illustration of why key directories stay out of profiles: even the application's own
unprivileged processes don't read the key, so a human operating the application
certainly doesn't need to.

## Escalations that are always ops

Some TLS-adjacent changes are never covered by a restricted profile, by design:

- **First-time TLS enablement that installs software** — e.g. `dnf install mod_ssl`
  for httpd. Package installation changes the system's footprint and goes through a
  change window with `<hostname>-app_full`-level access, per the
  [lifecycle](lifecycle.md).
- **Changing a listening port to anything below 1024.** Privileged ports are bound by
  root at service start; the config edit may sit in the granted tree, but the change
  (and any firewall/SELinux port work that comes with it) is reviewed and executed by
  ops.
- **Any change to key file permissions or ownership.** Loosening `0600 root` on a key
  is exactly the grant the model refuses to make implicitly; if a team believes they
  need it, that is a profile-review conversation, not a `chmod`.

## Quick reference

```bash
# check a cert's expiry (no privileges needed)
openssl x509 -enddate -noout -in /etc/pki/tls/certs/NAME.crt

# check what a running server presents (from any host)
openssl s_client -connect HOST:443 -servername HOST </dev/null 2>/dev/null \
  | openssl x509 -noout -dates

# permissions sanity: the key must never be world-readable
ls -l /etc/pki/tls/private/NAME.key     # want -rw------- root  (EL)
ls -l /etc/ssl/private/NAME.key         # Ubuntu

# after ops rotates key material: pick it up with the granted verb
sudo systemctl reload nginx             # or httpd — graceful, no downtime
sudo systemctl restart tomcat           # keystore swap needs a restart
sudo systemctl reload postgresql        # after an ops-side key rotation
```
