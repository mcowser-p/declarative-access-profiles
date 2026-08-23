#!/usr/bin/env bash
# verify-profile-ec2.sh — verify reviewed profiles on REAL EC2 instances
# (one per distro; every app's profile applied/probed/revoked in sequence).
# The real OS carries authselect + SELinux enforcing + real sshd+PAM, so the
# behavioral pam_group login is genuine — the point of using AMIs.
#
# LEGACY: verify-profile-kvm.sh on holy-qcow images is the authoritative
# path now; this AWS driver is kept as a fallback and only knows the
# original three distros.
#
# Usage:
#   scripts/verify-profile-ec2.sh --dry-run
#   scripts/verify-profile-ec2.sh sweep [--hours N]
#   scripts/verify-profile-ec2.sh [distro ...]        # default: all distros
#   scripts/verify-profile-ec2.sh --app <app> [distro ...]   # one app only
# Env:
#   ACCESS_SRC (required) — ansible-declarative-access checkout (main).
#   AWS_REGION (us-west-2), DAP_ITYPE (t3.small), DAP_MAX_MINUTES (30)
#
# Writes results to out/verify/<distro>.log; on success stamps the profile's
# "# VERIFIED:" header line. Re-derive any profile the real OS contradicts.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=ec2-lib.sh
source "$REPO/scripts/ec2-lib.sh"

[ "${1:-}" = "--dry-run" ] && { ec2_dry_run; exit 0; }
[ "${1:-}" = "sweep" ] && { shift; [ "${1:-}" = "--hours" ] && { ec2_sweep "$2"; exit 0; }; ec2_sweep; exit 0; }

ONLY_APP=""
[ "${1:-}" = "--app" ] && { ONLY_APP="$2"; shift 2; }
: "${ACCESS_SRC:?set ACCESS_SRC to the ansible-declarative-access checkout}"

DISTROS="${*:-almalinux-9 almalinux-10 ubuntu-24.04}"
mkdir -p "$REPO/out/verify"
trap ec2_teardown EXIT INT TERM
ec2_setup_sg_key

# apps with a reviewed profile for this distro (respects --app)
apps_for() {
  local distro="$1"
  for d in "$REPO"/profiles/*/; do
    local app; app="$(basename "$d")"
    [ -n "$ONLY_APP" ] && [ "$app" != "$ONLY_APP" ] && continue
    [ -f "$d/$distro-access.yml" ] && echo "$app"
  done
}

verify_one_distro() {
  local distro="$1" ip u start; start=$(date +%s)
  local applist; applist="$(apps_for "$distro")"
  [ -z "$applist" ] && { log "$distro: no reviewed profiles — skipping"; return 0; }

  ip="$(ec2_launch "$distro")" || return 1
  u="$(ec2_ssh_user "$distro")"
  log "$distro up at $ip — staging collection"
  ec2_scp_to "$ACCESS_SRC" "$ip" "$u" "/tmp/linux-access"

  ec2_ssh "$ip" "$u" 'sudo bash -s' <<'BOOT'
set -e
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -qq -y python3-venv python3-pip acl >/dev/null
else
  dnf install -qy python3-pip acl >/dev/null
fi
python3 -m venv /opt/ans-venv
/opt/ans-venv/bin/pip -q install ansible-core >/dev/null
/opt/ans-venv/bin/ansible-galaxy collection install community.general ansible.posix >/dev/null 2>&1
BOOT

  local logf="$REPO/out/verify/$distro.log"; : > "$logf"
  local app pass_all=1
  for app in $applist; do
    log "  verify $app on $distro"
    ec2_scp_to "$REPO/profiles/$app/$distro-access.yml" "$ip" "$u" "/tmp/profile.yml"
    # install the app's package so its units/paths exist
    local pkg conflicts
    pkg="$(python3 -c "
import yaml;m=yaml.safe_load(open('$REPO/matrix.yml'))
c=m['apps']['$app']['$distro'];print('' if 'na' in c else c['package'])")"
    conflicts="$(python3 -c "
import yaml;m=yaml.safe_load(open('$REPO/matrix.yml'))
c=m['apps']['$app']['$distro'];print('' if 'na' in c else ' '.join(c.get('conflicts',[])))")"
    if ec2_ssh "$ip" "$u" "sudo APP=$app PKG='$pkg' CONFLICTS='$conflicts' bash -s" < "$REPO/scripts/_verify-remote.sh" >> "$logf" 2>&1; then
      log "  OK  $app on $distro"
      # stamp VERIFIED
      local ami; ami="$(ec2_ami_for "$distro")"
      sed -i.bak "s|^# REVIEWED: \(.*\)   VERIFIED: .*|# REVIEWED: \1   VERIFIED: $(date -u +%Y-%m-%d) (EC2 $distro $ami, SELinux/authselect real)|" \
        "$REPO/profiles/$app/$distro-access.yml" && rm -f "$REPO/profiles/$app/$distro-access.yml.bak"
    else
      log "  FAIL $app on $distro (see out/verify/$distro.log)"; pass_all=0
    fi
  done

  ec2_charge $(( ($(date +%s)-start)/60 + 1 ))
  return $((1-pass_all))
}

fail=0
for d in $DISTROS; do verify_one_distro "$d" || fail=1; done
exit $fail
