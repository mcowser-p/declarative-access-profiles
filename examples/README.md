# Worked examples: deploy least-priv, then lock down

One directory per application: the runnable form of that app's
[role evaluation](../docs/role-evals/index.md). Each example is two plays
and a pin file:

| File | What it does | Where the reasoning lives |
| --- | --- | --- |
| `requirements.yml` | Pins the adopted public role (a version bump changes the footprint → re-capture, re-review) and the enforcement collection | role-eval §6a wrap notes |
| `deploy.yml` | Installs/configures the app with the role's least-privilege-compatible vars — run during the **setup window** (executor in app-full), before capture | role-eval §6b |
| `lockdown.yml` | Applies this repo's reviewed access profile to the host's restricted team group | role-eval §6c, the app's ops.md |

After lockdown, the application team's admin surface is the app's
`docs/apps/<app>/dev.md`; the operations runbook is `ops.md` (§6d).

## Running one

```bash
cd examples/nginx
ansible-galaxy install -r requirements.yml
ansible-playbook -i <inventory> deploy.yml
# ... capture + review happen between these on a NEW app (docs/onboarding.md);
# for the apps in this repo the reviewed profile already exists:
ansible-playbook -i <inventory> lockdown.yml -e distro_slug=almalinux-9
# revoke everything lockdown granted:
ansible-playbook -i <inventory> lockdown.yml -e distro_slug=almalinux-9 --tags cleanup
```

`lockdown.yml` loads the profile from this checkout
(`../../profiles/<app>/<distro_slug>-access.yml`) and runs the
`mcowser_p.declarative_access.declarative_access` role with it — the same
mechanics as the collection's playbook 5, resolved in-repo so profile and
example can never version-skew.

Profiles are data, examples are code: an example never edits a profile,
and `tools/check_profiles.py` still owns the contract.
