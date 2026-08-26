#!/usr/bin/env bash
# verify-profile-windows.sh — verify reviewed Windows profiles on REAL KVM
# guests from holy-qcow golden images. The Windows counterpart of
# verify-profile-kvm.sh: apply the profile, probe that every grant landed,
# revoke, probe that every grant is gone and the snapshots restored.
#
# Transport: Ansible over SSH with ansible_shell_type=powershell (the golden
# images ship OpenSSH with PowerShell as the default shell). WinRM is NOT
# used — it is disabled at seal on 2025 images, and the SSH path works on
# both.
#
# Usage:
#   scripts/verify-profile-windows.sh --dry-run
#   scripts/verify-profile-windows.sh sweep
#   scripts/verify-profile-windows.sh [platform ...]   # default: all
# Env:
#   ACCESS_SRC    (required) ansible-declarative-access checkout
#   LIBVIRT_URI   qemu:///system or qemu+ssh://user@host/system
#   HOLY_QCOW_SRC holy-qcow checkout (default ../md)
#   DAP_KEEP_VM=1 leave the guest running after a pass (debugging)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=windows-lib.sh
source "$REPO/scripts/windows-lib.sh"

[ "${1:-}" = "--dry-run" ] && { win_dry_run; exit $?; }
[ "${1:-}" = "sweep" ] && { win_sweep; exit 0; }

: "${ACCESS_SRC:?set ACCESS_SRC to the ansible-declarative-access checkout}"
command -v ansible-playbook >/dev/null 2>&1 || { log "FATAL: ansible-playbook not on PATH"; exit 2; }

PLATFORMS="${*:-$(python3 -c "
import yaml; print(' '.join(yaml.safe_load(open('$REPO/matrix-windows.yml'))['platforms']))")}"
mkdir -p "$REPO/out/verify"
DAP_TRAP_PLATFORMS="$PLATFORMS"
win_install_traps
win_setup_creds

apps_for() {
  local platform="$1" d app
  for d in "$REPO"/profiles/*/; do
    app="$(basename "$d")"
    [ -f "$d/$platform-access.yml" ] || continue
    # Windows platforms only: a Linux profile dir also matches profiles/*/
    python3 -c "
import yaml,sys
m=yaml.safe_load(open('$REPO/matrix-windows.yml'))
sys.exit(0 if '$app' in m['apps'] else 1)" 2>/dev/null && echo "$app"
  done
}

verify_one_platform() {
  local platform="$1" ip app logf pass_all=1
  local applist; applist="$(apps_for "$platform")"
  [ -z "$applist" ] && { log "$platform: no reviewed Windows profiles — skipping"; return 0; }

  ip="$(win_launch "$platform")" || return 1
  log "$platform up at $ip"

  local inv="$REPO/out/verify/$platform.inv"
  cat > "$inv" <<EOF
[win]
target ansible_host=$ip
[win:vars]
ansible_user=$WIN_SSH_USER
ansible_connection=ssh
ansible_shell_type=powershell
ansible_ssh_private_key_file=$DAP_KEY_FILE
ansible_ssh_common_args=$(_win_ssh_opts | sed 's/-o BatchMode=yes //')
EOF

  logf="$REPO/out/verify/$platform.log"; : > "$logf"
  for app in $applist; do
    log "  verify $app on $platform"
    local grp="${app}-team-sim" play="$REPO/out/verify/$platform-$app.yml"
    cat > "$play" <<EOF
---
- hosts: win
  vars:
    declarative_access_windows_group: $grp
  vars_files:
    - $REPO/profiles/$app/$platform-access.yml
  pre_tasks:
    - name: Simulated team group (the apply-time entity)
      ansible.windows.win_powershell:
        script: |
          \$Ansible.Changed = \$false
          if (-not (Get-LocalGroup -Name '$grp' -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name '$grp' -Description 'dap verify' | Out-Null
            \$Ansible.Changed = \$true
          }
  roles:
    - declarative_access_windows
EOF
    local ok=1
    ANSIBLE_ROLES_PATH="$ACCESS_SRC/roles" ANSIBLE_STDOUT_CALLBACK=default \
      ansible-playbook -i "$inv" "$play" >>"$logf" 2>&1 || ok=0
    if [ "$ok" = 1 ]; then
      DAP_GROUP="$grp" DAP_PROFILE="$app" win_run_ps1_env "$ip" \
        "$REPO/scripts/_verify-windows-granted.ps1" >>"$logf" 2>&1 || ok=0
      grep -q "RESULT: PASS" "$logf" || ok=0
    fi
    # revoke and prove it, whether or not the grant probes passed
    ANSIBLE_ROLES_PATH="$ACCESS_SRC/roles" ANSIBLE_STDOUT_CALLBACK=default \
      ansible-playbook -i "$inv" "$play" --tags cleanup >>"$logf" 2>&1 || ok=0
    DAP_GROUP="$grp" DAP_PROFILE="$app" win_run_ps1_env "$ip" \
      "$REPO/scripts/_verify-windows-revoked.ps1" >>"$logf" 2>&1 || ok=0

    if [ "$ok" = 1 ]; then
      log "  OK  $app on $platform"
      # keep the stamp inside yamllint's 120-col limit: the image name is the
      # identity that matters, and the OS caption is redundant with it
      local image_name
      image_name="$(win_ssh "$ip" '(Get-ItemProperty HKLM:\SOFTWARE\ImageRelease).IMAGE_NAME' | tr -d '\r' | tail -1)"
      sed -i.bak "s|^# REVIEWED: \(.*\)   VERIFIED: .*|# REVIEWED: \1   VERIFIED: $(date -u +%Y-%m-%d) (KVM $image_name,\n#           WMSVC+SDDL+JEA applied, probed, revoked)|" \
        "$REPO/profiles/$app/$platform-access.yml" && rm -f "$REPO/profiles/$app/$platform-access.yml.bak"
    else
      log "  FAIL $app on $platform (see out/verify/$platform.log)"; pass_all=0
    fi
  done

  [ -n "${DAP_KEEP_VM:-}" ] || win_destroy_platform "$platform"
  return $((1-pass_all))
}

fail=0
for p in $PLATFORMS; do verify_one_platform "$p" || fail=1; done
exit $fail
