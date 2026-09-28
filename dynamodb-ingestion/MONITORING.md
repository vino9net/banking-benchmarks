# Monitoring mechanism

This benchmark has **two things, and only two things, that publish metrics to
CloudWatch** — one is AWS-native and runs regardless of whether this benchmark ever
exists; the other is a script in this repo that we wrote specifically to feed a
dashboard. Nothing else in this directory publishes anything. If you only read one
section, read the table below.

| Component | Publishes to CloudWatch? | Namespace / metric | When it publishes | Where it lives |
|---|---|---|---|---|
| **account-inquiry's ingest Lambda** | **Yes — automatically, always** | `AccountInquiry` / `TransferApplied` (Count), `IngestionLatencyMs` (Milliseconds), `TransferAlreadyApplied` (Count) | Every time it processes a Kinesis batch — for *any* transfer that reaches it, benchmark-generated or not | `account-inquiry/src/account_inquiry/ingest/handler.py`, via `aws_lambda_powertools`'s `Metrics` (Embedded Metric Format — a structured CloudWatch Logs line that CloudWatch extracts into real metrics, no separate API call) |
| **`core_sim_tps.py`** (this repo) | **Yes — only while it's running** | `DynamoDBIngestionBench` / `TransfersCommitted` (Count) | Every report interval (default 5s), for as long as you have it running during a benchmark | `dynamodb-ingestion/core_sim_tps.py`, via a direct `boto3` `put_metric_data` call |
| `ddb_ingestion_metrics.py` (this repo) | **No — read-only** | reads `AccountInquiry` (above); publishes nothing of its own | N/A | `dynamodb-ingestion/ddb_ingestion_metrics.py` |
| `transfer.js` (k6 script) | No | — | — | `dynamodb-ingestion/transfer.js` — writes only to its own local `--out json=` file; never talks to CloudWatch |

## Why a Python script publishes metrics at all

core-sim (the thing under test on the write side) is a plain HTTP service with no AWS
SDK integration — it never talks to CloudWatch, or to AWS at all. Its only source of
truth for "how many transfers/sec is it actually completing" is k6's own local output
file (`--out json=...`), which `core_sim_tps.py` tails on the same machine k6 runs on.

To get that number next to the ingest Lambda's `TransferApplied` on one CloudWatch
dashboard (see `cloudwatch-dashboard.json`), *something* has to push it into CloudWatch
— core-sim can't do it (no AWS awareness), so `core_sim_tps.py` does, as a deliberate
design choice made in this repo, not an AWS default. That's the thing worth knowing:
one side of this comparison (the Lambda's metrics) is infrastructure that would emit
those numbers whether or not this benchmark existed; the other side
(`TransfersCommitted`) exists *only* because we wrote code to compute and publish it.

## A real caveat this creates

`AccountInquiry`'s metrics are **not scoped to this benchmark** — they reflect every
transfer that has ever reached the ingest Lambda, from any source, since it was
deployed. There's no dimension distinguishing "a transfer `core-sim`'s benchmark
generated" from "a transfer something else generated." If anything else in this AWS
account is producing real traffic through the same pipeline while a benchmark is
running, it silently mixes into the same `TransferApplied`/`IngestionLatencyMs`
numbers you're reading. For a dedicated staging account with nothing else writing to
it, this is a non-issue; it stops being true the moment that assumption changes.

`DynamoDBIngestionBench`/`TransfersCommitted` doesn't have this problem — it only ever
reflects whatever run of `core_sim_tps.py` published it, since nothing else publishes
to that namespace.

## Failure behavior

`core_sim_tps.py`'s CloudWatch publish is best-effort: a failed `put_metric_data` call
(bad credentials, no `cloudwatch:PutMetricData` permission, network) is caught and
printed as a warning to stderr — it never stops the tailer or affects the CSV/console
output, which come from the local k6 file regardless of whether CloudWatch is
reachable. Pass `--no-cloudwatch` to skip publishing entirely (e.g. for a pure local
dev-loop run against a local core-sim with no AWS access at all).

## Where the numbers actually get read

- `ddb_ingestion_metrics.py` polls `AccountInquiry`'s two metrics via `GetMetricData`
  and prints/logs TPS + P50/P95/P99 delay locally — this is what we used before a
  CloudWatch dashboard existed, and still works standalone.
- `cloudwatch-dashboard.json` (see `README.md`) graphs both namespaces together —
  `TransfersCommitted` and `TransferApplied` on one write-vs-ingest TPS chart,
  `IngestionLatencyMs` percentiles on another.

## Cost

Both metrics involved cost essentially nothing at this benchmark's scale: CloudWatch
custom metrics are billed by how many distinct metrics exist per month (namespace +
name + dimension set) and by API call volume, not by data volume or retention
duration. This setup publishes to exactly one custom metric
(`DynamoDBIngestionBench`/`TransfersCommitted`, no dimensions) and reads two that the
Lambda would be emitting regardless of whether anything ever queries them. See
`account-inquiry/AGENTS.md`'s "Kinesis costs while idle" section for the one thing in
this whole pipeline that *does* cost money continuously, which is unrelated to any of
this — the Kinesis stream's per-shard-hour charge, not CloudWatch.
