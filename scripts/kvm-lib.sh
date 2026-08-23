#!/usr/bin/env bash
# kvm-lib.sh — shared KVM launch/teardown for the capture and verify drivers.
# The KVM counterpart of ec2-lib.sh, driving holy-qcow golden images instead
# of AMIs: same authoritative surface (authselect, real PAM/sshd, SELinux or
# AppArmor, systemd-logind) on our own CIS-hardened images, no cloud account.
#
# VMs are provisioned with OpenTofu through holy-qcow's tofu/modules/vm,
# consumed in place from a sibling checkout (HOLY_QCOW_SRC). The libvirt URI
# may be local (qemu:///system) or remote (qemu+ssh://user@host/system). NAT
# guests on a remote host are only reachable *from that host*, so guest ssh
# hops through it automatically (ProxyJump derived from the URI).
#
# Safety: throwaway domains all carry the dap- name prefix; teardown is an
# EXIT/INT/TERM trap that destroys via tofu AND reaps by prefix (launch runs
# in command substitution — a subshell — so on-disk workdirs plus the name
# prefix are the authoritative record, never a parent-scope array; the same
# lesson as ec2-lib's RunId tag). `sweep` reaps strays without any tfstate.
#
# Source this; then call kvm_launch / kvm_ssh / kvm_scp_back / kvm_teardown,
# or run the driver's `sweep` / `--dry-run`.
set -euo pipefail

: "${LIBVIRT_URI:=qemu:///system}"
: "${DAP_GOLDEN_POOL:=golden}"
: "${DAP_VM_POOL:=vmdisks}"
: "${KVM_SSH_USER:=ops}"

_KVMLIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HOLY_QCOW_SRC:=$_KVMLIB_REPO/../md}"
KVM_WORK_ROOT="$_KVMLIB_REPO/out/kvm"

# tofu and the mkisofs shim (exec'd by the libvirt provider for the seed
# ISO) may live in ~/.local/bin without being on a non-interactive PATH
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
TOFU="${TOFU:-$(command -v tofu || echo "$HOME/.local/bin/tofu")}"

log() { echo "[kvm] $*" >&2; }

# --- guest ssh hop --------------------------------------------------------
# qemu+ssh://user@host/system → NAT guests live behind user@host. Derive the
# jump automatically; DAP_SSH_JUMP=none forces a direct connection.
kvm_jump() {
  if [ -n "${DAP_SSH_JUMP:-}" ]; then
    [ "$DAP_SSH_JUMP" = "none" ] || echo "$DAP_SSH_JUMP"
    return 0
  fi
  case "$LIBVIRT_URI" in
    qemu+ssh://*) echo "$LIBVIRT_URI" | sed 's|^qemu+ssh://||; s|/.*$||' ;;
  esac
}

_kvm_ssh_opts() {
  local jump; jump="$(kvm_jump)"
  echo "-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR${jump:+ -o ProxyJump=$jump}"
}

# --- image resolution (latest published build; never hardcode) ------------
kvm_slug_for() {
  case "$1" in
    almalinux-9) echo alma9 ;;
    almalinux-10) echo alma10 ;;
    ubuntu-24.04) echo ubuntu2404 ;;
    ubuntu-26.04) echo ubuntu2604 ;;
    amazonlinux-2023) echo al2023 ;;
    *) echo "unknown distro $1" >&2; return 1 ;;
  esac
}

# Latest <slug>-YYYYMMDD.qcow2 in the golden pool (dates sort lexically).
# Pin override: DAP_IMAGE_<slug> (e.g. DAP_IMAGE_alma9=alma9-20260822.qcow2).
kvm_image_for() {
  local distro="$1" slug pin vol
  slug="$(kvm_slug_for "$distro")" || return 1
  pin="$(eval "echo \${DAP_IMAGE_${slug}:-}")"
  if [ -n "$pin" ]; then echo "$pin"; return 0; fi
  vol="$(virsh -c "$LIBVIRT_URI" vol-list "$DAP_GOLDEN_POOL" 2>/dev/null \
    | awk '{print $1}' | grep -E "^${slug}-[0-9]{8}\.qcow2$" | sort | tail -1)"
  [ -n "$vol" ] || { log "FATAL: no ${slug}-*.qcow2 in pool $DAP_GOLDEN_POOL at $LIBVIRT_URI"; return 1; }
  echo "$vol"
}

# --- ephemeral keypair ----------------------------------------------------
DAP_KEY_DIR="" DAP_KEY_FILE=""

kvm_setup_key() {
  DAP_KEY_DIR="$(mktemp -d)"
  DAP_KEY_FILE="$DAP_KEY_DIR/dap-kvm"
  ssh-keygen -q -t ed25519 -N "" -C "dap-kvm-ephemeral" -f "$DAP_KEY_FILE"
  log "ephemeral key $DAP_KEY_FILE"
}

# --- launch one VM; echoes its IPv4; workdir is the teardown record -------
kvm_launch() {
  local distro="$1" vol name workdir ip
  vol="$(kvm_image_for "$distro")" || return 1
  name="dap-$(kvm_slug_for "$distro")"
  workdir="$KVM_WORK_ROOT/$distro"
  mkdir -p "$workdir"
  sed "s|@@VM_MODULE_SOURCE@@|$HOLY_QCOW_SRC/tofu/modules/vm|" \
    "$_KVMLIB_REPO/scripts/kvm/main.tf.tmpl" > "$workdir/main.tf"

  log "launching $distro ($vol) as $name via $LIBVIRT_URI"
  "$TOFU" -chdir="$workdir" init -input=false >/dev/null
  "$TOFU" -chdir="$workdir" apply -auto-approve -input=false \
    -var "libvirt_uri=$LIBVIRT_URI" \
    -var "image=$vol" \
    -var "name=$name" \
    -var "ssh_authorized_keys=[\"$(cat "$DAP_KEY_FILE.pub")\"]" >/dev/null

  ip="$("$TOFU" -chdir="$workdir" output -raw ip 2>/dev/null || true)"
  # wait_for_lease can hand back nothing or an IPv6 link-local; the dnsmasq
  # lease table on the (possibly remote) host is authoritative — poll it.
  local i
  for i in $(seq 1 30); do
    case "$ip" in *.*.*.*) break ;; esac
    sleep 5
    ip="$(virsh -c "$LIBVIRT_URI" domifaddr "$name" --source lease 2>/dev/null \
      | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')"
  done
  case "$ip" in
    *.*.*.*) ;;
    *) log "FATAL: no IPv4 lease for $name after 150s"; return 1 ;;
  esac

  # wait for sshd
  local ok=0 opts; opts="$(_kvm_ssh_opts)"
  for i in $(seq 1 40); do
    # shellcheck disable=SC2086
    if ssh -i "$DAP_KEY_FILE" $opts -o ConnectTimeout=5 \
        "$KVM_SSH_USER@$ip" true 2>/dev/null; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] || { log "FATAL: ssh never came up for $distro ($ip)"; return 1; }

  # provenance gate: the guest must self-report the image we asked for
  local image_name
  image_name="$(kvm_ssh "$ip" "$KVM_SSH_USER" \
    '. /etc/image-release 2>/dev/null && echo "$IMAGE_NAME"' | tail -1)"
  if [ "$image_name" != "${vol%.qcow2}" ]; then
    log "FATAL: guest reports IMAGE_NAME='$image_name', expected '${vol%.qcow2}'"
    return 1
  fi
  echo "$ip"
}

kvm_ssh() { local ip="$1" u="$2"; shift 2; local opts; opts="$(_kvm_ssh_opts)"
  # shellcheck disable=SC2086
  ssh -i "$DAP_KEY_FILE" $opts -o ConnectTimeout=10 "$u@$ip" "$@"; }
kvm_scp_to() { local src="$1" ip="$2" u="$3" dst="$4"; local opts; opts="$(_kvm_ssh_opts)"
  # shellcheck disable=SC2086
  scp -q -i "$DAP_KEY_FILE" $opts -r "$src" "$u@$ip:$dst"; }
kvm_scp_back() { local ip="$1" u="$2" src="$3" dst="$4"; local opts; opts="$(_kvm_ssh_opts)"
  # shellcheck disable=SC2086
  scp -q -i "$DAP_KEY_FILE" $opts -r "$u@$ip:$src" "$dst"; }

# destroy one distro's harness VM and drop its workdir; safe if none exists.
# Drivers call this between distros so a 5-distro sweep never holds more than
# one idle guest's RAM.
kvm_destroy_distro() {
  local workdir="$KVM_WORK_ROOT/$1"
  [ -f "$workdir/terraform.tfstate" ] || { rm -rf "$workdir"; return 0; }
  log "destroying $1"
  "$TOFU" -chdir="$workdir" destroy -auto-approve -input=false \
    -var "libvirt_uri=$LIBVIRT_URI" -var image=x -var name=x \
    -var 'ssh_authorized_keys=[]' >/dev/null 2>&1 || true
  rm -rf "$workdir"
}

# --- teardown (idempotent; safe as an EXIT trap) --------------------------
kvm_teardown() {
  set +e
  local workdir
  for workdir in "$KVM_WORK_ROOT"/*/; do
    [ -d "$workdir" ] || continue
    kvm_destroy_distro "$(basename "$workdir")"
  done
  kvm_sweep
  if [ -n "$DAP_KEY_DIR" ] && [ -d "$DAP_KEY_DIR" ]; then
    shred -u "$DAP_KEY_FILE" "$DAP_KEY_FILE.pub" 2>/dev/null
    rmdir "$DAP_KEY_DIR" 2>/dev/null
  fi
  log "teardown done"
  set -e
}

# scoped teardown for parallel per-distro driver runs: touches only the
# distros this run owns (the global kvm_teardown sweeps every dap-* guest
# and would reap a sibling run's VM). Drivers set DAP_TRAP_DISTROS before
# installing the trap.
DAP_TRAP_DISTROS=""
kvm_teardown_scoped() {
  set +e
  local d
  for d in $DAP_TRAP_DISTROS; do kvm_destroy_distro "$d"; done
  if [ -n "$DAP_KEY_DIR" ] && [ -d "$DAP_KEY_DIR" ]; then
    shred -u "$DAP_KEY_FILE" "$DAP_KEY_FILE.pub" 2>/dev/null
    rmdir "$DAP_KEY_DIR" 2>/dev/null
  fi
  set -e
}

# --- sweep: reap any dap-* domain/volume, tfstate or not ------------------
kvm_sweep() {
  local d v
  for d in $(virsh -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep '^dap-'); do
    log "sweeping domain $d"
    virsh -c "$LIBVIRT_URI" destroy "$d" >/dev/null 2>&1
    virsh -c "$LIBVIRT_URI" undefine "$d" --nvram >/dev/null 2>&1
  done
  for v in $(virsh -c "$LIBVIRT_URI" vol-list "$DAP_VM_POOL" 2>/dev/null \
      | awk '{print $1}' | grep '^dap-'); do
    log "sweeping volume $v"
    virsh -c "$LIBVIRT_URI" vol-delete "$v" --pool "$DAP_VM_POOL" >/dev/null 2>&1
  done
  return 0
}

# --- dry-run: resolve every image + preflight, launch nothing -------------
kvm_dry_run() {
  log "DRY RUN — resolving images at $LIBVIRT_URI, launching nothing"
  local fail=0 d jump
  [ -x "$TOFU" ] || command -v "$TOFU" >/dev/null 2>&1 || { log "MISSING: tofu ($TOFU)"; fail=1; }
  [ -d "$HOLY_QCOW_SRC/tofu/modules/vm" ] \
    || { log "MISSING: HOLY_QCOW_SRC module dir $HOLY_QCOW_SRC/tofu/modules/vm"; fail=1; }
  virsh -c "$LIBVIRT_URI" pool-info "$DAP_GOLDEN_POOL" >/dev/null 2>&1 \
    || { log "MISSING: pool $DAP_GOLDEN_POOL at $LIBVIRT_URI"; fail=1; }
  virsh -c "$LIBVIRT_URI" pool-info "$DAP_VM_POOL" >/dev/null 2>&1 \
    || { log "MISSING: pool $DAP_VM_POOL at $LIBVIRT_URI"; fail=1; }
  jump="$(kvm_jump)"
  [ -n "$jump" ] && log "guest ssh will ProxyJump via $jump"
  for d in $(python3 -c "
import yaml; m = yaml.safe_load(open('$_KVMLIB_REPO/matrix.yml'))
print(' '.join(m['distros']))"); do
    printf '  %-18s %s\n' "$d" "$(kvm_image_for "$d" 2>/dev/null || echo 'UNRESOLVED')" >&2
    kvm_image_for "$d" >/dev/null 2>&1 || fail=1
  done
  return $fail
}
