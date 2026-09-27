#!/usr/bin/env bash
# Launches the core-sim VM: Debian 13 arm64, sized to hold 10M+ accounts and the
# idempotency-key leakage from tens of millions of transfers in Redis (see AGENTS.md).
# Only runs the non-interactive part of setup (base packages, Redis tuning) via
# user-data — cloning core-sim needs a GitHub token, done next in
# 04_bootstrap_core_sim_vm.sh over SSH.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

ami="$(debian13_ami arm64)"
info "using AMI $ami"

id="$(launch_instance "$CORE_SIM_NAME_TAG" "$CORE_SIM_INSTANCE_TYPE" "$CORE_SIM_VOLUME_GB" \
    "$ami" "$INFRA_DIR/cloud-init/core-sim.sh")"
state_set CORE_SIM_INSTANCE_ID "$id"

ip="$(instance_public_ip "$id")"
private_ip="$(instance_private_ip "$id")"
state_set CORE_SIM_PUBLIC_IP "$ip"
state_set CORE_SIM_PRIVATE_IP "$private_ip"
info "core-sim VM: $id @ $ip (private: $private_ip)"

wait_for_ssh "$ip"
wait_for_cloud_init "$ip"

cat <<EOF

core-sim VM is up: $ip (instance $id, private IP $private_ip)

Use the public IP ($ip) for anything outside this VPC (your laptop, an external load
generator). For Redis specifically, use the private IP ($private_ip) from the bench
VM — confirmed against a real run that \`redis-cli -h $ip ping\` from the bench VM hangs,
while \`redis-cli -h $private_ip ping\` works immediately. This isn't a general
"public IP doesn't work inside the VPC" thing (core-sim's HTTP API on port 8000 works
fine via either IP, confirmed the same way) — it's specific to Redis's security group
rule being a *self-reference* (\"allow from this same security group\"), and AWS only
matches that kind of rule against an instance's private IP, never its public one, even
from another instance in the same group.

Next: infra/04_bootstrap_core_sim_vm.sh
  (clones core-sim over SSH)
EOF
