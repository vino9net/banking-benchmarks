#!/usr/bin/env bash
# Clones core-sim onto the sim VM and starts it (+ its relay) in tmux. core-sim is
# public, so this is a plain clone — no token needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

ip="$(state_get CORE_SIM_PUBLIC_IP)"
[ -n "$ip" ] || die "no CORE_SIM_PUBLIC_IP in state — run 03_launch_core_sim_vm.sh first"

if ssh_run "$ip" '[ -d ~/core-sim/.git ]' 2>/dev/null; then
    info "core-sim already cloned on $ip, pulling latest"
    ssh_run "$ip" 'cd ~/core-sim && git pull --ff-only'
else
    info "cloning core-sim on $ip"
    ssh_run "$ip" "git clone --depth 1 '${CORE_SIM_REPO_URL}' ~/core-sim"
fi

info "installing core-sim dependencies on $ip (uv sync)"
ssh_run "$ip" 'cd ~/core-sim && ~/.local/bin/uv sync --all-extras'

info "starting core-sim (app + relay) in tmux on $ip"
ssh_run "$ip" bash -s <<REMOTE
set -euo pipefail
cd ~/core-sim
tmux has-session -t core-sim 2>/dev/null && tmux kill-session -t core-sim
tmux new-session -d -s core-sim -n app
tmux send-keys -t core-sim:app '~/.local/bin/uv run core-sim' C-m
tmux new-window -t core-sim -n relay
# No KINESIS_STREAM set yet on purpose — publishing to the real "transfers" stream is
# only turned on once account-inquiry's DynamoDB table has been (re)seeded from Redis
# (06_reseed_dynamodb.sh), so early transfers don't race a table that doesn't have
# those accounts in it yet. Attach and re-run with KINESIS_STREAM=transfers when ready.
# AWS_DEFAULT_REGION is required explicitly — confirmed live that boto3 does not
# resolve region from EC2 instance metadata by default in this environment, and
# core-sim-relay's put_records() call fails with NoRegionError without it.
tmux send-keys -t core-sim:relay 'echo "run: AWS_DEFAULT_REGION=${AWS_REGION} KINESIS_STREAM=transfers ~/.local/bin/uv run core-sim-relay"' C-m
REMOTE

sleep 2
if ssh_run "$ip" 'curl -fsS -m 5 http://localhost:8000/health' >/dev/null 2>&1; then
    info "core-sim is up and healthy on $ip:${CORE_SIM_PORT}"
else
    warn "core-sim did not answer /health yet — check with: ssh ${SSH_USER}@${ip} tmux attach -t core-sim"
fi

cat <<EOF

core-sim is running on $ip:${CORE_SIM_PORT} (tmux session "core-sim", windows: app, relay)

Next: infra/05_seed_accounts.sh
EOF
