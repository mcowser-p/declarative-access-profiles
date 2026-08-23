#!/usr/bin/env bash
# verify-profile-kvm.sh — verify reviewed profiles on REAL KVM guests from
# holy-qcow golden images (one VM per distro; every app's profile
# applied/probed/revoked in sequence). The images carry authselect, SELinux
# (or AppArmor on Ubuntu), real sshd+PAM and our CIS hardening, so the
# behavioral pam_group login probe is genuine — and the stamp names the
# exact image the profile was proven on.
#
# Usage:
#   scripts/verify-profile-kvm.sh --dry-run
#   scripts/verify-profile-kvm.sh sweep
#   scripts/verify-profile-kvm.sh [distro ...]              # default: all matrix distros
#   scripts/verify-profile-kvm.sh --app <app> [distro ...]  # one app only
# Env:
#   ACCESS_SRC    (required) ansible-declarative-access checkout (main branch)
#   LIBVIRT_URI   qemu:///system (default) or qemu+ssh://user@host/system
#   HOLY_QCOW_SRC holy-qcow checkout providing tofu/modules/vm (default ../md)
#
# Writes results to out/verify/<distro>.log; on success stamps the profile's
# "# VERIFIED:" header line with the guest's self-reported provenance
# (/etc/image-release IMAGE_NAME, MAC state, CIS state). Re-derive any
# profile the real OS contradicts.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kvm-lib.sh
source "$REPO/scripts/kvm-lib.sh"

[ "${1:-}" = "--dry-run" ] && { kvm_dry_run; exit $?; }
[ "${1:-}" = "sweep" ] && { kvm_sweep; exit 0; }

ONLY_APP=""
[ "${1:-}" = "--app" ] && { ONLY_APP="$2"; shift 2; }
: "${ACCESS_SRC:?set ACCESS_SRC to the ansible-declarative-access checkout}"

DISTROS="${*:-$(python3 -c "
import yaml; print(' '.join(yaml.safe_load(open('$REPO/matrix.yml'))['distros']))")}"
mkdir -p "$REPO/out/verify"
DAP_TRAP_DISTROS="$DISTROS"
trap kvm_teardown_scoped EXIT INT TERM
kvm_setup_key

# apps with a reviewed profile for this distro (respects --app and the
# DAP_ONLY_APP space-separated list, same contract as the capture driver)
apps_for() {
  local distro="$1"
  for d in "$REPO"/profiles/*/; do
    local app; app="$(basename "$d")"
    [ -n "$ONLY_APP" ] && [ "$app" != "$ONLY_APP" ] && continue
    if [ -n "${DAP_ONLY_APP:-}" ]; then
      case " $DAP_ONLY_APP " in *" $app "*) ;; *) continue ;; esac
    fi
    [ -f "$d/$distro-access.yml" ] && echo "$app"
  done
}

verify_one_distro() {
  local distro="$1" ip start; start=$(date +%s)
  local applist; applist="$(apps_for "$distro")"
  [ -z "$applist" ] && { log "$distro: no reviewed profiles — skipping"; return 0; }

  ip="$(kvm_launch "$distro")" || return 1
  log "$distro up at $ip — staging collection"
  kvm_scp_to "$ACCESS_SRC" "$ip" "$KVM_SSH_USER" "/tmp/linux-access"

  kvm_ssh "$ip" "$KVM_SSH_USER" 'sudo bash -s' <<'BOOT'
set -e
mkdir -p /root/.dap-tmp
export TMPDIR=/root/.dap-tmp
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

  # provenance for the VERIFIED stamp, self-reported by the guest once
  local prov
  prov="$(kvm_ssh "$ip" "$KVM_SSH_USER" 'bash -s' <<'PROBE'
. /etc/image-release 2>/dev/null
if command -v getenforce >/dev/null 2>&1; then
  mac="SELinux $(getenforce | tr '[:upper:]' '[:lower:]')"
elif command -v aa-enabled >/dev/null 2>&1 && aa-enabled >/dev/null 2>&1; then
  mac="AppArmor"
else
  mac="no MAC"
fi
if [ -n "${IMAGE_CIS_SCORE:-}" ]; then cis="CIS L1"; else cis="no CIS hardening"; fi
echo "KVM ${IMAGE_NAME:-unknown-image}, ${mac}, real PAM, ${cis}"
PROBE
)"
  prov="$(echo "$prov" | tail -1)"
  log "$distro provenance: $prov"

  local logf="$REPO/out/verify/$distro.log"; : > "$logf"
  local app pass_all=1
  for app in $applist; do
    log "  verify $app on $distro"
    kvm_scp_to "$REPO/profiles/$app/$distro-access.yml" "$ip" "$KVM_SSH_USER" "/tmp/profile.yml"
    # install the app's package so its units/paths exist
    local pkg conflicts repos
    pkg="$(python3 -c "
import yaml;m=yaml.safe_load(open('$REPO/matrix.yml'))
c=m['apps']['$app']['$distro'];print('' if 'na' in c else c['package'])")"
    conflicts="$(python3 -c "
import yaml;m=yaml.safe_load(open('$REPO/matrix.yml'))
c=m['apps']['$app']['$distro'];print('' if 'na' in c else ' '.join(c.get('conflicts',[])))")"
    repos="$(python3 -c "
import yaml;m=yaml.safe_load(open('$REPO/matrix.yml'))
c=m['apps']['$app']['$distro'];print('' if 'na' in c else ' '.join(c.get('repos',[])))")"
    case " $repos " in *" epel "*)
      kvm_ssh "$ip" "$KVM_SSH_USER" 'sudo dnf install -qy epel-release >/dev/null 2>&1' ;;
    esac
    if kvm_ssh "$ip" "$KVM_SSH_USER" "sudo APP=$app PKG='$pkg' CONFLICTS='$conflicts' bash -s" \
        < "$REPO/scripts/_verify-remote.sh" >> "$logf" 2>&1; then
      log "  OK  $app on $distro"
      sed -i.bak "s|^# REVIEWED: \(.*\)   VERIFIED: .*|# REVIEWED: \1   VERIFIED: $(date -u +%Y-%m-%d) ($prov)|" \
        "$REPO/profiles/$app/$distro-access.yml" && rm -f "$REPO/profiles/$app/$distro-access.yml.bak"
    else
      log "  FAIL $app on $distro (see out/verify/$distro.log)"; pass_all=0
    fi
  done

  kvm_destroy_distro "$distro"
  log "$distro verify complete ($(( ($(date +%s)-start)/60 )) min)"
  return $((1-pass_all))
}

fail=0
for d in $DISTROS; do verify_one_distro "$d" || fail=1; done
exit $fail
