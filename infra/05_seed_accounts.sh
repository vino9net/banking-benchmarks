#!/usr/bin/env bash
# Seeds core-sim's Redis via its own POST /admin/seed — core-sim has no separate
# standalone seed script; this HTTP endpoint IS the seeding logic (see
# src/core_sim/engines/redis_lua.py RedisLuaEngine.seed(), pipelined in chunks of 5000).
# Destructive: wipes acct:*/idem:*/the outbox stream on the target Redis first — see
# core-sim's own AGENTS.md/README. Safe here because this Redis is dedicated to this
# benchmark.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

ip="$(state_get CORE_SIM_PUBLIC_IP)"
[ -n "$ip" ] || die "no CORE_SIM_PUBLIC_IP in state — run 03_launch_core_sim_vm.sh first"

# SEED_ACCOUNTS_K is in thousands (config.sh, default 100 = 100,000 accounts) — override
# via .env or `SEED_ACCOUNTS_K=10000 infra/05_seed_accounts.sh` for a real 10M-account run.
[[ "$SEED_ACCOUNTS_K" =~ ^[0-9]+$ ]] || die "SEED_ACCOUNTS_K is not a number: $SEED_ACCOUNTS_K"
n_accounts=$((SEED_ACCOUNTS_K * 1000))
opening_balance=100000000   # 1,000,000.00 in minor units — matches core-sim's own docs/README example
currency="SGD"
expected_total=$((n_accounts * opening_balance))

info "seeding ${n_accounts} accounts (SEED_ACCOUNTS_K=${SEED_ACCOUNTS_K}, opening balance ${opening_balance} ${currency}) on ${ip}:${CORE_SIM_PORT}"
info "this runs inside one HTTP request and blocks until every account is written — for" \
     "large values of SEED_ACCOUNTS_K, expect it to take a while; --max-time below is generous on purpose"

response="$(curl -fsS -m 1800 -XPOST "http://${ip}:${CORE_SIM_PORT}/admin/seed" \
    -H 'content-type: application/json' \
    -d "{\"n_accounts\": ${n_accounts}, \"opening_balance\": ${opening_balance}, \"currency\": \"${currency}\"}")"

echo "$response"
echo "$response" | grep -q '"ok":true' || die "conservation check after seed did not report ok:true — see response above"

state_set N_ACCOUNTS_SEEDED "$n_accounts"
state_set EXPECTED_TOTAL_BALANCE "$expected_total"

cat <<EOF

Seeded ${n_accounts} accounts. expected_total_balance=${expected_total}

Next: infra/06_reseed_dynamodb.sh
  (wipes + reseeds account-inquiry's DynamoDB table from this same Redis data)
EOF
