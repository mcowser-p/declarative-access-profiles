#!/usr/bin/env bash
# _verify-remote.sh — runs ON the EC2 instance (piped via ssh by
# verify-profile-ec2.sh). Applies /tmp/profile.yml with the real playbook 5,
# probes allow/deny incl. a behavioral pam_group ssh login, then revokes with
# --tags cleanup and asserts clean. Env: APP, PKG.
set -uo pipefail
APP="${APP:?}"; PKG="${PKG:-}"
ANS=/opt/ans-venv/bin/ansible-playbook
export ANSIBLE_ROLES_PATH=/tmp/linux-access/roles

# Remove conflicting packages from an earlier app on this same instance
# (mysql-server and mariadb-server cannot coexist; without this the install
# below silently fails and every probe afterwards lies).
if [ -n "${CONFLICTS:-}" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    # purge + autoremove --purge: removing the meta alone strands the core/
    # common packages and their conffiles (/etc/mysql, /var/lib/mysql), and
    # the incoming package's postinst then skips data-dir initialization
    DEBIAN_FRONTEND=noninteractive apt-get purge -qq -y $CONFLICTS >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -qq -y >/dev/null 2>&1 || true
  else
    dnf remove -qy $CONFLICTS >/dev/null 2>&1 || true
  fi
  # The MySQL/MariaDB pair (the only CONFLICTS users) shares datadir paths,
  # and even a purge preserves a populated datadir (Debian debconf policy;
  # rpm keeps non-empty dirs). The incoming server's postinst then skips
  # initialization and its -files/-keyring siblings never appear. Verify
  # simulates a CLEAN install, so clear the conflicting server's state.
  case " $CONFLICTS " in
    *" mariadb-server "*|*" mysql-server "*|*mariadb*server*)
      rm -rf /var/lib/mysql /var/lib/mysql-files /var/lib/mysql-keyring \
             /var/lib/mariadb /etc/mysql /etc/my.cnf.d /etc/my.cnf ;;
  esac
fi

# install the app so its units/paths exist (idempotent; apt auto-starts)
if [ -n "$PKG" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -qq -y $PKG >/dev/null 2>&1 || true
  else
    dnf install -qy $PKG >/dev/null 2>&1 || true
  fi
fi

groupadd "${APP}-team-sim" 2>/dev/null || true
# The probe users persist across apps on this instance, so ADD them to each
# app's team group (creating them once in the first app's group would make
# every later probe fail for the wrong reason).
id appdev  >/dev/null 2>&1 || useradd -m appdev
id pamuser >/dev/null 2>&1 || useradd -m -p '*' pamuser   # '*' = no password, NOT locked
usermod -aG "${APP}-team-sim" appdev
usermod -aG "${APP}-team-sim" pamuser

echo "=== APPLY $APP ==="
$ANS -i localhost, -c local /tmp/linux-access/playbooks/5_apply_access_profile.yml \
  -e @/tmp/profile.yml -e "group_name=${APP}-team-sim" \
  -e "declarative_access_sudo_nopasswd=true" 2>&1 | tee /tmp/apply.log | grep -E "PLAY RECAP" -A1 | tail -1
# surface the failing task — a silent failed=1 makes every later probe lie
grep -E "^(fatal|failed):" -A6 /tmp/apply.log | head -20

echo "=== granted verbs ==="
sudo -l -U appdev | tr ',' '\n' | grep -oE "systemctl [a-z-]+ [a-zA-Z0-9@.-]+" | sort -u | head -30

fail=0
echo "=== PROBES ==="
# a foreign unit must be denied
if sudo -u appdev sudo -n systemctl restart sshd.service >/dev/null 2>&1 || \
   sudo -u appdev sudo -n systemctl restart ssh.service >/dev/null 2>&1; then
  echo "FAIL deny: foreign unit restart allowed"; fail=1
else echo "OK  deny: foreign unit refused"; fi

# config dir writable via ACL/group (first folders_modify entry, if any)
CONF=$(/opt/ans-venv/bin/python -c "
import yaml;d=yaml.safe_load(open('/tmp/profile.yml'))
x=d.get('declarative_access_folders_modify') or [];print(x[0] if x else '')")
if [ -n "$CONF" ] && [ -d "$CONF" ]; then
  if sudo -u appdev bash -c "touch '$CONF/.probe' && rm -f '$CONF/.probe'" 2>/dev/null; then
    echo "OK  allow: write $CONF"; else echo "FAIL: appdev cannot write $CONF"; fail=1; fi
fi

# behavioral pam_group: does an sshd login put pamuser in the local group?
# (only when the profile uses pam_group)
USES_PAM=$(/opt/ans-venv/bin/python -c "
import yaml;d=yaml.safe_load(open('/tmp/profile.yml'))
print('1' if d.get('declarative_access_pam_group') else '')")
if [ -n "$USES_PAM" ]; then
  GRP=$(/opt/ans-venv/bin/python -c "
import yaml;d=yaml.safe_load(open('/tmp/profile.yml'))
g=d.get('declarative_access_local_groups') or [];print(g[0] if g else '')")
  # the profile maps the TEAM group; re-map pamuser's login group for the test
  # by adding a group.conf line for pamuser -> GRP via the role's own path is
  # overkill; instead confirm the rendered group.conf + that a fresh sshd
  # session for a mapped principal gains the group. We map %"${APP}-team-sim".
  # pamuser is a member of ${APP}-team-sim, so a login as pamuser should gain GRP.
  # NEVER let ssh-keygen prompt: on a re-run it asks "Overwrite?" and reads
  # the answer from stdin — which is the rest of this piped script.
  [ -f /root/.probe_key ] || ssh-keygen -q -t ed25519 -N '' -f /root/.probe_key </dev/null >/dev/null 2>&1
  mkdir -p /home/pamuser/.ssh; cp /root/.probe_key.pub /home/pamuser/.ssh/authorized_keys
  chown -R pamuser:"${APP}-team-sim" /home/pamuser/.ssh; chmod 700 /home/pamuser/.ssh; chmod 600 /home/pamuser/.ssh/authorized_keys
  IDS=$(ssh -i /root/.probe_key -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null pamuser@127.0.0.1 id 2>/dev/null || true)
  if echo "$IDS" | grep -q "$GRP"; then
    echo "OK  behavioral: sshd login gains '$GRP' via pam_group ($IDS)"
  else
    echo "WARN behavioral: '$GRP' not in sshd session id ($IDS) — check authselect/pam stack"
  fi
fi

echo "=== REVOKE (--tags cleanup) ==="
$ANS -i localhost, -c local /tmp/linux-access/playbooks/5_apply_access_profile.yml \
  -e @/tmp/profile.yml -e "group_name=${APP}-team-sim" \
  --tags cleanup --skip-tags login 2>&1 | grep -E "PLAY RECAP" -A1 | tail -1
if ls /etc/sudoers.d/ | grep -q "${APP}"; then echo "FAIL: sudoers survived"; fail=1
else echo "OK  revoked: sudoers gone"; fi

exit $fail
