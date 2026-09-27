#!/bin/bash
# EC2 user-data for the benchmark VM. Runs once, as root, on first boot.
set -euo pipefail
exec > /var/log/banking-benchmarks-setup.log 2>&1
echo "banking-benchmarks bench user-data starting: $(date -u)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    git tmux redis-tools nodejs npm build-essential curl ca-certificates \
    nginx apache2-utils ssl-cert openssl

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

# nginx reverse-proxies :80/:443 to k6's own web dashboard (127.0.0.1:5665, only
# listening while a run with K6_WEB_DASHBOARD=true is active) so you can check
# benchmark status from a browser instead of an SSH tunnel. :443 uses Debian's
# snakeoil self-signed cert (ssl-cert package) since this VM has no DNS name to get a
# real one for — browsers will show a certificate warning, which is expected here.
#
# Locked behind HTTP Basic Auth by default: a reverse proxy in front of a
# publicly-reachable dashboard with no auth is not a safe default. The password set
# here is a random placeholder nobody is ever told — 08_bootstrap_benchmark_vm.sh
# replaces it with an operator-chosen one right after launch. Secrets are set
# interactively there, never baked into cloud-init (see this repo's AGENTS.md).
htpasswd -bc /etc/nginx/k6-dashboard.htpasswd admin "$(openssl rand -base64 24)"

cat > /etc/nginx/sites-available/k6-dashboard <<'NGINX'
server {
    listen 80 default_server;
    listen 443 ssl default_server;
    server_name _;

    ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    auth_basic           "k6 dashboard";
    auth_basic_user_file /etc/nginx/k6-dashboard.htpasswd;

    location / {
        # Between runs (or before the first one) nothing is listening on 5665 and
        # this returns 502 — expected, not a misconfiguration.
        proxy_pass http://127.0.0.1:5665;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;  # the dashboard holds a long-lived connection open for live updates
    }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/k6-dashboard /etc/nginx/sites-enabled/k6-dashboard
systemctl enable nginx
systemctl restart nginx

touch /var/lib/cloud/banking-benchmarks-ready
echo "banking-benchmarks bench user-data finished: $(date -u)"
