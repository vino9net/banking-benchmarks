#!/usr/bin/env python3
"""Tails k6's streamed JSON metrics output and reports core-sim write-side TPS.

Run k6 with `--out json=<path>` (see README.md) so it streams one JSON object per
metric sample as the run progresses; this script follows that file (like `tail -f`)
and, every REPORT_INTERVAL seconds, prints:

  - cumulative transfer count and TPS since this script started watching
  - TPS over the trailing WINDOW_SECONDS (default 60s)

Both numbers are derived from the *event* timestamps k6 attaches to each sample (i.e.
when core-sim actually completed each request), not from wall-clock polling time, so
they're accurate even if this script starts late or stalls briefly.

Unless --no-cloudwatch is passed, each report also publishes the number of transfers
committed *since the last report* as a CloudWatch Count metric (fixed namespace
DynamoDBIngestionBench, metric TransfersCommitted — this script has exactly one job, so
neither is configurable) — the same Count-per-event shape as the ingest Lambda's own
TransferApplied metric (see ddb_ingestion_metrics.py), so a CloudWatch dashboard can
graph Sum(TransfersCommitted)/period next to Sum(TransferApplied)/period as one
write-vs-ingest TPS comparison. Publishing failures (missing permissions, network,
whatever) are caught and only printed as a warning — this script's only real job is
tailing k6's output correctly, and a CloudWatch hiccup must never take that down.

AWS identity/region come entirely from the environment (AWS_PROFILE, AWS_REGION /
AWS_DEFAULT_REGION, or the bench VM's own instance role) — same convention as every
other AWS-touching command in this repo. Region needs to be set explicitly somewhere:
this repo already found boto3 does not auto-detect it from EC2 instance metadata.

Usage:
    uv run python core_sim_tps.py --metrics-file k6-metrics.ndjson \
        [--csv-out core_sim_tps.csv]
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from collections import deque
from datetime import UTC, datetime

import boto3

METRIC_NAME = "transfers_committed"
CLOUDWATCH_NAMESPACE = "DynamoDBIngestionBench"
CLOUDWATCH_METRIC_NAME = "TransfersCommitted"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--metrics-file", required=True, help="path to k6's --out json= file")
    p.add_argument("--metric-name", default=METRIC_NAME, help="k6 Counter metric to track")
    p.add_argument("--window-seconds", type=float, default=60.0, help="trailing TPS window")
    p.add_argument(
        "--report-interval",
        type=float,
        default=5.0,
        help="seconds between printed snapshots",
    )
    p.add_argument("--csv-out", help="optional path to also append snapshots as CSV")
    p.add_argument(
        "--no-cloudwatch", action="store_true", help="don't publish to CloudWatch at all"
    )
    return p.parse_args()


def _parse_time(s: str) -> float:
    # k6's JSON output uses RFC3339 with a trailing "Z".
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(UTC).timestamp()


def follow(path: str):
    while not os.path.exists(path):
        time.sleep(0.2)
    with open(path) as f:
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.1)
                continue
            yield line


def _cloudwatch_client(args: argparse.Namespace):
    if args.no_cloudwatch:
        return None
    try:
        # No explicit profile/region: boto3 already resolves both from the environment
        # (AWS_PROFILE, AWS_REGION/AWS_DEFAULT_REGION) or, on the bench VM, from the
        # instance's IAM role automatically — the same convention every other
        # AWS-touching command in this repo relies on (e.g. core-sim-relay). Region
        # does need to be set explicitly *somewhere* in the environment though: this
        # repo already found boto3 does not auto-detect it from EC2 instance metadata.
        return boto3.client("cloudwatch")
    except Exception as exc:  # noqa: BLE001 - never let a CloudWatch problem take the tailer down
        print(
            f"[core-sim-tps] warning: could not create CloudWatch client, "
            f"publishing disabled: {exc}",
            file=sys.stderr,
        )
        return None


def _publish(cw, ts: float, delta: int) -> None:
    if cw is None or delta <= 0:
        return
    try:
        cw.put_metric_data(
            Namespace=CLOUDWATCH_NAMESPACE,
            MetricData=[
                {
                    "MetricName": CLOUDWATCH_METRIC_NAME,
                    "Timestamp": datetime.fromtimestamp(ts, tz=UTC),
                    "Value": float(delta),
                    "Unit": "Count",
                }
            ],
        )
    except Exception as exc:  # noqa: BLE001 - a publish failure must never stop the tailer
        print(
            f"[core-sim-tps] warning: failed to publish to CloudWatch: {exc}",
            file=sys.stderr,
        )


def main() -> None:
    args = parse_args()
    cw = _cloudwatch_client(args)

    window: deque[float] = deque()
    start_time: float | None = None
    total = 0
    last_published_total = 0
    last_report = 0.0

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
                    "cumulative_count",
                    "tps_since_launch",
                    f"tps_last_{int(args.window_seconds)}s",
                ]
            )

    print(
        f"[core-sim-tps] watching {args.metrics_file!r} for metric {args.metric_name!r}",
        file=sys.stderr,
    )

    try:
        for line in follow(args.metrics_file):
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if obj.get("type") != "Point" or obj.get("metric") != args.metric_name:
                continue
            data = obj.get("data", {})
            try:
                ts = _parse_time(data["time"])
            except (KeyError, ValueError):
                continue
            value = data.get("value", 1)

            if start_time is None:
                start_time = ts
            total += value
            window.append(ts)
            cutoff = ts - args.window_seconds
            while window and window[0] < cutoff:
                window.popleft()

            now = time.time()
            if now - last_report < args.report_interval:
                continue
            last_report = now

            elapsed = ts - start_time
            tps_since_launch = total / elapsed if elapsed > 0 else 0.0
            tps_window = (
                len(window) / min(args.window_seconds, elapsed) if elapsed > 0 else 0.0
            )

            print(
                f"[core-sim] elapsed={elapsed:7.1f}s  count={total:9d}  "
                f"tps_since_launch={tps_since_launch:8.1f}  "
                f"tps_last_{int(args.window_seconds)}s={tps_window:8.1f}"
            )
            if csv_writer and csv_file:
                csv_writer.writerow(
                    [
                        f"{elapsed:.1f}",
                        total,
                        f"{tps_since_launch:.2f}",
                        f"{tps_window:.2f}",
                    ]
                )
                csv_file.flush()

            _publish(cw, ts, total - last_published_total)
            last_published_total = total
    except KeyboardInterrupt:
        pass
    finally:
        if csv_file:
            csv_file.close()


if __name__ == "__main__":
    main()
