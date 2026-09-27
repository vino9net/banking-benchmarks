# DynamoDB ingestion benchmark

Measures the pipeline in AGENTS.md's "System under test" end to end:

```
k6 (this dir) ──HTTP /transfer──► core-sim ──Redis/Kinesis/relay──► ingest Lambda ──► DynamoDB
```

Three independent things are measured, each read from wherever it's cheapest and most
accurate to read it from — nothing here scans DynamoDB or adds new instrumentation to
either sibling repo:

| what | source | script |
|---|---|---|
| core-sim write TPS (last-minute + since-launch) | k6's own streamed metrics | `core_sim_tps.py` |
| DynamoDB ingestion TPS + P50/P95/P99 delay (last-minute + since-launch) + approx. running transaction count | the ingest Lambda's existing CloudWatch metrics | `ddb_ingestion_metrics.py` |
| live view of the load generator | k6's built-in web dashboard | `transfer.js` (via `K6_WEB_DASHBOARD=true`) |

## Why these sources, not something else

- **Delay** = `updated_at - processed_at`, where `processed_at` is core-sim's own
  `created_at` (embedded in the 176-byte transfer record before it ever leaves core-sim)
  and `updated_at` is the ingest Lambda's write-time — both are already stored on every
  DynamoDB transaction item (`account_inquiry/ingest/ddb.py`), and the Lambda already
  computes this exact delay and emits it as a CloudWatch metric (`ingest/handler.py`).
  Reading that metric needs no new instrumentation and no per-transfer correlation.
- **DynamoDB ingestion TPS** is the same Lambda's `TransferApplied` Count metric,
  summed over a period.
- **core-sim TPS** comes from k6 itself, since core-sim's own `/transfer` response
  already carries everything needed (success/failure, and its own `created_at`) — no
  reason to look anywhere else for the write side.
- **Approx. running transaction count**, for correlating "more transactions in flight"
  against "higher delay": a real `Select=COUNT` scan or `DescribeTable.ItemCount` was
  explicitly ruled out (see the docstring in `ddb_ingestion_metrics.py`) — both are
  either expensive at tens-of-millions-of-rows scale or refreshed only ~every 6 hours
  and dominated by pre-existing seeded Account rows. Instead this accumulates
  `TransferApplied` across polls to get a running total of *transactions ingested this
  run*, which is free (same metric already driving TPS) and is actually the relevant
  number for this correlation.
- **Open-loop load** (`constant-arrival-rate`): core-sim's own
  `docs/benchmark.md` flags that a closed loop (fixed VUs) is coordinated omission —
  when the server slows down, offered load silently drops with it, understating delay
  under saturation. `transfer.js` uses k6's `constant-arrival-rate` executor instead.

## Configurable account-number distribution

`distributions.js` is a small registry — `{ uniform, gaussian, zipf }` today. Each entry
is a `{ setup(env, nAccounts), pick(state, nAccounts) }` pair; adding a new one is
"write one function pair, add one registry entry" (see the comments there). Select at
run time with `-e DISTRIBUTION=<name>`.

- `uniform` (default): every account equally likely.
- `gaussian`: normal distribution, `-e GAUSSIAN_MEAN=... -e GAUSSIAN_STDDEV=...`
  (default mean = N_ACCOUNTS/2, stddev = N_ACCOUNTS/6).
- `zipf`: hot-account distribution ported from `core-sim/bench/transfer.js`,
  `-e THETA=0.99` for brutally hot, `0` for uniform.

## Running a benchmark

Requires `k6` and `uv` (both already installed on the bench VM by
`infra/cloud-init/benchmark.sh`; locally, `brew install k6` + `astral.sh/uv`).

```bash
cd dynamodb-ingestion
uv sync   # once, installs boto3 for the two reporter scripts

# 0. Bracket the run — conservation check before (per AGENTS.md, non-negotiable).
#    /admin/seed (run once beforehand via infra/05_seed_accounts.sh) already printed
#    the expected_total to compare against; or just call conservation with no args now
#    and diff it against the same call after the run.
curl -s "$BASE/admin/conservation"

# 1. DynamoDB ingestion TPS / delay / approx. transaction count (start this first —
#    it takes 1-3 min before CloudWatch has anything to report, so starting early
#    means useful numbers are ready close to when the load actually ramps up).
uv run python ddb_ingestion_metrics.py --region us-west-2 --csv-out results/ddb_ingestion.csv

# 2. core-sim write TPS — reads the file k6 is about to write, in real time.
#    Start this before or right after k6; it just waits for the file to appear.
uv run python core_sim_tps.py --metrics-file results/k6-metrics.ndjson --csv-out results/core_sim_tps.csv

# 3. The load itself. K6_WEB_DASHBOARD=true serves a live dashboard on :5665
#    (throughput/latency/status-code charts) for as long as k6 is running.
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=results/k6-report.html \
  k6 run -e BASE="$BASE" -e N_ACCOUNTS=10000000 -e RATE=500 -e DISTRIBUTION=uniform \
    --out json=results/k6-metrics.ndjson transfer.js

# 4. Conservation check after — compare against step 0's total.
curl -s "$BASE/admin/conservation?expected_total=<value from /admin/seed>"
```

Stop the two Python reporters (Ctrl-C) once k6 finishes and CloudWatch has caught up
(a minute or two of drain time — the ingest Lambda is still processing the queue's
tail after the last request completes).

### Reaching the k6 dashboard from your laptop

The bench VM runs nginx, reverse-proxying `:80`/`:443` to k6's dashboard on
`127.0.0.1:5665` (see `infra/cloud-init/benchmark.sh`), so once a run is going with
`K6_WEB_DASHBOARD=true` set, just open `http://<benchmark-vm-public-ip>/` (or `https://`
— self-signed cert, expect a browser warning) and log in with the credentials
`infra/08_bootstrap_benchmark_vm.sh` printed when the VM was bootstrapped. A 502 means
no run is currently active, not a misconfiguration.

If you'd rather not expose it at all, an SSH tunnel still works as an alternative:

```bash
ssh -L 5665:localhost:5665 admin@<benchmark-vm-public-ip>
```

then open `http://localhost:5665` locally. `K6_WEB_DASHBOARD_EXPORT` also saves a
static HTML report you can open after the fact, through either path.

## Correlating transaction count against delay

Both reporters' `--csv-out` files are plain CSV, one row per report interval, with an
`elapsed_s` column in common. `ddb_ingestion.csv`'s `approx_total_transactions` column
against its own `delay_p95_ms_since_launch` (or the `_last_minute` variants) is the
"does delay grow as more transactions flow through" correlation — load both CSVs
(joined loosely on `elapsed_s`, since the two scripts poll on different intervals) into
a notebook or spreadsheet.

## Known limitations (carried over / new)

- CloudWatch lags real time by roughly 1-3 minutes — `ddb_ingestion_metrics.py`'s "last
  minute" figure prints its own bucket timestamp so this lag is visible, not hidden.
  CloudWatch's own metric granularity is 60s, so nothing here is more fine-grained than
  that on the DynamoDB side.
- Idempotency keys still leak in core-sim's Redis (`IDEM_TTL_SECONDS`, default 24h) —
  reseed between independent runs, per AGENTS.md.
- This only measures core-sim's HTTP write path and DynamoDB ingestion. It does not
  touch the AppSync/GraphQL read side — that's a separate benchmark per AGENTS.md's
  "two independent AWS-facing surfaces" note.
