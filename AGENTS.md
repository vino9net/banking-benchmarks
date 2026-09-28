# AGENTS.md

Instructions and architecture context for coding agents working in this repo.

## What this repo is

`banking-benchmarks` holds load-test/benchmark rigs that exercise the infrastructure
built by two sibling repos, checked out next to this one:

```
banking-demo/
  core-sim/            producer — the core banking simulator
  account-inquiry/     consumer — DynamoDB + AppSync read side (public repo)
  banking-benchmarks/  this repo — benchmarks that drive the other two
```

This repo does not own any application logic. It owns: infrastructure-provisioning
scripts to stand up VMs that run the other two systems, and benchmark scripts/configs
that generate load against them and record results. Each benchmark gets its own
directory here.

## The system under test

```
k6 / node (bench VM) ──HTTP /transfer──► core-sim (sim VM) ──EVALSHA──► Redis
                                                                          │
                                                             XADD (same atomic script)
                                                                          ▼
                                                          Redis stream `transfers` (outbox)
                                                                          │
                                                        core-sim-relay: XREADGROUP → XACK
                                                                          ▼
                                                          Amazon Kinesis Data Stream `transfers`
                                                                          │
                                                     event source mapping ▼
                                                          Lambda (account-inquiry ingest)
                                                                          │
                                                            TransactWriteItems ▼
                                                                    DynamoDB (accounts + transactions)
                                                                          │
                                          AppSync (AWS_IAM auth, JS resolvers) ◄┘
                                                                          ▲
k6 / node (bench VM) ──IAM-signed GraphQL query───────────────────────────┘
```

- **core-sim** (`../core-sim`, public GitHub repo) simulates one function — fund
  transfer between accounts — against a pluggable storage engine. The only implemented
  engine is `redis_lua`: an atomic Lua script debits one account, credits another, and
  `XADD`s a fixed-width binary transfer record onto a Redis stream in the same atomic
  operation (its `docs/ARCH_DESIGN.md` §D4 is the load-bearing decision — read it before
  changing anything about durability or the outbox). A separate `core-sim-relay` process
  drains that stream and republishes each record onto an Amazon Kinesis Data Stream
  (`transfers`), at-least-once. core-sim never talks to AWS directly except through this
  relay's `PutRecords` calls; it has no idea account-inquiry exists.
  See `../core-sim/AGENTS.md` and `../core-sim/docs/ARCH_DESIGN.md`.

- **account-inquiry** (`../account-inquiry`, **public** GitHub repo) is the read side: an
  ingest Lambda consumes the same Kinesis stream, fans each transfer record into a
  debit/credit transaction-item pair, and atomically applies both balance updates via one
  `TransactWriteItems` call into a single DynamoDB table (partition key `id`, sort key
  `sid` — see its AGENTS.md for the overloaded key shape). An AppSync GraphQL API
  (`AWS_IAM` auth only, no API key) with JS resolvers reads straight from that table:
  `getAccountsForCustomer` and `getTransactionsForAccount`. account-inquiry never creates
  Account items itself — every transfer for an account not already in the table fails
  `ConditionalCheckFailed` — so **core-sim's Redis is the source of truth for account
  existence**, and account-inquiry's DynamoDB table has to be seeded from it before any
  transfer will apply cleanly. `scripts/seed_from_redis.py` in that repo does this copy
  (and, by default, wipes the table first). See `../account-inquiry/AGENTS.md`.

- **This repo** provisions two EC2 VMs to run the above at scale (millions of accounts,
  tens of millions of transactions — far more than a laptop can usefully simulate) and
  drives/measures load against them. See `docs/infrastructure-setup.md` for the full
  runbook and `infra/` for the scripts that implement it.

## Key facts that shape every benchmark here

- **Balances are derived state, not source of truth.** `balances = seed + replay(transfers)`
  in core-sim, and account-inquiry's DynamoDB balances are themselves derived from
  replaying core-sim's transfer stream. Neither store persists to disk by design
  (`appendonly no`, `save ""` in Redis) — a reseed is the normal recovery path, not an
  emergency one. This is why "wipe and reseed" is a first-class step in every benchmark
  run here, not a one-time setup chore.
- **Conservation checks are non-negotiable.** Sum every balance before and after a run —
  it must be identical. core-sim exposes `GET /admin/conservation?expected_total=N` for
  this. Any benchmark added to this repo should bracket its run with this check; a
  throughput number from a run that failed conservation is fiction, not data
  (`core-sim/docs/ARCH_DESIGN.md` §6.1).
- **Idempotency keys leak.** Every successful transfer leaves a `idem:<key>` in Redis for
  `IDEM_TTL_SECONDS` (default 24h) — core-sim's own
  [benchmark.md](../core-sim/docs/benchmark.md) documents this biting a same-day
  worker-scaling sweep. At benchmark scale (tens of millions of transfers) this is real
  memory, not a rounding error — size the sim VM for accounts *and* leaked idempotency
  keys, and prefer reseeding between independent runs.
- **core-sim's Redis is a single-writer, single-core ceiling, on purpose** (`ARCH_DESIGN.md`
  §D3) — it cannot be sharded and contention (hot-account vs. uniform access, via the k6
  Zipf `theta` parameter) is structurally invisible to it. Don't expect a hot-account run
  against `redis_lua` to look different from a uniform one; that's the engine working as
  designed, not a benchmark bug.
- **Two independent AWS-facing surfaces get benchmarked**: core-sim's own HTTP API
  (`POST /transfer`, plain HTTP, no auth) for write throughput, and the AppSync GraphQL
  API (`AWS_IAM`/SigV4 auth only) for read throughput. A load generator hitting AppSync
  needs valid AWS credentials with `appsync:GraphQL` granted on that specific API — a
  resource policy on the API does *not* grant this, only an identity policy on the
  caller does (`account-inquiry/stack.py`'s `grant_query()`).

## Repo layout

```
docs/
  infrastructure-setup.md   step-by-step runbook: provision both VMs, install tooling,
                             seed core-sim's Redis, wipe+reseed account-inquiry's
                             DynamoDB table, ready both VMs for a benchmark run
infra/
  config.sh                 shared config for every infra/*.sh script (profile, region,
                             VPC/subnet, key pair, instance sizing — override via env)
  lib/common.sh              shared bash helpers (AMI lookup, SSH wait, tagging)
  cloud-init/                 EC2 user-data scripts (non-interactive base tool installs)
  01_create_security_group.sh
  02_create_iam_role.sh
  03_launch_core_sim_vm.sh
  04_bootstrap_core_sim_vm.sh   interactive: prompts for a GitHub token, clones core-sim
  05_seed_accounts.sh            interactive: prompts for how many million accounts
  06_reseed_dynamodb.sh          wipes + reseeds account-inquiry's DynamoDB from Redis
  07_launch_benchmark_vm.sh
  08_bootstrap_benchmark_vm.sh
  teardown.sh                  tears down everything this repo's scripts created
```

Benchmark-specific directories (load-test scripts, k6/node configs, result logs) get
added alongside `infra/` and `docs/` as they're built — each benchmark in its own
top-level directory, per the project's convention.

## Working in this repo

- `infra/*.sh` scripts are meant to be run in numeric order, once, against a fresh
  environment; they check for existing resources before creating them, so re-running a
  script is safe but not idempotent-by-design in the CDK sense — read a script before
  re-running it if you're unsure what it'll touch.
- Nothing here provisions or modifies the `AccountInquiryStack-staging` CloudFormation
  stack itself (DynamoDB table, AppSync API, Kinesis stream, ingest Lambda) — that's
  account-inquiry's CDK app, already deployed. This repo only reads its outputs (table
  name, API URL, stream name) and writes into the table it already created.
- Secrets (a GitHub PAT, if this repo or some future dependency turns out to be private;
  AWS credentials) are always prompted for interactively and passed over an
  already-encrypted channel (SSH) — never written into a script, a cloud-init file, or
  committed to this repo.

## Tearing down between runs, to save cost

A benchmark run here is occasional, not continuous — most of the time this rig should be
torn down, not left running. Of everything it creates, only two things actually cost
money while idle: the two EC2 instances (per-hour compute + attached EBS) and the
Kinesis stream (per-shard-hour billing regardless of traffic — see
`../account-inquiry/AGENTS.md`'s "Kinesis costs while idle"). Everything else costs
nothing to leave alone:

- **DynamoDB** — `TableV2` on-demand billing means zero cost with zero requests, so
  there's no need to empty it just to save money. It's still worth emptying before
  tearing down (see below), but that's for a clean start next time, not for cost.
- **The CloudWatch dashboard** (`DynamoDBIngestionBench`) — CloudWatch's free tier
  covers the first 3 custom dashboards per account per month; this account has 2
  (`DynamoDBIngestionBench` plus the pre-existing `vinobank`), so it's costing nothing.
  Leave it — only reconsider if a 4th dashboard shows up somewhere and pushes the
  account over the free-tier count (then it's $3/dashboard/month).
- **The security group and IAM role/instance profile** (`infra/01_create_security_group.sh`,
  `infra/02_create_iam_role.sh`) — plain AWS resources with no idle charge. Keep them
  around between runs; `infra/03_launch_core_sim_vm.sh` and `07_launch_benchmark_vm.sh`
  reuse them from `infra/.state/env` instead of recreating them, which is the whole
  reason resuming is fast.

**Order** (do DynamoDB before terminating anything — the wipe below runs from the
core-sim VM the same way `infra/06_reseed_dynamodb.sh` does, so it needs that VM, and
its SSH access, to still exist):

1. **Wipe DynamoDB.** account-inquiry's `scripts/seed_from_redis.py --wipe-only` empties
   the table and stops — no Redis read, no reseed. Run it the same way
   `06_reseed_dynamodb.sh` runs the full reseed, just with the extra flag:
   ```
   ssh "$SSH_USER@$(state_get CORE_SIM_PUBLIC_IP)" \
     "cd ~/account-inquiry && AWS_DEFAULT_REGION='$AWS_REGION' ~/.local/bin/uv run python \
      scripts/seed_from_redis.py --stack-name '$ACCOUNT_INQUIRY_STACK' --wipe-only --yes"
   ```
   (If you'd rather run it from your own machine instead of over SSH, it needs no VM at
   all — `--wipe-only` never touches Redis, only DynamoDB via your AWS credentials — in
   which case this step's ordering relative to VM termination stops mattering.)

2. **Terminate the two EC2 instances.** Do this directly (not `infra/teardown.sh` — that
   also deletes the security group and IAM role/instance profile, which cost nothing to
   keep and are what make the next resume fast):
   ```
   aws ec2 terminate-instances --instance-ids "$(state_get CORE_SIM_INSTANCE_ID)" "$(state_get BENCHMARK_INSTANCE_ID)"
   ```
   Redis dies with the core-sim instance (`appendonly no`, `save ""` — see "Key facts"
   above); that's expected, not a problem, since accounts get reseeded from
   `05_seed_accounts.sh`'s account-generation logic next time, not from a Redis snapshot.

3. **Delete the Kinesis stream.** `RemovalPolicy.RETAIN` on account-inquiry's stream
   means nothing here or in `cdk destroy` ever removes it automatically — see
   `../account-inquiry/AGENTS.md`'s "Kinesis costs while idle" for the command and why
   not to just `create-stream` it back by hand next time (let `cdk deploy` do that).

Reaching for `infra/teardown.sh` instead of steps 2-3 is for permanently decommissioning
the rig, not for pausing it between runs — it also deletes the security group and IAM
role, so the next run starts from `infra/01_create_security_group.sh` again instead of
resuming.
