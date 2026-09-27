#!/usr/bin/env bash
# Tears down everything the infra/*.sh scripts created: both instances, the security
# group, the IAM role/instance profile. Does NOT touch account-inquiry's CloudFormation
# stack (DynamoDB table, AppSync API, Kinesis stream, Lambda), the VPC/subnet, or the
# m1air key pair — none of those belong to this repo.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

for id_key in CORE_SIM_INSTANCE_ID BENCHMARK_INSTANCE_ID; do
    id="$(state_get "$id_key")"
    if [ -n "$id" ]; then
        info "terminating $id ($id_key)"
        awsc ec2 terminate-instances --instance-ids "$id" >/dev/null || warn "couldn't terminate $id (already gone?)"
    fi
done

for id_key in CORE_SIM_INSTANCE_ID BENCHMARK_INSTANCE_ID; do
    id="$(state_get "$id_key")"
    [ -n "$id" ] && awsc ec2 wait instance-terminated --instance-ids "$id" 2>/dev/null || true
done

sg_id="$(state_get SG_ID)"
if [ -n "$sg_id" ]; then
    info "deleting security group $sg_id"
    awsc ec2 delete-security-group --group-id "$sg_id" || warn "couldn't delete $sg_id yet — instances may still be detaching from it, retry in a minute"
fi

if awsc iam get-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
    info "removing role from instance profile and deleting it"
    awsc iam remove-role-from-instance-profile \
        --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" || true
    awsc iam delete-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" || true
fi

if awsc iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
    info "deleting IAM role $IAM_ROLE_NAME"
    awsc iam delete-role-policy --role-name "$IAM_ROLE_NAME" --policy-name "banking-benchmarks-access" || true
    awsc iam delete-role --role-name "$IAM_ROLE_NAME" || true
fi

rm -f "$STATE_DIR/env"
info "teardown complete"
