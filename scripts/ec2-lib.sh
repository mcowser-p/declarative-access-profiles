#!/usr/bin/env bash
# ec2-lib.sh — shared EC2 launch/teardown for the capture and verify drivers.
#
# Why EC2 and not containers: a real AlmaLinux/Ubuntu AMI carries the OS auth
# surface containers miss — authselect, real /etc/pam.d/sshd, SELinux
# ENFORCING, systemd-logind, real sshd+PAM. That surface is the whole point
# of the access model, so both capture and verify run here.
#
# Cost controls (hard ceiling): every instance self-terminates on shutdown,
# a `shutdown -h +MAX_MINUTES` watchdog fires even if this driver dies, an
# EXIT/INT/TERM trap terminates instances, everything is TTL-tagged, and
# `sweep` reaps strays. Smallest instances, gp3 8GB delete-on-terminate.
#
# Source this; then call ec2_launch / ec2_ssh / ec2_scp_back / ec2_teardown,
# or run the driver's `sweep` / `--dry-run`.
set -euo pipefail

: "${AWS_REGION:=us-west-2}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

DAP_PROJECT_TAG="dap-ec2"
DAP_ITYPE="${DAP_ITYPE:-t3.small}"
DAP_MAX_MINUTES="${DAP_MAX_MINUTES:-30}"     # per-instance self-terminate watchdog
DAP_TTL_HOURS="${DAP_TTL_HOURS:-2}"          # sweep threshold

# Per-instance on-demand $/hr (us-west-2), for the running spend estimate.
# (function, not an associative array — macOS ships bash 3.2)
dap_rate() {
  case "$1" in
    t3.micro) echo 0.0104 ;; t3.small) echo 0.0208 ;;
    t3.medium) echo 0.0416 ;; *) echo 0.0208 ;;
  esac
}
DAP_SPEND_FILE="${TMPDIR:-/tmp}/dap-ec2-spend.$$"
echo 0 > "$DAP_SPEND_FILE"

log() { echo "[ec2] $*" >&2; }

# --- AMI resolution (dynamic — never hardcode) ----------------------------
ec2_ami_for() {
  local distro="$1"
  case "$distro" in
    ubuntu-24.04)
      aws ssm get-parameter \
        --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
        --query Parameter.Value --output text ;;
    almalinux-9|almalinux-10)
      local v="${distro##*-}"
      aws ec2 describe-images --owners 764336703387 \
        --filters "Name=name,Values=AlmaLinux OS ${v}*" \
                  "Name=architecture,Values=x86_64" \
                  "Name=state,Values=available" \
        --query 'sort_by(Images[?!contains(Name,`Beta`) && !contains(Name,`beta`)], &CreationDate)[-1].ImageId' \
        --output text ;;
    *) echo "unknown distro $distro" >&2; return 1 ;;
  esac
}

ec2_ssh_user() { case "$1" in ubuntu-24.04) echo ubuntu ;; *) echo ec2-user ;; esac; }

# --- ephemeral SG (SSH from THIS host's /32 only) + keypair ---------------
DAP_RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$$"
DAP_SG_ID="" DAP_KEY_NAME="" DAP_KEY_FILE="" ; declare -a DAP_INSTANCES=()

ec2_setup_sg_key() {
  local myip vpc
  myip="$(curl -s https://checkip.amazonaws.com)"
  vpc="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  DAP_SG_ID="$(aws ec2 create-security-group \
    --group-name "dap-ec2-$DAP_RUN_ID" --vpc-id "$vpc" \
    --description "dap ephemeral $DAP_RUN_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$DAP_PROJECT_TAG},{Key=RunId,Value=$DAP_RUN_ID}]" \
    --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --group-id "$DAP_SG_ID" \
    --protocol tcp --port 22 --cidr "${myip}/32" >/dev/null
  DAP_KEY_NAME="dap-ec2-$DAP_RUN_ID"
  DAP_KEY_FILE="${TMPDIR:-/tmp}/${DAP_KEY_NAME}.pem"
  aws ec2 create-key-pair --key-name "$DAP_KEY_NAME" \
    --query KeyMaterial --output text > "$DAP_KEY_FILE"
  chmod 600 "$DAP_KEY_FILE"
  log "SG $DAP_SG_ID (ssh from ${myip}/32), key $DAP_KEY_NAME"
}

# --- launch one instance; echoes its public IP; records it for teardown ---
ec2_launch() {
  local distro="$1" ami subnet iid ip ud
  ami="$(ec2_ami_for "$distro")"
  subnet="$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' --output text)"
  ud="${TMPDIR:-/tmp}/dap-ud-$distro.sh"
  # watchdog: hard self-terminate after DAP_MAX_MINUTES no matter what
  cat > "$ud" <<EOF
#!/bin/bash
shutdown -h +${DAP_MAX_MINUTES} "dap watchdog" &
EOF
  log "launching $distro ($ami, $DAP_ITYPE)"
  iid="$(aws ec2 run-instances \
    --image-id "$ami" --instance-type "$DAP_ITYPE" \
    --key-name "$DAP_KEY_NAME" \
    --network-interfaces "DeviceIndex=0,SubnetId=$subnet,Groups=$DAP_SG_ID,AssociatePublicIpAddress=true" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=8,VolumeType=gp3,DeleteOnTermination=true}' \
    --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
    --instance-initiated-shutdown-behavior terminate \
    --user-data "file://$ud" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$DAP_PROJECT_TAG},{Key=RunId,Value=$DAP_RUN_ID},{Key=Distro,Value=$distro},{Key=Name,Value=dap-$distro-$DAP_RUN_ID}]" \
    --query 'Instances[0].InstanceId' --output text)"
  DAP_INSTANCES+=("$iid")
  aws ec2 wait instance-running --instance-ids "$iid"
  ip="$(aws ec2 describe-instances --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  # wait for sshd
  local u; u="$(ec2_ssh_user "$distro")"
  local ok=0 i
  for i in $(seq 1 40); do
    if ssh -i "$DAP_KEY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
        "$u@$ip" true 2>/dev/null; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] || { log "FATAL: ssh never came up for $distro ($ip)"; return 1; }
  echo "$ip"
}

ec2_ssh()  { local ip="$1" u="$2"; shift 2; ssh -i "$DAP_KEY_FILE" -o BatchMode=yes \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$u@$ip" "$@"; }
ec2_scp_to() { local src="$1" ip="$2" u="$3" dst="$4"; scp -q -i "$DAP_KEY_FILE" -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -r "$src" "$u@$ip:$dst"; }
ec2_scp_back() { local ip="$1" u="$2" src="$3" dst="$4"; scp -q -i "$DAP_KEY_FILE" -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -r "$u@$ip:$src" "$dst"; }

# --- teardown (idempotent; safe as an EXIT trap) --------------------------
# Terminates by RunId TAG, not a bash array: ec2_launch runs inside command
# substitution (a subshell), so a parent-scope array would miss every
# instance. The tag is set at run-instances time and is authoritative.
ec2_teardown() {
  set +e
  local ids
  ids="$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$DAP_PROJECT_TAG" "Name=tag:RunId,Values=$DAP_RUN_ID" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
  if [ -n "$ids" ]; then
    log "terminating: $ids"
    aws ec2 terminate-instances --instance-ids $ids >/dev/null 2>&1
    aws ec2 wait instance-terminated --instance-ids $ids 2>/dev/null
  fi
  [ -n "$DAP_SG_ID" ] && aws ec2 delete-security-group --group-id "$DAP_SG_ID" >/dev/null 2>&1
  [ -n "$DAP_KEY_NAME" ] && aws ec2 delete-key-pair --key-name "$DAP_KEY_NAME" >/dev/null 2>&1
  [ -n "$DAP_KEY_FILE" ] && rm -f "$DAP_KEY_FILE"
  log "teardown done. estimated spend this run: \$$(cat "$DAP_SPEND_FILE" 2>/dev/null)"
  rm -f "$DAP_SPEND_FILE"
}

# add an instance's worth of wall-clock minutes to the running estimate
ec2_charge() {
  local mins="$1" rate; rate="$(dap_rate "$DAP_ITYPE")"
  python3 -c "
cur=float(open('$DAP_SPEND_FILE').read() or 0)
cur += $mins/60.0*$rate
open('$DAP_SPEND_FILE','w').write(f'{cur:.4f}')
print(f'[ec2] running spend estimate: \${cur:.4f}')" >&2
}

# --- sweep: reap anything tagged Project=dap-ec2 older than N hours --------
ec2_sweep() {
  local hours="${1:-$DAP_TTL_HOURS}"
  local cutoff; cutoff="$(python3 -c "import datetime;print((datetime.datetime.utcnow()-datetime.timedelta(hours=$hours)).strftime('%Y-%m-%dT%H:%M:%S'))")"
  log "sweep: terminating dap-ec2 instances launched before ${cutoff}Z"
  local ids
  ids="$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$DAP_PROJECT_TAG" "Name=instance-state-name,Values=running,pending,stopped" \
    --query "Reservations[].Instances[?LaunchTime<='${cutoff}'].InstanceId" --output text)"
  [ -n "$ids" ] && aws ec2 terminate-instances --instance-ids $ids >/dev/null && log "swept: $ids" || log "nothing to sweep"
  # orphan SGs
  local sgs
  sgs="$(aws ec2 describe-security-groups --filters "Name=tag:Project,Values=$DAP_PROJECT_TAG" --query 'SecurityGroups[].GroupId' --output text)"
  for sg in $sgs; do aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 && log "deleted SG $sg" || true; done
}

# --- dry-run: resolve AMIs + print the estimate, launch nothing -----------
ec2_dry_run() {
  local n_capture=3 n_verify=3
  log "DRY RUN — resolving AMIs, launching nothing"
  for d in almalinux-9 almalinux-10 ubuntu-24.04; do
    printf '  %-14s %s\n' "$d" "$(ec2_ami_for "$d")" >&2
  done
  python3 -c "
r=$(dap_rate "$DAP_ITYPE")
cap=$n_capture*(30/60)*r; ver=$n_verify*(45/60)*r; ebs=6*(8*0.08/730)
print(f'[ec2] estimate ($DAP_ITYPE, us-west-2 on-demand):')
print(f'[ec2]   capture 3x~30min  \${cap:.3f}')
print(f'[ec2]   verify  3x~45min  \${ver:.3f}')
print(f'[ec2]   EBS gp3 8GB        \${ebs:.4f}')
print(f'[ec2]   TOTAL full run    \${cap+ver+ebs:.3f}   (watchdog worst case ~\${6*(30/60)*r+ebs:.3f})')" >&2
}
