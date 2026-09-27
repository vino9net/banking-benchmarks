#!/usr/bin/env bash
# Shared config for infra/*.sh. Source this — do not execute it directly.
#
# Every value has a real default for the dev1 AWS account (211281185885, us-west-2),
# resolved by hand against what already exists there (see docs/infrastructure-setup.md
# "Environment facts"). Override any of them via env vars before running a script if
# you're pointing at a different account/region.

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$INFRA_DIR/.." && pwd)"

# .env (gitignored, see .env.example) is applied first so it wins over the hardcoded
# defaults below — but a value already exported in the calling shell still wins over
# .env: each line only fills in a variable that isn't already set (a plain `source`
# would instead unconditionally clobber an exported override, e.g.
# `AWS_PROFILE=x ./03_launch_core_sim_vm.sh` silently losing to .env's own value).
if [ -f "$REPO_ROOT/.env" ]; then
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [ -z "${!key:-}" ] && export "${key}=${val}"
    done < <(grep -vE '^\s*(#|$)' "$REPO_ROOT/.env")
fi

: "${AWS_PROFILE:=dev1}"
: "${AWS_REGION:=us-west-2}"
export AWS_PROFILE AWS_REGION

# The already-deployed account-inquiry stack (DynamoDB table + AppSync API + Kinesis
# stream + ingest Lambda). This repo never creates or modifies it, only reads its
# outputs and writes into the table.
: "${ACCOUNT_INQUIRY_STACK:=AccountInquiryStack-staging}"

# Networking. dev1's default VPC already has public subnets with auto-assign-public-IP
# on (checked directly against the account — see the runbook) so there is nothing to
# create here except the security group. Both VMs go in the same subnet/AZ: pod-to-pod
# RTT between the sim VM and the bench VM matters a lot at the throughput this rig
# targets (core-sim/docs/ARCH_DESIGN.md §7.1), and same-AZ is the cheap way to keep it
# low without a placement group.
: "${VPC_ID:=vpc-06627344a3b084aa7}"
: "${SUBNET_ID:=subnet-0460e3e4335d95b0a}"     # us-west-2a, default VPC

# SSH key pair, already registered in this AWS account. Its local private key matches
# ~/.ssh/id_ed25519 (verified by comparing SHA256 fingerprints) — if you're running this
# against a different machine/account, either import that key pair under the same name
# or override KEY_NAME/SSH_KEY_PATH to one you do have.
: "${KEY_NAME:=m1air}"
: "${SSH_KEY_PATH:=$HOME/.ssh/id_ed25519}"
: "${SSH_USER:=admin}"    # Debian's official cloud AMIs default to this login user

: "${SG_NAME:=banking-benchmarks}"
: "${IAM_ROLE_NAME:=banking-benchmarks-vm-role}"
: "${IAM_INSTANCE_PROFILE_NAME:=banking-benchmarks-vm-profile}"

# Memory-optimized mid-size for the sim VM (Redis holds 10M+ accounts plus leaked
# idempotency keys from tens of millions of transfers — see AGENTS.md); CPU-optimized
# for the bench VM (k6/node are the load generator, not the thing being measured).
# Graviton (arm64) throughout — cheaper, and Debian publishes official arm64 images.
: "${CORE_SIM_INSTANCE_TYPE:=r7g.xlarge}"      # 4 vCPU / 32 GiB
: "${BENCHMARK_INSTANCE_TYPE:=c7g.xlarge}"     # 4 vCPU / 8 GiB
: "${CORE_SIM_VOLUME_GB:=30}"
: "${BENCHMARK_VOLUME_GB:=20}"

: "${CORE_SIM_NAME_TAG:=banking-benchmarks-core-sim}"
: "${BENCHMARK_NAME_TAG:=banking-benchmarks-bench}"

# core-sim's HTTP API. Deliberately public per the benchmark's own requirement (the
# bench VM's load generator must reach it) — see 01_create_security_group.sh for why
# this is the one port opened to 0.0.0.0/0 while SSH and Redis are not.
: "${CORE_SIM_PORT:=8000}"

# How many accounts to seed into core-sim's Redis (05_seed_accounts.sh), in thousands —
# e.g. 100 = 100,000 accounts. Default kept small (100K, not the 10M the task sizes the
# VM for) so a first run is fast to iterate on; bump it via .env or the shell for a
# real benchmark run.
: "${SEED_ACCOUNTS_K:=100}"

CORE_SIM_REPO_URL="https://github.com/vino9net/core-sim.git"      # public
ACCOUNT_INQUIRY_REPO_URL="https://github.com/vino9net/account-inquiry.git"  # public
# This repo itself, for the bench VM to clone (08_bootstrap_benchmark_vm.sh). Not yet
# pushed to GitHub as of writing this — override if you push it somewhere else, or
# under a different name.
: "${BANKING_BENCHMARKS_REPO_URL:=https://github.com/vino9net/banking-benchmarks.git}"

STATE_DIR="$INFRA_DIR/.state"
mkdir -p "$STATE_DIR"

# shellcheck source=lib/common.sh
source "$INFRA_DIR/lib/common.sh"
