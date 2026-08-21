# Conventions

The consistency rules every document and profile in this library follows.
Generators (human or LLM) apply them; reviewers enforce them.

## 1. Evidence gates

Every factual claim is exactly one of:

- **untagged** — read from a named footprint or profile in this repo;
- **`[app-knowledge]`** — true of the software generally, not observed in
  our capture;
- **`[needs-runtime-confirmation]`** — unknowable at install time (all
  port/listener claims, first-run file modes like PostgreSQL's
  `log_file_mode`, worker-process identities).

A doc's evidence sections (ops §1 footprint summary, dev §1 grants table)
may not contain tagged cells — those sections are evidence-only.

## 2. Grants are quoted, never paraphrased

Sudoers command lines, journalctl variants, and paths in dev §1/§2 and ops
§4/§5 are copied verbatim from the reviewed profile or rendered sudoers.
sudo matches the whole command string, argument order included — paraphrase
is a correctness bug. Every dev doc opens with the `sudo -l` framing.

## 3. One fact, one home

Shared mechanics live only in `concepts/` (default-ACL inheritance, the
logrotate mask gotcha, key-ownership split, root-equivalence tradeoff,
lifecycle mechanics). App docs state the app-specific instantiation in at
most two sentences and link. The canonical doctrine sentences are reused
word-for-word, not re-derived.

## 4. Profile ↔ doc lockstep

`<distro>-raw.yml` is never edited. Every reviewed-vs-raw delta carries
exactly one greppable review comment:

```
# REVIEW-DROP:   <what> — <why>   (removed keys stay visible as comments)
# REVIEW-KEEP:   <why>            (retained despite looking risky)
# REVIEW-ADD:    <why>            (hand-added — e.g. /var/log/<app>)
# REVIEW-CHANGE: <why>            (value narrowed or renamed — e.g. the
#                                  distro-neutral profile_name, or a
#                                  folder scoped down to a subdirectory)
```

dev.md and ops.md cite the profile path; a profile edit invalidates the
`# VERIFIED:` line until `scripts/verify-profile.sh` passes again.

## 5. Tone split

- **dev.md** — second person, freshman-and-up, explains *why* once.
- **ops.md** — imperative runbook, tables over prose, every command
  copy-pasteable.
- **blog** — narrative; every technical claim exists in a linked doc. The
  blog cites, never originates.

## 6. Per-distro N/A is explicit

Distro tables always carry all three distro columns. A non-applicable cell
reads `N/A on <distro> — <short reason>`. Silence is indistinguishable
from omission at generation scale, so silence is banned.

## 7. Naming discipline

AD groups are always `<hostname>-app_full` / `<hostname>-app_restricted`.
Local service groups use the distro-correct name with the cross-name in
parentheses on first use (`apache` (Ubuntu: `www-data`)). Unit names keep
their exact suffixes (`.timer` stays `.timer`). The apply vehicle is cited
as "playbook 5 (`5_apply_access_profile.yml`)".

## 8. Cross-link contract

Every dev.md links: its ops.md, its reviewed profile, `concepts/tls-ssl.md`
and `concepts/logging.md`. Every ops.md links: its dev.md, both profile
files, the app's role-eval, and `concepts/lifecycle.md`. Link text names
the target ("the raw→reviewed decisions in ops §2"), never "here".

## 9. The make-or-break details use fixed wording

Wherever they apply, these are stated with the canonical sentences from
`concepts/`:

1. default ACLs are why new and rotated files stay granted;
2. logrotate's `create` mode is the ACL mask — `getfacl` `#effective:` is
   the diagnostic, `logrotate -f` + `getfacl` is the pre-flip test;
3. private keys are root-only and in no profile — the team reloads, the
   platform rotates; Tomcat (keystore in granted tree) and PostgreSQL (key
   inside the closed data dir) are the two named exceptions.

## 10. Honesty sections are mandatory

dev.md includes denied-command examples. ops.md includes the `risks[]`
triage and, whenever `files_modify` is non-empty, the root-equivalence and
global-daemon-reload tradeoffs. The blog's limits section may not be cut.
