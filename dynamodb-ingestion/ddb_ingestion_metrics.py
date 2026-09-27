#!/usr/bin/env python3
"""Reports DynamoDB ingestion TPS, delay percentiles, and a running approximate
transaction count, by polling the account-inquiry ingest Lambda's own CloudWatch
metrics — no DynamoDB reads, no CloudWatch Logs Insights queries, no scans.

Why CloudWatch and not a table scan or DynamoDB Streams:

  - account-inquiry's DynamoDB table has no stream enabled (only the upstream Kinesis
    stream from core-sim), so there's nothing to tail on the DynamoDB side directly.
  - `DescribeTable`'s ItemCount is refreshed by DynamoDB only ~every 6 hours and counts
    Account rows too (single-table design) — useless at benchmark-run timescales.
  - A `Select=COUNT` scan against a table with tens of millions of rows is exactly the
    "expensive query" this is meant to avoid.

Instead: account_inquiry/ingest/handler.py already emits, per Lambda invocation, EMF
metrics into CloudWatch namespace "AccountInquiry":

  - TransferApplied      (Count)         — one per transfer successfully ingested
  - IngestionLatencyMs   (Milliseconds)  — updated_at - processed_at, i.e. exactly the
                                           core-sim -> DynamoDB delay this benchmark
                                           wants to measure, computed by the Lambda
                                           itself (no clock correlation needed here)

This script queries both via GetMetricData using SEARCH() expressions (so it doesn't
need to guess the exact dimension set Powertools attaches) and reports, every
REPORT_INTERVAL (default 60s, matching CloudWatch's own metric granularity):

  - ingestion TPS: last full minute, and since this script started watching
  - delay p50/p95/p99: last full minute, and since this script started watching
  - a running approximate total of transactions ingested during this run (the
    cumulative sum of TransferApplied) — free, since it's the same metric driving TPS,
    and it's what actually correlates with delay (unlike the table's total row count,
    which is dominated by pre-existing seeded accounts/transactions)

Caveat: CloudWatch typically lags real time by 1-3 minutes before a metric is queryable,
so "last minute" here means "the most recent minute CloudWatch has fully reported," not
literally the last 60 wall-clock seconds — each report prints that bucket's own
timestamp so the lag is visible rather than hidden.

Usage:
    uv run python ddb_ingestion_metrics.py [--region us-west-2] [--csv-out ddb_ingestion.csv]
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
import time
from datetime import datetime, timedelta, timezone

import boto3

NAMESPACE = "AccountInquiry"
COUNT_METRIC = "TransferApplied"
LATENCY_METRIC = "IngestionLatencyMs"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--region", default=os.environ.get("AWS_REGION"), help="AWS region (else boto3 default chain)")
    p.add_argument("--profile", default=os.environ.get("AWS_PROFILE"), help="AWS profile (else boto3 default chain)")
    p.add_argument("--report-interval", type=float, default=60.0, help="seconds between polls (CloudWatch is 60s-granular)")
    p.add_argument("--recent-lookback-minutes", type=int, default=6, help="how far back to look for the latest complete minute")
    p.add_argument("--csv-out", help="optional path to also append snapshots as CSV")
    return p.parse_args()


def _search_query(qid: str, metric: str, stat: str, period: int) -> dict:
    return {
        "Id": qid,
        "Expression": f"SEARCH('Namespace=\"{NAMESPACE}\" MetricName=\"{metric}\"', '{stat}', {period})",
        "ReturnData": True,
    }


def _client(args: argparse.Namespace):
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    return session.client("cloudwatch")


def _latest_complete_minute(cw, lookback_minutes: int) -> tuple[datetime | None, float, float, float, float]:
    """Returns (bucket_start, tps, p50, p95, p99) for the most recent 60s bucket that
    CloudWatch has data for, within the lookback window. bucket_start is None (and the
    rest 0.0) if nothing has landed yet."""
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=lookback_minutes)
    resp = cw.get_metric_data(
        MetricDataQueries=[
            _search_query("tps", COUNT_METRIC, "Sum", 60),
            _search_query("p50", LATENCY_METRIC, "p50", 60),
            _search_query("p95", LATENCY_METRIC, "p95", 60),
            _search_query("p99", LATENCY_METRIC, "p99", 60),
        ],
        StartTime=start,
        EndTime=end,
        ScanBy="TimestampDescending",
    )
    by_id = {r["Id"]: r for r in resp["MetricDataResults"]}
    tps_series = by_id.get("tps", {})
    if not tps_series.get("Timestamps"):
        return None, 0.0, 0.0, 0.0, 0.0

    bucket = tps_series["Timestamps"][0]
    count = tps_series["Values"][0]
    tps = count / 60.0

    def _value_at(series_id: str) -> float:
        series = by_id.get(series_id, {})
        for ts, val in zip(series.get("Timestamps", []), series.get("Values", [])):
            if ts == bucket:
                return val
        return 0.0

    return bucket, tps, _value_at("p50"), _value_at("p95"), _value_at("p99")


def _since_launch(cw, launch: datetime) -> tuple[float, float, float, float, float]:
    """Returns (elapsed_s, cumulative_count, p50, p95, p99) over [launch, now].

    Period is set to the smallest 60s multiple >= the elapsed run time, so CloudWatch
    returns a single bucket spanning the whole run — real percentiles computed by
    CloudWatch over that entire window, not an average-of-per-minute-percentiles
    (which would not be mathematically valid)."""
    now = datetime.now(timezone.utc)
    elapsed = max((now - launch).total_seconds(), 60.0)
    period = int(-(-elapsed // 60) * 60)  # round up to a multiple of 60

    resp = cw.get_metric_data(
        MetricDataQueries=[
            _search_query("tps", COUNT_METRIC, "Sum", period),
            _search_query("p50", LATENCY_METRIC, "p50", period),
            _search_query("p95", LATENCY_METRIC, "p95", period),
            _search_query("p99", LATENCY_METRIC, "p99", period),
        ],
        StartTime=launch,
        EndTime=now,
        ScanBy="TimestampAscending",
    )
    by_id = {r["Id"]: r for r in resp["MetricDataResults"]}

    def _first(series_id: str) -> float:
        series = by_id.get(series_id, {})
        values = series.get("Values", [])
        return values[0] if values else 0.0

    cumulative_count = _first("tps")
    return elapsed, cumulative_count, _first("p50"), _first("p95"), _first("p99")


def main() -> None:
    args = parse_args()
    cw = _client(args)
    launch = datetime.now(timezone.utc)

    csv_writer = None
    csv_file = None
    if args.csv_out:
        is_new = not os.path.exists(args.csv_out)
        csv_file = open(args.csv_out, "a", newline="")
        csv_writer = csv.writer(csv_file)
        if is_new:
            csv_writer.writerow(
                [
                    "elapsed_s",
                    "approx_total_transactions",
                    "tps_since_launch",
                    "delay_p50_ms_since_launch",
                    "delay_p95_ms_since_launch",
                    "delay_p99_ms_since_launch",
                    "last_minute_bucket",
                    "tps_last_minute",
                    "delay_p50_ms_last_minute",
                    "delay_p95_ms_last_minute",
                    "delay_p99_ms_last_minute",
                ]
            )

    print(
        f"[ddb-ingestion] watching CloudWatch namespace={NAMESPACE!r} "
        f"({COUNT_METRIC}, {LATENCY_METRIC}) every {args.report_interval:.0f}s",
        file=sys.stderr,
    )

    try:
        while True:
            elapsed, total, p50_all, p95_all, p99_all = _since_launch(cw, launch)
            tps_since_launch = total / elapsed if elapsed > 0 else 0.0
            bucket, tps_last, p50_last, p95_last, p99_last = _latest_complete_minute(
                cw, args.recent_lookback_minutes
            )

            print(
                f"[ddb] elapsed={elapsed:7.1f}s  approx_total={total:9.0f}  "
                f"tps_since_launch={tps_since_launch:7.1f}  "
                f"delay(since launch) p50={p50_all:7.1f}ms p95={p95_all:7.1f}ms p99={p99_all:7.1f}ms"
            )
            if bucket is not None:
                lag_s = (datetime.now(timezone.utc) - bucket).total_seconds()
                print(
                    f"      last complete minute @ {bucket.isoformat()} "
                    f"({lag_s:5.0f}s ago)  tps={tps_last:7.1f}  "
                    f"delay p50={p50_last:7.1f}ms p95={p95_last:7.1f}ms p99={p99_last:7.1f}ms"
                )
            else:
                print("      no data landed in CloudWatch yet (expect 1-3min lag on the first report)")

            if csv_writer and csv_file:
                csv_writer.writerow(
                    [
                        f"{elapsed:.1f}",
                        f"{total:.0f}",
                        f"{tps_since_launch:.2f}",
                        f"{p50_all:.1f}",
                        f"{p95_all:.1f}",
                        f"{p99_all:.1f}",
                        bucket.isoformat() if bucket else "",
                        f"{tps_last:.2f}",
                        f"{p50_last:.1f}",
                        f"{p95_last:.1f}",
                        f"{p99_last:.1f}",
                    ]
                )
                csv_file.flush()

            time.sleep(args.report_interval)
    except KeyboardInterrupt:
        pass
    finally:
        if csv_file:
            csv_file.close()


if __name__ == "__main__":
    main()
