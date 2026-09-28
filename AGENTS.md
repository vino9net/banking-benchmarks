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
Kinesis stream (per-shard-hour billing regardless of traffic). Everything else costs
nothing to leave alone, so it's left alone — including DynamoDB:

- **DynamoDB is never touched at teardown or ramp-up.** `TableV2` on-demand billing means
  zero cost with zero requests, and storage is free too (25GB/month free tier; this table
  has never exceeded ~1GB). The table just sits there between runs with whatever data is
  in it; `06_reseed_dynamodb.sh`'s normal wipe-then-reseed at the start of the next
  session brings it back in sync with Redis's freshly-generated accounts, same as always.
  (An earlier version of this section proposed wiping it at teardown, or even routing
  Kinesis recovery through a full `cdk destroy`/`cdk deploy` of the whole stack — rejected
  once it became clear that path drags DynamoDB along for the ride too, permanently
  orphaning the old table and minting a new one on every cycle. Not worth it for a
  resource that isn't the cost problem in the first place.)
- **The CloudWatch dashboard** (`DynamoDBIngestionBench`) — CloudWatch's free tier covers
  the first 3 custom dashboards per account per month; this account has just the one, so
  it's costing nothing. Leave it — only reconsider if enough other dashboards accumulate
  in this account to push past that free-tier count (then it's $3/dashboard/month).
- **The security group and IAM role/instance profile** (`infra/01_create_security_group.sh`,
  `infra/02_create_iam_role.sh`) — plain AWS resources with no idle charge. Keep them
  around between runs; `infra/03_launch_core_sim_vm.sh` and `07_launch_benchmark_vm.sh`
  reuse them from `infra/.state/env` instead of recreating them, which is the whole
  reason resuming is fast.

**Kinesis is the one resource that actually needs a teardown/ramp-up procedure**, and
it's handled with plain AWS CLI calls, not CDK — see
`../account-inquiry/AGENTS.md`'s "Kinesis costs while idle" for the full reasoning
(why `cdk deploy` alone can't bring a manually-deleted, `RemovalPolicy.RETAIN` resource
back, verified directly against this stack with both `cdk diff` and
`detect-stack-drift`). In short: `cdk deploy`/`cdk destroy` were both considered and
rejected for this — deploy silently no-ops on a resource CloudFormation still thinks is
unchanged, and destroy would work but only by rebuilding (and DynamoDB-sprawling) the
entire stack just to fix one resource.

**Teardown:**

1. **Terminate the two EC2 instances:**
   ```bash
   aws ec2 terminate-instances --instance-ids "$(state_get CORE_SIM_INSTANCE_ID)" "$(state_get BENCHMARK_INSTANCE_ID)"
   ```
   Redis dies with the core-sim instance (`appendonly no`, `save ""` — see "Key facts"
   above); expected, not a problem — accounts get reseeded from `05_seed_accounts.sh`'s
   generation logic next time, not from a Redis snapshot.

2. **Delete the Kinesis stream** — this is the step that actually stops the billing:
   ```bash
   aws kinesis delete-stream --stream-name transfers --region us-west-2
   ```

Reaching for `infra/teardown.sh` instead of step 1 is for permanently decommissioning
this repo's own VMs/security-group/IAM role, not for pausing between runs — it also
deletes the security group and IAM role/instance profile, so the next run starts from
`infra/01_create_security_group.sh` again instead of resuming.

**Ramp-up:** recreate the stream matching CDK's actual generated properties (verified via
`cdk synth` — 2 shards, KMS encryption via the AWS-managed key, which a plain
`create-stream` does *not* enable by default; 24h retention is already AWS's default for
a new stream, so nothing extra needed there), then re-enable the ingest Lambda's event
source mapping — deleting the stream doesn't delete the mapping, it just auto-disables it
(`aws lambda list-event-source-mappings` will show
`LastProcessingResult: "PROBLEM: Stream not found. Recreate the stream and re-enable..."`,
which is exactly what these steps do):

```bash
aws kinesis create-stream --stream-name transfers --shard-count 2 --region us-west-2
# wait for the stream to reach ACTIVE (aws kinesis describe-stream-summary)
aws kinesis start-stream-encryption --stream-name transfers \
    --encryption-type KMS --key-id alias/aws/kinesis --region us-west-2
aws lambda update-event-source-mapping --uuid <uuid-from-list-event-source-mappings> \
    --enabled --region us-west-2
```

Since the stream name is fixed, its ARN comes back identical, so nothing downstream
(the event source mapping, IAM policies referencing it) needs to change. This does leave
the stream permanently outside CloudFormation's bookkeeping (`detect-stack-drift` will
keep reporting it `DELETED` relative to the stack) — accepted, since re-adopting it via
`cdk import` isn't worth the added complexity for a benchmark-support stack, and nothing
here needs CDK to manage the stream's day-to-day lifecycle.

## Reading CloudWatch numbers correctly — a pitfall that produced a false alarm

Checking "how much has actually landed in DynamoDB so far" during a live 2000 tps run,
an ad hoc `GetMetricData`/`SEARCH()` query against `AccountInquiry/TransferApplied` with a
short relative window (`StartTime = now - 60min`, `now - 40min`, etc.) undercounted the
true total by ~300-400K — enough to look exactly like a stalled, stuck consumer with a
huge unprocessed backlog. It wasn't: re-running the same query with `StartTime` set safely
*before the run itself started* (90 min back, not 40) accounted for 1,793,018 of the
1,800,001 transfers written, with the ~7K gap fully explained by
`AccountInquiry/TransferAlreadyApplied` (the relay's at-least-once redelivery, correctly
deduped). The pipeline had drained completely; the "backlog" was a query bug, not a real one.

**The mistake, generalized**: `GetMetricData`/`SEARCH()` results are strictly clipped to
`[StartTime, EndTime]` — data published before `StartTime` isn't a zero, it's just absent
from the returned series, and a `Sum` over that series will silently exclude it. There's no
warning; the query just returns a smaller-than-true number that looks exactly like missing
or stuck data. This is *the same underlying gotcha* the dashboard's "Approx Ingestion
Backlog" widget already warns about in its own title (`RUNNING_SUM` is cumulative *over
whatever time range the CloudWatch console has selected* — pick a range that starts before
the run began, or the number is meaningless) — it just bit an ad hoc script version of the
same query instead of the dashboard.

**How to avoid it**:
- When computing a "total so far" number for a still-running or just-finished benchmark,
  always set `StartTime` with generous margin before the run's actual start — never a
  short relative window ("last 40 min") chosen without checking how long the run has
  actually been going.
- Prefer `AWS/Lambda`'s `IteratorAge` metric (dimensioned by `FunctionName`, `Stat=Maximum`)
  for "is the consumer keeping up" questions instead of recomputing cumulative sums. It's a
  point-in-time reading of how stale the oldest unprocessed record is — immune to this
  class of windowing mistake entirely, which is exactly why it's on the dashboard as its
  own widget now, not just the `RUNNING_SUM` one.
- Before concluding a pipeline is "stuck" from a metrics gap, check for a mundane
  explanation first: `AccountInquiry/TransferAlreadyApplied` (deduped redeliveries),
  the ingest Lambda's own recent log stream (a clean `REPORT` line with no errors is
  strong evidence it's actually caught up and correctly idle, not stalled), and the
  `IngestDlq` queue depth (should be 0 unless something is genuinely failing repeatedly).
