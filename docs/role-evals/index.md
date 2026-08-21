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

Evaluations land here as apps complete review; the coverage table on the
[home page](../index.md) tracks status.
