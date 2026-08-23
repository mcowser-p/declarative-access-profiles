# Role evaluations — method and index

Should you install this application with a public Ansible role
(geerlingguy, linux-system-roles, vendor roles), or by hand, or with an
org-built role? Each evaluation scores the public candidates against the
requirements this library derives from real install footprints, and ends
with an **adopt / adopt+wrap / build** verdict plus the part no public
role delivers: wiring the install into our access lifecycle.

The method and fixed R1–R10 rubric live in the
[evaluate-profile skill](https://github.com/mcowser-p/declarative-access-profiles/tree/main/skills/evaluate-profile/references/role-eval-rubric.md).
The standing finding so far: public roles make software *run*; none manage
the access model (scoped sudoers, pam_group, ACLs — rubric row R6). That
gap is exactly what the profiles in this repo fill.

Every evaluation ends with **"Implementing least privilege with this
role"** — the section that takes a team from "we picked this role" to
"locked down and operating":

- **6a** where the role runs in the access lifecycle (setup window, before
  capture) and how its outputs map to profile keys;
- **6b** configuring the deployment for least privilege — the role's own
  vars that keep config root-owned, the service on its packaged account,
  logs where the profile's grants expect them (and an honest "not
  expressible with this role" where the knob doesn't exist);
- **6c** applying the reviewed access profile — the playbook 5 command
  against this library's profile for the app;
- **6d** who does what after lockdown — the application team's admin
  surface is the app's [dev guide](../apps/nginx/dev.md) ("your life
  after lockdown"), the operations team's reference is its ops runbook.

The runnable form of §6 lives in the repo's
[`examples/<app>/` directories](https://github.com/mcowser-p/declarative-access-profiles/tree/main/examples)
— `requirements.yml` (the pinned role), `deploy.yml` (the §6b vars),
`lockdown.yml` (the §6c apply, resolved against this repo's profiles).

Evaluations land here as apps complete review; the coverage table on the
[home page](../index.md) tracks status.
