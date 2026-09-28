#!/bin/bash
# EC2 user-data for the benchmark VM. Runs once, as root, on first boot.
set -euo pipefail
exec > /var/log/banking-benchmarks-setup.log 2>&1
echo "banking-benchmarks bench user-data starting: $(date -u)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    git tmux redis-tools nodejs npm build-essential curl ca-certificates

# k6: NOT via dl.k6.io's apt repo — confirmed against the real repo that it only
# publishes amd64/i386 (`Architectures: amd64 i386` in its Release file), so on this
# arm64/Graviton box `apt-get install k6` fails with "Unable to locate package k6" even
# though the repo itself was added successfully. Grafana does publish an arm64 build,
# just as a GitHub-releases tarball rather than an apt package — install that instead,
# keyed off `dpkg --print-architecture` so this also works unchanged if the instance
# type ever moves back to x86_64.
k6_arch="$(dpkg --print-architecture)"
k6_url="$(curl -fsSL https://api.github.com/repos/grafana/k6/releases/latest \
    | grep -o "https://[^\"]*linux-${k6_arch}\.tar\.gz")"
curl -fsSL "$k6_url" -o /tmp/k6.tar.gz
tar -xzf /tmp/k6.tar.gz -C /tmp
install -m 0755 /tmp/k6-*/k6 /usr/local/bin/k6
rm -rf /tmp/k6.tar.gz /tmp/k6-*

# uv, for account-inquiry's Python scripts (query_appsync.py) if run from here too.
sudo -u admin -H bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

touch /var/lib/cloud/banking-benchmarks-ready
echo "banking-benchmarks bench user-data finished: $(date -u)"
