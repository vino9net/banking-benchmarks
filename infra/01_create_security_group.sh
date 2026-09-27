#!/usr/bin/env bash
# Creates one security group shared by both VMs (they need to talk to each other, and
# it's simpler than managing two). Idempotent: safe to re-run, e.g. after your IP
# changes — it updates the SSH rule in place rather than erroring on a duplicate.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

sg_id="$(awsc ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"

if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
    info "creating security group ${SG_NAME} in ${VPC_ID}"
    sg_id="$(awsc ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "banking-benchmarks: core-sim + bench VMs" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},{Key=Project,Value=banking-benchmarks}]" \
        --query 'GroupId' --output text)"
else
    info "reusing existing security group $sg_id"
fi
state_set SG_ID "$sg_id"

# --- SSH: open to 0.0.0.0/0 by request (admin's source IP moves around between VPNs).
# --- Traded off deliberately against the alternative (re-running this script on every
# --- IP change) — SSH is still gated by the m1air key pair, unlike the Redis case
# --- below, which has no such gate and stays restricted.
info "authorizing SSH (22) from 0.0.0.0/0"
awsc ec2 authorize-security-group-ingress --group-id "$sg_id" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0,Description=admin}]" \
    >/dev/null 2>&1 || true

# --- core-sim's HTTP API: public, on purpose — the task requires the sim VM be
# --- reachable "from the public internet" so a load generator can reach it, and the
# --- bench VM in this same setup already gets there via the SG's own rule below, so
# --- this rule is really for a load generator running somewhere else entirely.
info "authorizing core-sim HTTP (${CORE_SIM_PORT}) from 0.0.0.0/0"
awsc ec2 authorize-security-group-ingress --group-id "$sg_id" \
    --ip-permissions "IpProtocol=tcp,FromPort=${CORE_SIM_PORT},ToPort=${CORE_SIM_PORT},IpRanges=[{CidrIp=0.0.0.0/0,Description=core-sim-http}]" \
    >/dev/null 2>&1 || true

# --- Redis: NEVER public — it has no auth, and an internet-facing Redis with 10M+
# --- accounts sitting in it is a real incident, not a hypothetical one. Only other
# --- members of this same security group (i.e. the bench VM, for ad hoc redis-cli use)
# --- can reach it.
info "authorizing Redis (6379) from within the security group only"
awsc ec2 authorize-security-group-ingress --group-id "$sg_id" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":6379,\"ToPort\":6379,\"UserIdGroupPairs\":[{\"GroupId\":\"${sg_id}\",\"Description\":\"self\"}]}]" \
    >/dev/null 2>&1 || true

info "security group ready: $sg_id"
