#!/usr/bin/env bash
# windows-lib.sh — shared Windows launch/teardown for the IIS capture and
# verify drivers. The Windows counterpart of kvm-lib.sh.
#
# Transport is SSH (the golden images ship OpenSSH with PowerShell as the
# default shell — see holy-qcow packer/common/windows/base.ps1), matching
# holy-qcow's smoke-test-windows.sh. WinRM-HTTPS exists on windows2022
# images and is what a delegated team member would use for a second-identity
# PS-Remoting session; Administrator automation goes over SSH.
#
# Two Windows-specific teardown facts, both learned the hard way upstream:
# UEFI domains leave an NVRAM file that blocks re-definition (undefine needs
# --nvram), and computer names are NetBIOS-limited to 15 chars, so the domain
# prefix stays short.
set -euo pipefail

: "${LIBVIRT_URI:=qemu:///system}"
: "${DAP_GOLDEN_POOL:=golden}"
: "${DAP_VM_POOL:=vmdisks}"
: "${WIN_SSH_USER:=Administrator}"

_WINLIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HOLY_QCOW_SRC:=$_WINLIB_REPO/../md}"
WIN_WORK_ROOT="$_WINLIB_REPO/out/windows"

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
TOFU="${TOFU:-$(command -v tofu || echo "$HOME/.local/bin/tofu")}"

log() { echo "[win] $*" >&2; }

# --- guest ssh hop (NAT guests are reachable only from the KVM host) ------
win_jump() {
  if [ -n "${DAP_SSH_JUMP:-}" ]; then
    [ "$DAP_SSH_JUMP" = "none" ] || echo "$DAP_SSH_JUMP"
    return 0
  fi
  case "$LIBVIRT_URI" in
    qemu+ssh://*) echo "$LIBVIRT_URI" | sed 's|^qemu+ssh://||; s|/.*$||' ;;
  esac
}

_win_ssh_opts() {
  local jump; jump="$(win_jump)"
  echo "-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR${jump:+ -o ProxyJump=$jump}"
}

# --- image resolution ------------------------------------------------------
# platform slug -> golden volume prefix. Editions are distinct images; the
# pilot targets core (headless is the server norm and IIS Manager is remote).
win_slug_for() {
  case "$1" in
    windows-2022) echo windows2022-core ;;
    windows-2025) echo windows2025-core ;;
    *) echo "unknown windows platform $1" >&2; return 1 ;;
  esac
}

win_image_for() {
  local platform="$1" slug pin vol
  slug="$(win_slug_for "$platform")" || return 1
  pin="$(eval "echo \${DAP_IMAGE_${slug//-/_}:-}")"
  if [ -n "$pin" ]; then echo "$pin"; return 0; fi
  vol="$(virsh -c "$LIBVIRT_URI" vol-list "$DAP_GOLDEN_POOL" 2>/dev/null \
    | awk '{print $1}' | grep -E "^${slug}-[0-9]{8}\.qcow2$" | sort | tail -1)"
  [ -n "$vol" ] || { log "FATAL: no ${slug}-*.qcow2 in pool $DAP_GOLDEN_POOL at $LIBVIRT_URI"; return 1; }
  echo "$vol"
}

# --- ephemeral key + admin password ---------------------------------------
DAP_KEY_DIR="" DAP_KEY_FILE="" WIN_ADMIN_PW=""

win_setup_creds() {
  DAP_KEY_DIR="$(mktemp -d)"
  DAP_KEY_FILE="$DAP_KEY_DIR/dap-win"
  ssh-keygen -q -t ed25519 -N "" -C "dap-win-ephemeral" -f "$DAP_KEY_FILE"
  # complexity-satisfying throwaway; never leaves this run
  WIN_ADMIN_PW="Dap!$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')9z"
  log "ephemeral key $DAP_KEY_FILE"
}

# --- launch one VM; echoes its IPv4 ---------------------------------------
win_launch() {
  local platform="$1" vol name workdir ip
  vol="$(win_image_for "$platform")" || return 1
  # <=15 chars: NetBIOS truncates silently and clones then collide
  name="dap-${platform#windows-}"   # windows-2022 -> dap-2022
  workdir="$WIN_WORK_ROOT/$platform"
  mkdir -p "$workdir"
  sed "s|@@VM_MODULE_SOURCE@@|$HOLY_QCOW_SRC/tofu/modules/windows-vm|" \
    "$_WINLIB_REPO/scripts/windows/main.tf.tmpl" > "$workdir/main.tf"

  log "launching $platform ($vol) as $name via $LIBVIRT_URI"
  "$TOFU" -chdir="$workdir" init -input=false >/dev/null
  "$TOFU" -chdir="$workdir" apply -auto-approve -input=false \
    -var "libvirt_uri=$LIBVIRT_URI" \
    -var "image=$vol" \
    -var "name=$name" \
    -var "admin_password=$WIN_ADMIN_PW" \
    -var "ssh_authorized_keys=[\"$(cat "$DAP_KEY_FILE.pub")\"]" >/dev/null

  # windows-vm sets wait_for_lease=false (OOBE outlasts the provider), so the
  # host lease table is the only address source. 10 min.
  local i
  for i in $(seq 1 60); do
    ip="$(virsh -c "$LIBVIRT_URI" domifaddr "$name" --source lease 2>/dev/null \
      | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')"
    case "$ip" in *.*.*.*) break ;; esac
    sleep 10
  done
  case "$ip" in
    *.*.*.*) ;;
    *) log "FATAL: no IPv4 lease for $name after 10m"; return 1 ;;
  esac

  # sshd waits on firstboot (IIS install + reboot on rename): allow 30 min
  local ok=0 opts; opts="$(_win_ssh_opts)"
  for i in $(seq 1 180); do
    # shellcheck disable=SC2086
    if ssh -i "$DAP_KEY_FILE" $opts -o ConnectTimeout=8 \
        "$WIN_SSH_USER@$ip" 'exit 0' 2>/dev/null; then ok=1; break; fi
    sleep 10
  done
  [ "$ok" = 1 ] || { log "FATAL: ssh never came up for $platform ($ip)"; return 1; }

  # provenance gate — the guest must self-report the image we asked for
  local image_name
  image_name="$(win_ssh "$ip" "(Get-ItemProperty HKLM:\\SOFTWARE\\ImageRelease).IMAGE_NAME" | tr -d '\r' | tail -1)"
  if [ "$image_name" != "${vol%.qcow2}" ]; then
    log "FATAL: guest reports IMAGE_NAME='$image_name', expected '${vol%.qcow2}'"
    return 1
  fi

  # the role install finishes after sshd; wait for its stamp (15 min)
  for i in $(seq 1 90); do
    if win_ssh "$ip" "Test-Path C:\\bootstrap\\iis.done" | tr -d '\r' | grep -q True; then
      log "$platform IIS provisioning complete"; break
    fi
    sleep 10
  done
  echo "$ip"
}

win_ssh() { local ip="$1"; shift; local opts; opts="$(_win_ssh_opts)"
  # shellcheck disable=SC2086
  ssh -i "$DAP_KEY_FILE" $opts -o ConnectTimeout=15 "$WIN_SSH_USER@$ip" "$@"; }
win_scp_to() { local src="$1" ip="$2" dst="$3"; local opts; opts="$(_win_ssh_opts)"
  # shellcheck disable=SC2086
  scp -q -i "$DAP_KEY_FILE" $opts -r "$src" "$WIN_SSH_USER@$ip:$dst"; }
win_scp_back() { local ip="$1" src="$2" dst="$3"; local opts; opts="$(_win_ssh_opts)"
  # shellcheck disable=SC2086
  scp -q -i "$DAP_KEY_FILE" $opts -r "$WIN_SSH_USER@$ip:$src" "$dst"; }

# Run a local .ps1 on the guest. Copy-then-execute, never a stdin pipe: the
# golden images set PowerShell as the SSH default shell, so piping a script
# into `powershell -Command -` nests one PowerShell inside another and the
# script silently produces nothing (empty stdout, empty stderr, exit 0).
win_run_ps1() {
  local ip="$1" script="$2" remote
  remote="C:/Windows/Temp/$(basename "$script")"
  win_scp_to "$script" "$ip" "$remote"
  win_ssh "$ip" "powershell -NoProfile -ExecutionPolicy Bypass -File $remote"
}

# Same, with DAP_GROUP / DAP_PROFILE exported into the guest session so a
# probe body can be reused across apps and entities.
win_run_ps1_env() {
  local ip="$1" script="$2" remote
  remote="C:/Windows/Temp/$(basename "$script")"
  win_scp_to "$script" "$ip" "$remote"
  win_ssh "$ip" "\$env:DAP_GROUP='${DAP_GROUP:-}'; \$env:DAP_PROFILE='${DAP_PROFILE:-}'; powershell -NoProfile -ExecutionPolicy Bypass -File $remote"
}

win_destroy_platform() {
  local workdir="$WIN_WORK_ROOT/$1"
  [ -f "$workdir/terraform.tfstate" ] || { rm -rf "$workdir"; return 0; }
  log "destroying $1"
  "$TOFU" -chdir="$workdir" destroy -auto-approve -input=false \
    -var "libvirt_uri=$LIBVIRT_URI" -var image=x -var name=x \
    -var "admin_password=x" -var 'ssh_authorized_keys=[]' >/dev/null 2>&1 || true
  rm -rf "$workdir"
}

win_teardown() {
  set +e
  local workdir
  for workdir in "$WIN_WORK_ROOT"/*/; do
    [ -d "$workdir" ] || continue
    win_destroy_platform "$(basename "$workdir")"
  done
  win_sweep
  if [ -n "$DAP_KEY_DIR" ] && [ -d "$DAP_KEY_DIR" ]; then
    shred -u "$DAP_KEY_FILE" "$DAP_KEY_FILE.pub" 2>/dev/null
    rmdir "$DAP_KEY_DIR" 2>/dev/null
  fi
  log "teardown done"
  set -e
}

# --- sweep: reap stray dap-* windows domains/volumes ----------------------
win_sweep() {
  local d v
  # match the whole dap- prefix, not just well-formed suffixes: a malformed
  # name must never be able to strand a VM outside the sweep's reach
  for d in $(virsh -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep -E '^dap-'); do
    log "sweeping domain $d"
    virsh -c "$LIBVIRT_URI" destroy "$d" >/dev/null 2>&1
    # --nvram: UEFI domains leave an NVRAM file that blocks re-definition
    virsh -c "$LIBVIRT_URI" undefine "$d" --nvram >/dev/null 2>&1
  done
  for v in $(virsh -c "$LIBVIRT_URI" vol-list "$DAP_VM_POOL" 2>/dev/null \
      | awk '{print $1}' | grep -E '^dap-'); do
    log "sweeping volume $v"
    virsh -c "$LIBVIRT_URI" vol-delete "$v" --pool "$DAP_VM_POOL" >/dev/null 2>&1
  done
  return 0
}

win_dry_run() {
  log "DRY RUN — resolving Windows images at $LIBVIRT_URI, launching nothing"
  local fail=0 p jump
  [ -x "$TOFU" ] || command -v "$TOFU" >/dev/null 2>&1 || { log "MISSING: tofu ($TOFU)"; fail=1; }
  [ -d "$HOLY_QCOW_SRC/tofu/modules/windows-vm" ] \
    || { log "MISSING: $HOLY_QCOW_SRC/tofu/modules/windows-vm"; fail=1; }
  jump="$(win_jump)"; [ -n "$jump" ] && log "guest ssh will ProxyJump via $jump"
  for p in windows-2022 windows-2025; do
    printf '  %-14s %s\n' "$p" "$(win_image_for "$p" 2>/dev/null || echo 'UNRESOLVED')" >&2
    win_image_for "$p" >/dev/null 2>&1 || fail=1
  done
  return $fail
}
