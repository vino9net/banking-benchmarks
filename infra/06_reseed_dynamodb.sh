#!/usr/bin/env bash
# Wipes and reseeds account-inquiry's DynamoDB table from core-sim's Redis, using
# account-inquiry's own scripts/seed_from_redis.py (public repo, no token needed).
#
# Runs FROM the core-sim VM, not locally and not from the bench VM: Redis is only
# reachable from inside the security group (never public — see
# 01_create_security_group.sh / the redis section of cloud-init/core-sim.sh), and the
# core-sim VM already holds the IAM role with DynamoDB + CloudFormation access. This
# script could equally run on the bench VM (same role, same SG), but running it here
# means one less network hop and no extra clone.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

ip="$(state_get CORE_SIM_PUBLIC_IP)"
[ -n "$ip" ] || die "no CORE_SIM_PUBLIC_IP in state — run 03_launch_core_sim_vm.sh first"

n_accounts="$(state_get N_ACCOUNTS_SEEDED)"
if [ -n "$n_accounts" ]; then
    info "Redis currently holds ~${n_accounts} accounts (from 05_seed_accounts.sh) — this will wipe" \
         "and rewrite ${n_accounts} rows in DynamoDB. On-demand billing means no capacity to" \
         "provision, but a scan+batch_write of millions of rows will still take real time."
fi
read -rp "Wipe and reseed ${ACCOUNT_INQUIRY_STACK}'s DynamoDB table from Redis on ${ip}? Type 'yes' to continue: " confirm
[ "$confirm" = "yes" ] || die "aborted"

if ssh_run "$ip" '[ -d ~/account-inquiry/.git ]' 2>/dev/null; then
    info "account-inquiry already cloned on $ip, pulling latest"
    ssh_run "$ip" 'cd ~/account-inquiry && git pull --ff-only'
else
    info "cloning account-inquiry (public repo) on $ip"
    ssh_run "$ip" "git clone --depth 1 '${ACCOUNT_INQUIRY_REPO_URL}' ~/account-inquiry"
fi

info "installing account-inquiry dependencies on $ip (uv sync)"
ssh_run "$ip" 'cd ~/account-inquiry && ~/.local/bin/uv sync'

info "running seed_from_redis.py on $ip against ${ACCOUNT_INQUIRY_STACK} (${AWS_REGION})"
info "(the sim VM's instance role provides AWS credentials automatically — no keys needed on the VM)"
ssh_run "$ip" "cd ~/account-inquiry && AWS_DEFAULT_REGION='${AWS_REGION}' ~/.local/bin/uv run python scripts/seed_from_redis.py \
    --stack-name '${ACCOUNT_INQUIRY_STACK}' --region '${AWS_REGION}' --yes"

info "DynamoDB table reseeded from Redis."
cat <<EOF

DynamoDB now matches Redis. To let new transfers flow all the way to DynamoDB, start
publishing on the relay (attach: ssh ${SSH_USER}@${ip} tmux attach -t core-sim, window "relay"):

    KINESIS_STREAM=transfers ~/.local/bin/uv run core-sim-relay

Next: infra/07_launch_benchmark_vm.sh
EOF
