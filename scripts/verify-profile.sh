#!/usr/bin/env bash
# verify-profile.sh — apply a reviewed profile to a simulated restricted
# group inside a systemd container, prove allow/deny, then revoke via the
# real --tags cleanup path. One green run earns the profile its
# "# VERIFIED:" header line.
#
# Usage:  scripts/verify-profile.sh <app> <distro>
#         (app/distro exactly as in matrix.yml, e.g. nginx almalinux-9)
# Env:    ACCESS_SRC  (required) path to an ansible-declarative-access
#                     checkout (main). Alternative once pinned versions
#                     matter here:
#                     `ansible-galaxy collection install mcowser_p.declarative_access`.
#         DOCKER_HOST as needed (macOS Docker Desktop).
#
# Adapted from ansible-declarative-access scripts/verify-app-profile.sh;
# differences: distro-aware images (self-built ubuntu init image — there is
# no official ubuntu-24.04 systemd image), installs the app itself (no
# capture container reuse), config/log/vendor-unit probes as appdev.
set -euo pipefail

APP="${1:?usage: verify-profile.sh <app> <distro>}"
DISTRO="${2:?usage: verify-profile.sh <app> <distro>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
: "${ACCESS_SRC:?set ACCESS_SRC to the ansible-declarative-access checkout}"

PROFILE="profiles/${APP}/${DISTRO}-access.yml"
[ -f "$REPO/$PROFILE" ] || { echo "missing $PROFILE — review the raw profile first" >&2; exit 1; }

cell_json=$(python3 -c "
import yaml, json, sys
m = yaml.safe_load(open('$REPO/matrix.yml'))
c = m['apps'].get('$APP', {}).get('$DISTRO')
if not c or 'na' in c:
    sys.exit('matrix cell $APP/$DISTRO missing or N/A')
c['family'] = m['distros']['$DISTRO']['family']
print(json.dumps(c))")
PKG=$(echo "$cell_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['package'])")
SERVICE=$(echo "$cell_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['service'])")
FAMILY=$(echo "$cell_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['family'])")

case "$DISTRO" in
  almalinux-9)  IMG="almalinux/9-init" ;;
  almalinux-10) IMG="almalinux/10-init" ;;
  ubuntu-24.04)
    IMG="dap/ubuntu-24.04-init"
    if ! docker image inspect "$IMG" >/dev/null 2>&1; then
      echo "[*] building $IMG (no official ubuntu systemd image)"
      docker build -t "$IMG" - <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y systemd systemd-sysv && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
CMD ["/sbin/init"]
DOCKERFILE
    fi ;;
  ubuntu-26.04)
    IMG="dap/ubuntu-26.04-init"
    if ! docker image inspect "$IMG" >/dev/null 2>&1; then
      echo "[*] building $IMG (no official ubuntu systemd image)"
      docker build -t "$IMG" - <<'DOCKERFILE'
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y systemd systemd-sysv && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
CMD ["/sbin/init"]
DOCKERFILE
    fi ;;
  amazonlinux-2023)
    IMG="dap/amazonlinux-2023-init"
    if ! docker image inspect "$IMG" >/dev/null 2>&1; then
      echo "[*] building $IMG (no official AL2023 systemd image)"
      docker build -t "$IMG" - <<'DOCKERFILE'
FROM amazonlinux:2023
RUN dnf -y install systemd && dnf clean all
CMD ["/sbin/init"]
DOCKERFILE
    fi ;;
  *) echo "unknown distro $DISTRO" >&2; exit 1 ;;
esac

NAME="dap-verify-${APP}-${DISTRO}"
echo "[*] starting $IMG as $NAME"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --privileged --name "$NAME" "$IMG" >/dev/null
sleep 5

docker cp "$ACCESS_SRC" "$NAME:/opt/linux-access" >/dev/null
docker cp "$REPO/$PROFILE" "$NAME:/tmp/profile.yml" >/dev/null

docker exec -i "$NAME" bash -s -- "$APP" "$PKG" "$SERVICE" "$FAMILY" <<'INNER'
set -euo pipefail
APP="$1"; PKG="$2"; SERVICE="$3"; FAMILY="$4"

# wait for systemd
for i in $(seq 1 12); do
  state=$(systemctl is-system-running 2>/dev/null || true)
  case "$state" in running|degraded) break ;; esac
  sleep 5
done

# openssh-server: a locked-down target always runs sshd, and the pam_group
# path edits /etc/pam.d/sshd — the base ubuntu init image ships neither.
if [ "$FAMILY" = "debian" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -qq -y $PKG ansible-core acl sudo python3 openssh-server >/dev/null
else
  # AL2023 packages ansible as `ansible`; EL9/10 ship `ansible-core`
  dnf install -qy $PKG ansible-core acl sudo openssh-server >/dev/null 2>&1 \
    || dnf install -qy $PKG ansible acl sudo openssh-server >/dev/null
fi
ansible-galaxy collection install community.general ansible.posix >/dev/null 2>&1

groupadd "${APP}-team-sim" 2>/dev/null || true
id appdev >/dev/null 2>&1 || useradd -m -G "${APP}-team-sim" appdev
export ANSIBLE_ROLES_PATH=/opt/linux-access/roles

echo "===== APPLY $APP profile to ${APP}-team-sim ====="
ansible-playbook -i localhost, -c local \
  /opt/linux-access/playbooks/5_apply_access_profile.yml \
  -e @/tmp/profile.yml \
  -e "group_name=${APP}-team-sim" -e "declarative_access_sudo_nopasswd=true" \
  2>&1 | grep -E "PLAY RECAP" -A1 | tail -1

echo "===== granted verbs (sudo -l -U appdev) ====="
sudo -l -U appdev | tr "," "\n" | grep -oE "systemctl [a-z-]+ [a-zA-Z0-9@.-]+" | sort -u | head -30

echo "===== PROBES as appdev ====="
sudo -u appdev sudo -n systemctl status "$SERVICE" >/dev/null \
  && echo "OK  allow: systemctl status $SERVICE"
sudo -u appdev sudo -n systemctl restart "$SERVICE" >/dev/null \
  && echo "OK  allow: systemctl restart $SERVICE"
if sudo -u appdev sudo -n systemctl restart ssh.service >/dev/null 2>&1 || \
   sudo -u appdev sudo -n systemctl restart sshd.service >/dev/null 2>&1; then
  echo "FAIL deny: foreign unit restart was ALLOWED"; exit 1
else
  echo "OK  deny: foreign unit restart refused"
fi
# config-dir write via ACL/group (first folders_modify entry, if any)
CONF_DIR=$(python3 -c "
import yaml
d = yaml.safe_load(open('/tmp/profile.yml'))
dirs = d.get('declarative_access_folders_modify') or []
print(dirs[0] if dirs else '')")
if [ -n "$CONF_DIR" ]; then
  sudo -u appdev bash -c "touch '$CONF_DIR/.dap-verify' && rm -f '$CONF_DIR/.dap-verify'" \
    && echo "OK  allow: write in $CONF_DIR" \
    || { echo "FAIL: appdev cannot write $CONF_DIR"; exit 1; }
fi
# vendor unit must NOT be writable
UNIT_PATH=$(systemctl show -p FragmentPath "$SERVICE" | cut -d= -f2)
if [ -n "$UNIT_PATH" ] && sudo -u appdev bash -c "echo x >> '$UNIT_PATH'" 2>/dev/null; then
  echo "FAIL deny: vendor unit $UNIT_PATH is writable"; exit 1
else
  echo "OK  deny: vendor unit not writable"
fi

echo "===== REVOKE (real --tags cleanup) ====="
ansible-playbook -i localhost, -c local \
  /opt/linux-access/playbooks/5_apply_access_profile.yml \
  -e @/tmp/profile.yml \
  -e "group_name=${APP}-team-sim" --tags cleanup --skip-tags login \
  2>&1 | grep -E "PLAY RECAP" -A1 | tail -1
if ls /etc/sudoers.d/ | grep -q "${APP}"; then
  echo "FAIL: sudoers file survived cleanup"; exit 1
fi
if [ -n "$CONF_DIR" ] && getfacl -p "$CONF_DIR" 2>/dev/null | grep -q "${APP}-team-sim"; then
  echo "FAIL: ACL for ${APP}-team-sim survived cleanup"; exit 1
fi
echo "OK  revoked clean"
INNER

docker rm -f "$NAME" >/dev/null
echo "[*] VERIFIED: $APP on $DISTRO — record it in the profile header"
