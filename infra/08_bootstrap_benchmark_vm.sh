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

core_sim_ip="$(state_get CORE_SIM_PUBLIC_IP)"
appsync_url="$(awsc cloudformation describe-stacks --stack-name "$ACCOUNT_INQUIRY_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='AccountInquiryApiUrl'].OutputValue" --output text 2>/dev/null || true)"

cat <<EOF

benchmark VM ready: $ip
  redis-cli, node, k6, tmux, git installed. banking-benchmarks cloned to ~/banking-benchmarks.

  core-sim HTTP API : http://${core_sim_ip:-<unset>}:${CORE_SIM_PORT}
  AppSync GraphQL    : ${appsync_url:-<run: aws cloudformation describe-stacks --stack-name $ACCOUNT_INQUIRY_STACK>}
  Redis (SG-internal): ${core_sim_ip:-<unset>}:6379   # redis-cli -h <that ip> ping

Both VMs share IAM role ${IAM_ROLE_NAME} — AppSync queries from this VM authenticate via
that role's instance credentials automatically (SigV4), no separate credentials needed.

Infrastructure setup is done. Individual benchmarks (k6 scripts, results) live in their
own directories at the repo root — see docs/infrastructure-setup.md for how to run one.
EOF
