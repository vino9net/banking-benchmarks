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
state_set CORE_SIM_PUBLIC_IP "$ip"
info "core-sim VM: $id @ $ip"

wait_for_ssh "$ip"
wait_for_cloud_init "$ip"

cat <<EOF

core-sim VM is up: $ip (instance $id)

Next: infra/04_bootstrap_core_sim_vm.sh
  (clones core-sim over SSH)
EOF
