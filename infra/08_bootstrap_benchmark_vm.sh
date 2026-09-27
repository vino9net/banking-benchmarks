#!/usr/bin/env bash
# Clones this repo onto the bench VM so its k6/node benchmark scripts are available
# there. Tries a plain (public) clone first; if BANKING_BENCHMARKS_REPO_URL turns out
# to be private, falls back to an interactive GitHub-token prompt (same pattern as
# core-sim needed before it went public — see git history of
# 04_bootstrap_core_sim_vm.sh if you need that flow again for some other private repo).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

ip="$(state_get BENCHMARK_PUBLIC_IP)"
[ -n "$ip" ] || die "no BENCHMARK_PUBLIC_IP in state — run 07_launch_benchmark_vm.sh first"

if ssh_run "$ip" '[ -d ~/banking-benchmarks/.git ]' 2>/dev/null; then
    info "banking-benchmarks already cloned on $ip, pulling latest"
    ssh_run "$ip" 'cd ~/banking-benchmarks && git pull --ff-only'
else
    info "cloning ${BANKING_BENCHMARKS_REPO_URL} on $ip"
    if ssh_run "$ip" "git clone --depth 1 '${BANKING_BENCHMARKS_REPO_URL}' ~/banking-benchmarks" 2>/tmp/bb-clone.err; then
        :
    else
        cat /tmp/bb-clone.err >&2
        warn "public clone failed — assuming the repo is private, prompting for a token"
        : "${GITHUB_TOKEN:=}"
        if [ -z "$GITHUB_TOKEN" ]; then
            read -rsp "GitHub personal access token (needs 'repo' scope): " GITHUB_TOKEN
            echo
        fi
        [ -n "$GITHUB_TOKEN" ] || die "no token provided"
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
            "${SSH_USER}@${ip}" "GITHUB_TOKEN='${GITHUB_TOKEN}' bash -s" <<REMOTE
set -euo pipefail
git -c credential.helper='!f() { echo "username=x-access-token"; echo "password=\${GITHUB_TOKEN}"; }; f' \
    clone --depth 1 "${BANKING_BENCHMARKS_REPO_URL}" ~/banking-benchmarks
REMOTE
        unset GITHUB_TOKEN
    fi
    rm -f /tmp/bb-clone.err
fi

# cloud-init locked the nginx reverse proxy in front of k6's web dashboard behind a
# random password nobody was ever told (see cloud-init/benchmark.sh) — replace it with
# one you actually have, now, interactively. Secrets are always set this way in this
# repo, never baked into cloud-init (AGENTS.md), and never passed as a command-line
# arg here either (visible via `ps` on the VM to any other local user) — piped over
# stdin, through the already-encrypted SSH channel, to `htpasswd -i` instead.
: "${DASHBOARD_USER:=admin}"
[[ "$DASHBOARD_USER" =~ ^[A-Za-z0-9_-]+$ ]] || die "DASHBOARD_USER must be alphanumeric/-/_ (got: ${DASHBOARD_USER})"
: "${DASHBOARD_PASSWORD:=}"
if [ -z "$DASHBOARD_PASSWORD" ]; then
    read -rsp "Password for the k6 dashboard (user '${DASHBOARD_USER}'), or blank to generate one: " DASHBOARD_PASSWORD
    echo
fi
if [ -z "$DASHBOARD_PASSWORD" ]; then
    DASHBOARD_PASSWORD="$(openssl rand -base64 18)"
    info "generated a dashboard password (shown below, not stored anywhere else — save it now)"
fi
printf '%s\n' "$DASHBOARD_PASSWORD" | ssh_run "$ip" "sudo htpasswd -Bic /etc/nginx/k6-dashboard.htpasswd '${DASHBOARD_USER}' && sudo systemctl reload nginx"

core_sim_private_ip="$(state_get CORE_SIM_PRIVATE_IP)"
core_sim_public_ip="$(state_get CORE_SIM_PUBLIC_IP)"
appsync_url="$(awsc cloudformation describe-stacks --stack-name "$ACCOUNT_INQUIRY_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='AccountInquiryApiUrl'].OutputValue" --output text 2>/dev/null || true)"

cat <<EOF

benchmark VM ready: $ip
  redis-cli, node, k6, tmux, git installed. banking-benchmarks cloned to ~/banking-benchmarks.

  For Redis specifically, use core-sim's PRIVATE IP from this VM, not its public one —
  confirmed against a real run that \`redis-cli -h ${core_sim_public_ip:-<unset>}\` from
  here hangs, while \`redis-cli -h ${core_sim_private_ip:-<unset>}\` works immediately.
  core-sim's HTTP API (port 8000) works fine via either IP from here — the difference is
  that Redis's security-group rule is a *self-reference* (allow from this same security
  group), and AWS only matches that kind of rule against an instance's private IP, never
  its public one, even from another member of the same group.

  core-sim HTTP API : http://${core_sim_private_ip:-<unset>}:${CORE_SIM_PORT}   (from this VM; also works via the public IP)
                       http://${core_sim_public_ip:-<unset>}:${CORE_SIM_PORT}   (from outside the VPC)
  AppSync GraphQL    : ${appsync_url:-<run: aws cloudformation describe-stacks --stack-name $ACCOUNT_INQUIRY_STACK>}
  Redis (SG-internal): redis-cli -h ${core_sim_private_ip:-<unset>} ping   (must be the private IP)

  k6 dashboard       : http://${ip}/   or   https://${ip}/  (self-signed cert — expect a
                       browser warning, this VM has no DNS name to get a real one for)
                       user '${DASHBOARD_USER}', password: ${DASHBOARD_PASSWORD}
                       Only shows anything while a run has K6_WEB_DASHBOARD=true set
                       (see dynamodb-ingestion/README.md) — 502 between runs is expected.

Both VMs share IAM role ${IAM_ROLE_NAME} — AppSync queries from this VM authenticate via
that role's instance credentials automatically (SigV4), no separate credentials needed.

Infrastructure setup is done. Individual benchmarks (k6 scripts, results) live in their
own directories at the repo root — see docs/infrastructure-setup.md for how to run one.
EOF
