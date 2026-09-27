#!/bin/bash
# EC2 user-data for the core-sim VM. Runs once, as root, on first boot. Handles only
# the non-interactive parts (base packages, Redis tuning) — cloning core-sim needs a
# GitHub token, which this script never has access to, so that happens later over SSH
# (04_bootstrap_core_sim_vm.sh).
set -euo pipefail
exec > /var/log/banking-benchmarks-setup.log 2>&1
echo "banking-benchmarks core-sim user-data starting: $(date -u)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    git tmux redis-server build-essential curl ca-certificates pkg-config

# Durability lives in the Kinesis log, not the ledger (core-sim/docs/ARCH_DESIGN.md
# §6.3/§6.4) — AOF/RDB here just cost throughput for a store that's designed to be
# reseeded, not recovered in place.
#
# Debian's shipped redis.conf has NO active `save` line — the default save points
# (3600 1 300 100 60 10000) are Redis's compiled-in default, applied when the conf file
# says nothing at all. A sed replace of `^save .*` is therefore a silent no-op here
# (confirmed against a real Debian 13 install); delete-then-append is the only way to
# actually turn it off.
sed -i '/^save /d' /etc/redis/redis.conf
echo 'save ""' >> /etc/redis/redis.conf
sed -i 's/^appendonly .*/appendonly no/' /etc/redis/redis.conf
# Redis has no auth of its own. The security group is the actual control here — only
# other members of the same SG (i.e. the bench VM) can reach 6379 at all (see
# 01_create_security_group.sh) — so it's safe to bind beyond loopback for the bench
# VM's ad hoc redis-cli use, but disable protected-mode explicitly since it would
# otherwise block that non-loopback, no-auth connection outright.
sed -i 's/^bind .*/bind 0.0.0.0 -::1/' /etc/redis/redis.conf
sed -i 's/^protected-mode .*/protected-mode no/' /etc/redis/redis.conf
systemctl enable redis-server
systemctl restart redis-server

# uv, installed as the login user (not root) since that's who runs core-sim.
sudo -u admin -H bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

touch /var/lib/cloud/banking-benchmarks-ready
echo "banking-benchmarks core-sim user-data finished: $(date -u)"
