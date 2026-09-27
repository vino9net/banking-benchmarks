# Standing up the benchmark infrastructure

Provisions two EC2 VMs and wires them to the already-deployed `account-inquiry` stack
(DynamoDB + AppSync + Kinesis + ingest Lambda) so a benchmark in this repo can drive
load against the whole pipeline described in [`AGENTS.md`](../AGENTS.md):

- **sim VM** — runs Redis + `core-sim` (the fund-transfer simulator).
- **bench VM** — runs the load generator (`k6`, `node`) against the sim VM's HTTP API
  and/or the AppSync GraphQL API.

Everything here is implemented as numbered scripts under [`infra/`](../infra/), meant to
be run in order, once, against a fresh environment. Each step below explains what its
script does and why; run the script, don't hand-type the AWS CLI calls it contains.

## Environment facts (resolved against the real account, not assumed)

| | |
|---|---|
| AWS profile | `dev1` |
| AWS account | `211281185885` |
| Region | `us-west-2` |
| VPC | `vpc-06627344a3b084aa7` (default VPC — already has public subnets, nothing to create) |
| Subnet (both VMs) | `subnet-0460e3e4335d95b0a` (us-west-2a) — same AZ for both VMs to keep the RTT between them low; see `core-sim/docs/ARCH_DESIGN.md` §7.1 on why cross-node hops matter here |
| SSH key pair | `m1air` (ed25519) — its private key is `~/.ssh/id_ed25519` (verified by SHA256 fingerprint match) |
| `account-inquiry` stack | `AccountInquiryStack-staging`, already deployed: table `AccountInquiryStack-staging-AccountsTable81C15AE5-OXNRIUZ4UJAS`, AppSync API `https://43nj3ci6fbdwff45kxoi72bc3q.appsync-api.us-west-2.amazonaws.com/graphql`, Kinesis stream `transfers` |

All of these are defaults in [`infra/config.sh`](../infra/config.sh), overridable via
env vars if you're running this against a different account/region — but the numbers
above are what's actually there today, not placeholders.

## Prerequisites

- AWS CLI v2, authenticated as the `dev1` profile (`aws sts get-caller-identity
  --profile dev1` should return account `211281185885`).
- This repo pushed to GitHub before step 8 (cloning it onto the bench VM). Both
  `core-sim` and `account-inquiry` are public, so no GitHub token is needed for either
  of those clones — if this repo itself is private, step 8's bootstrap script falls
  back to an interactive token prompt (needs `repo` scope). Nothing here ever writes
  such a token to disk or embeds it in a git remote URL.

## Step 1 — security group

```bash
infra/01_create_security_group.sh
```

Creates one security group (`banking-benchmarks`), shared by both VMs. Three rules,
each with a different reason:

| Port | Source | Why |
|---|---|---|
| 22 (SSH) | `0.0.0.0/0` | admin's source IP moves around between VPNs, so this is open rather than scoped — still gated by the `m1air` key pair, unlike Redis below, which has no such gate |
| 8000 (core-sim HTTP) | `0.0.0.0/0` | **required by the task**: the sim VM's benchmark endpoint must be reachable from the public internet, e.g. a load generator running somewhere other than the bench VM |
| 6379 (Redis) | this security group only | **never public** — Redis has no auth, and the security group (not Redis config) is what actually keeps it from being an open, unauthenticated write path to 10M+ accounts. Only the bench VM (same SG) can reach it, for ad hoc `redis-cli` use |

## Step 2 — IAM role (shared by both VMs)

```bash
infra/02_create_iam_role.sh
```

One role (`banking-benchmarks-vm-role`) + instance profile
(`banking-benchmarks-vm-profile`), attached to **both** VMs — the task requires the
bench VM use the same role as the sim VM, and there's no reason to split it. Grants
exactly three things, each scoped to one specific resource (never account-wide):

1. `dynamodb:*` (read/write, not admin) on `account-inquiry`'s `AccountsTable` — needed
   by `seed_from_redis.py` in step 5.
2. `appsync:GraphQL` on `account-inquiry`'s AppSync API — AppSync's IAM auth checks the
   *caller's* identity policy, not a resource policy on the API (see
   `account-inquiry/stack.py`'s `grant_query()`), so without this grant no request from
   either VM can authenticate to it, regardless of the security group.
3. `cloudformation:DescribeStacks` on the `AccountInquiryStack-staging` stack — both
   `seed_from_redis.py` and `account-inquiry/scripts/query_appsync.py` resolve the
   table name / API URL this way by default.

## Step 3 — launch the sim VM

```bash
infra/03_launch_core_sim_vm.sh
```

Resolves the latest official Debian 13 **arm64** AMI (published by Debian's Cloud Team,
AWS account `136693071363` — Debian isn't AWS-authored, so this is the closest thing to
"official" available; there's no AWS Marketplace listing worth using instead), and
launches an `r7g.xlarge` (4 vCPU / 32 GiB, Graviton).

**Why memory-optimized, and why this size:** core-sim's Redis holds one hash per
account (10M accounts × several fields) *plus* one leaked `idem:<key>` per successful
transfer for `IDEM_TTL_SECONDS` (default 24h) — see AGENTS.md and
`core-sim/docs/benchmark.md`'s "known problems" section, which documents this leak
directly. At 10M accounts and a 25M-transaction benchmark run, that's roughly 35M keys
alive in Redis simultaneously at the leak's peak, not 10M — size for both, not just the
account count the task names. 32 GiB gives comfortable headroom; watch `redis-cli INFO
memory` during your first real run and resize if needed (`redis_max_connections`/
instance type are both easy to change after the fact — this is a starting point, not a
promise).

The script's own `user-data` (`infra/cloud-init/core-sim.sh`) handles everything that
doesn't need a secret: `git`, `tmux`, `redis-server`, `build-essential`, `uv`, and Redis
tuning (`save ""`, `appendonly no` — durability lives in the Kinesis log, not the
ledger, per `core-sim/docs/ARCH_DESIGN.md` §6.3/§6.4; `bind 0.0.0.0`/`protected-mode no`
so the bench VM's `redis-cli` can actually reach it, safe only because the security
group — not Redis itself — is what restricts access). The script waits for that to
finish (`cloud-init status --wait`-equivalent polling) before returning.

## Step 4 — bootstrap the sim VM: clone `core-sim`, start it

```bash
infra/04_bootstrap_core_sim_vm.sh
```

`core-sim` is public, so this is a plain `git clone` — no token needed. Then: `uv sync
--all-extras` inside `~/core-sim` on the VM, and starts a `tmux` session
named `core-sim` with two windows:

- `app` — `uv run core-sim` (the HTTP API, port 8000)
- `relay` — left idle on purpose. Starting `core-sim-relay` with `KINESIS_STREAM=transfers`
  before DynamoDB has been seeded (step 5/6) would mean early transfers try to update
  accounts that don't exist yet in DynamoDB and fail `ConditionalCheckFailed` on the
  ingest Lambda side — harmless (they just don't apply) but confusing to debug later.
  Start the relay only after step 6.

## Step 5 — seed accounts into Redis

```bash
infra/05_seed_accounts.sh
```

Seeds `SEED_ACCOUNTS_K` thousand accounts (`config.sh`, **default 100** = 100,000
accounts — deliberately small so a first run is fast to iterate on; override via `.env`
or `SEED_ACCOUNTS_K=10000 infra/05_seed_accounts.sh` for a real 10M-account run). There
is no separate seeding script in `core-sim` — the seeding logic *is* `POST /admin/seed`
(`core_sim.engines.redis_lua.RedisLuaEngine.seed()`, pipelined in chunks of 5,000 HSETs)
— so this script just calls that endpoint on the sim VM's public IP with a generous
timeout, since seeding millions of accounts inside one blocking HTTP request takes real
time.

This is destructive by design (wipes `acct:*`/`idem:*`/the outbox stream first — see
`core-sim`'s own README) — safe here because this Redis is dedicated to the benchmark.
It prints the seed response and fails loudly if the post-seed conservation check isn't
`"ok":true`.

## Step 6 — wipe and reseed DynamoDB from Redis

```bash
infra/06_reseed_dynamodb.sh
```

`account-inquiry`'s ingest Lambda never creates Account items itself — a transfer for an
account that isn't already in DynamoDB fails `ConditionalCheckFailed` — so the table has
to be seeded from Redis before transfers can apply. `account-inquiry` already has the
script for this: `scripts/seed_from_redis.py` (public repo, no token needed).

Runs **on the sim VM**, not locally and not on the bench VM: that's where Redis is
reachable from (never public — step 1) and where the shared IAM role already provides
DynamoDB + CloudFormation credentials automatically, so no AWS keys ever touch either
VM's disk. Clones `account-inquiry`, `uv sync`, then:

```bash
uv run python scripts/seed_from_redis.py --stack-name AccountInquiryStack-staging --region us-west-2 --yes
```

This **wipes every item** (accounts and transactions) in the DynamoDB table first, then
rewrites account rows from Redis. DynamoDB billing is on-demand (no capacity to
provision), but a full scan-delete-then-batch-write of millions of rows still takes
real wall-clock time — expect minutes, not seconds, at 10M accounts. The script prompts
for confirmation before wiping.

After this, the console output tells you the command to start publishing on the
relay (`KINESIS_STREAM=transfers uv run core-sim-relay`, in the sim VM's `core-sim:relay`
tmux window) — do this once you're ready for transfers to actually flow through to
DynamoDB, not before.

## Step 7 — launch the bench VM

```bash
infra/07_launch_benchmark_vm.sh
```

Same Debian 13 arm64 AMI lookup, same security group, same IAM instance profile as the
sim VM (per the task's requirement) — but a CPU-optimized `c7g.xlarge` (4 vCPU / 8 GiB):
this VM is the load generator, not the thing being measured, so it needs cores for `k6`
and `node`, not memory.

`user-data` (`infra/cloud-init/benchmark.sh`) installs `redis-tools` (`redis-cli`),
`nodejs`/`npm`, `k6` (from k6's own apt repo — not in Debian's main repo), `tmux`, `git`,
and `uv`.

## Step 8 — bootstrap the bench VM

```bash
infra/08_bootstrap_benchmark_vm.sh
```

Clones this repo (`banking-benchmarks`) onto the bench VM. Tries a plain clone first;
falls back to an interactive GitHub-token prompt if it turns out to be private.
Prints a summary of both endpoints (core-sim's HTTP API, the AppSync GraphQL URL) and
confirms the shared IAM role so you know what a benchmark script running from here can
already reach without extra credentials:

- `http://<sim-vm-ip>:8000` — plain HTTP, no auth, core-sim's `/transfer` etc.
- AppSync GraphQL URL — `AWS_IAM`/SigV4 auth only. Anything querying it from this VM
  authenticates via the instance role's credentials automatically; there is no API key.
- `redis-cli -h <sim-vm-ip> ping` — reachable because both VMs share the security group,
  not because Redis is public.

**Infrastructure setup ends here.** Individual benchmarks — k6 scripts, node-based
AppSync load generators, result logs — live in their own directories at the repo root,
each documenting how to run it against the two VMs this runbook just stood up.

## Tearing down

```bash
infra/teardown.sh
```

Terminates both instances, deletes the security group, deletes the IAM
role/instance profile. Does **not** touch `AccountInquiryStack-staging` (its DynamoDB
table, AppSync API, Kinesis stream, Lambda), the VPC/subnet, or the `m1air` key pair —
none of those belong to this repo, and account-inquiry's own CDK app owns the first one.

## Design decisions worth knowing about

- **Debian 13, arm64, Graviton throughout.** Chosen for cost, and Debian publishes
  official arm64 images so there's no architecture mismatch to work around. If you need
  to compare against x86_64 for some reason, `debian13_ami x86_64` in
  `infra/lib/common.sh` already resolves that AMI too — just change the instance types
  in `config.sh` to a non-`g` family (e.g. `r7i.xlarge`/`c7i.xlarge`).
- **Traditional SSH key pair, not SSM Session Manager.** Simpler for this use case and
  matches how the existing `m1air` key is already used elsewhere in this account.
- **Same AZ, same security group, same IAM role for both VMs.** Minimizes both
  cross-node latency (see `core-sim/docs/ARCH_DESIGN.md` §7.1) and the number of moving
  parts to reason about when something doesn't connect.
- **State is tracked in `infra/.state/env`** (gitignored) — a flat key=value file each
  script reads/writes so later steps don't need you to copy-paste instance IDs or IPs
  between them. If you lose it, the instance IDs/IPs are still one `aws ec2
  describe-instances --filters Name=tag:Project,Values=banking-benchmarks` away.
