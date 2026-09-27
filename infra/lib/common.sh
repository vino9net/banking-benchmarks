#!/usr/bin/env bash
# Shared helpers for infra/*.sh. Sourced by config.sh — don't source this directly.

info()  { printf '\033[1;34m[info]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# --- tiny flat-file state store (infra/.state/env), so later scripts can pick up
# --- instance IDs / IPs resolved by earlier ones without re-querying AWS every time.
state_set() {
    local key="$1" val="$2" f="$STATE_DIR/env"
    touch "$f"
    grep -v "^${key}=" "$f" > "${f}.tmp" 2>/dev/null || true
    mv "${f}.tmp" "$f"
    printf '%s=%s\n' "$key" "$val" >> "$f"
}

state_get() {
    local key="$1" f="$STATE_DIR/env"
    [ -f "$f" ] && grep "^${key}=" "$f" | tail -n1 | cut -d= -f2- || true
}

# --- AWS CLI wrapper, always explicit about profile/region so this never silently
# --- touches whatever account happens to be the shell's ambient default.
awsc() {
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"
}

# --- latest official Debian 13 AMI for the given EC2 architecture (arm64 | x86_64).
# --- Debian's Cloud Team publishes these under AWS account 136693071363 — not an
# --- AWS-owned account, but the closest thing to "official" for a non-AWS-authored
# --- distro image; there is no AWS Marketplace substitute worth using here.
debian13_ami() {
    local arch="$1"
    awsc ec2 describe-images \
        --owners 136693071363 \
        --filters "Name=name,Values=debian-13-${arch}-*" \
                   "Name=state,Values=available" \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
        --output text
}

# --- block until an instance answers SSH, or give up after ~5 minutes.
wait_for_ssh() {
    local host="$1" tries=60
    info "waiting for SSH on $host ..."
    while ! ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
                "${SSH_USER}@${host}" true 2>/dev/null; do
        tries=$((tries - 1))
        [ "$tries" -gt 0 ] || die "timed out waiting for SSH on $host"
        sleep 5
    done
    info "SSH is up on $host"
}

# --- block until cloud-init's user-data script has finished running.
wait_for_cloud_init() {
    local host="$1" tries=60
    info "waiting for cloud-init to finish on $host ..."
    while ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new \
                -o UserKnownHostsFile=/dev/null "${SSH_USER}@${host}" \
                '[ -f /var/lib/cloud/banking-benchmarks-ready ]' 2>/dev/null; do
        tries=$((tries - 1))
        [ "$tries" -gt 0 ] || die "timed out waiting for cloud-init on $host"
        sleep 10
    done
    info "cloud-init finished on $host"
}

ssh_run() {
    local host="$1"; shift
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null "${SSH_USER}@${host}" "$@"
}

# --- launch (or reuse) a tagged EC2 instance. Prints its instance-id on stdout;
# --- everything else goes to stderr, so `id=$(launch_instance ...)` works cleanly.
#   $1 name tag   $2 instance type   $3 volume size GB   $4 AMI id   $5 user-data file
launch_instance() {
    local name="$1" itype="$2" vol_gb="$3" ami="$4" user_data_file="$5"

    local existing
    existing="$(awsc ec2 describe-instances \
        --filters "Name=tag:Name,Values=${name}" "Name=instance-state-name,Values=pending,running" \
        --query 'Reservations[].Instances[0].InstanceId' --output text)"
    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
        info "reusing existing instance $existing ($name)"
        printf '%s' "$existing"
        return
    fi

    local sg_id
    sg_id="$(state_get SG_ID)"
    [ -n "$sg_id" ] || die "no SG_ID in state — run 01_create_security_group.sh first"

    # Resolve the AMI's actual root device name rather than assuming /dev/xvda — get
    # this wrong and run-instances silently attaches an extra volume at the requested
    # size instead of resizing root, leaving the root volume at the AMI's default (8GB).
    local root_device
    root_device="$(awsc ec2 describe-images --image-ids "$ami" --query 'Images[0].RootDeviceName' --output text)"

    info "launching $name ($itype, ami $ami, root device $root_device)"
    local id
    id="$(awsc ec2 run-instances \
        --image-id "$ami" \
        --instance-type "$itype" \
        --key-name "$KEY_NAME" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$sg_id" \
        --associate-public-ip-address \
        --iam-instance-profile "Name=${IAM_INSTANCE_PROFILE_NAME}" \
        --block-device-mappings "[{\"DeviceName\":\"${root_device}\",\"Ebs\":{\"VolumeSize\":${vol_gb},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
        --user-data "file://${user_data_file}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=banking-benchmarks}]" \
        --query 'Instances[0].InstanceId' --output text)"

    info "waiting for $id to enter 'running' ..."
    awsc ec2 wait instance-running --instance-ids "$id"
    printf '%s' "$id"
}

instance_public_ip() {
    awsc ec2 describe-instances --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

instance_private_ip() {
    awsc ec2 describe-instances --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
}
