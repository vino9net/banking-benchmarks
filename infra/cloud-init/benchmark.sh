#!/bin/bash
# EC2 user-data for the benchmark VM. Runs once, as root, on first boot.
set -euo pipefail
exec > /var/log/banking-benchmarks-setup.log 2>&1
echo "banking-benchmarks bench user-data starting: $(date -u)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    git tmux redis-tools nodejs npm build-essential curl ca-certificates gnupg

# k6: not packaged in Debian's main repo, install from the official apt source.
curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
    > /etc/apt/sources.list.d/k6.list
apt-get update
apt-get install -y --no-install-recommends k6

# uv, for account-inquiry's Python scripts (query_appsync.py) if run from here too.
sudo -u admin -H bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

touch /var/lib/cloud/banking-benchmarks-ready
echo "banking-benchmarks bench user-data finished: $(date -u)"
