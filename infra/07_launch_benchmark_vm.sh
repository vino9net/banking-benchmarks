#!/usr/bin/env bash
# Launches the benchmark VM: Debian 13 arm64, same security group + IAM instance
# profile as the core-sim VM (the task requires this), CPU-optimized sizing since k6
# and node are the load generator here, not the thing being measured.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

ami="$(debian13_ami arm64)"
info "using AMI $ami"

id="$(launch_instance "$BENCHMARK_NAME_TAG" "$BENCHMARK_INSTANCE_TYPE" "$BENCHMARK_VOLUME_GB" \
    "$ami" "$INFRA_DIR/cloud-init/benchmark.sh")"
state_set BENCHMARK_INSTANCE_ID "$id"

ip="$(instance_public_ip "$id")"
state_set BENCHMARK_PUBLIC_IP "$ip"
info "benchmark VM: $id @ $ip"

wait_for_ssh "$ip"
wait_for_cloud_init "$ip"

cat <<EOF

benchmark VM is up: $ip (instance $id)

Next: infra/08_bootstrap_benchmark_vm.sh
EOF
