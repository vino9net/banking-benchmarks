// k6 load driver for the DynamoDB-ingestion benchmark (AGENTS.md's "System under test").
//
// Posts fund transfers to core-sim's HTTP API. This script only drives and measures
// the *write* side (core-sim's own throughput); DynamoDB ingestion TPS and delay are
// measured out-of-band by ddb_ingestion_metrics.py, reading the ingest Lambda's own
// CloudWatch metrics (see README.md) — this script has no knowledge of DynamoDB at all.
//
// Open-loop (constant-arrival-rate), not closed-loop: core-sim/docs/benchmark.md flags
// that a closed loop (fixed VUs waiting for each response) is coordinated omission —
// when the server slows down, offered load silently drops with it, so latency numbers
// understate how bad things get. constant-arrival-rate keeps the request rate fixed
// regardless of response time, at the cost of needing enough spare VUs (maxVUs) to
// keep up if latency spikes.
//
//   k6 run -e RATE=500 -e DISTRIBUTION=uniform  -e N_ACCOUNTS=10000000 transfer.js
//   k6 run -e RATE=500 -e DISTRIBUTION=gaussian -e GAUSSIAN_STDDEV=50000 transfer.js
//
// Run core_sim_tps.py alongside this (tailing --out json=<file>) to get write-side TPS
// printed locally and published to CloudWatch — see README.md.

import http from "k6/http";
import { check } from "k6";
import { Counter, Rate } from "k6/metrics";
import { DISTRIBUTIONS } from "./distributions.js";

const BASE = __ENV.BASE || "http://localhost:8000";
const N_ACCOUNTS = parseInt(__ENV.N_ACCOUNTS || "10000");
const AMOUNT = parseInt(__ENV.AMOUNT || "100");
const CURRENCY = __ENV.CURRENCY || "SGD";
const DISTRIBUTION = __ENV.DISTRIBUTION || "uniform";

// constant-arrival-rate knobs. PRE_ALLOCATED_VUS/MAX_VUS are k6's headroom for when
// responses slow down and more requests are in flight at once than at steady state;
// size MAX_VUS generously (default 4x rate) since running out mid-run silently drops
// the arrival rate, which is the exact failure mode this executor is meant to avoid.
const RATE = parseInt(__ENV.RATE || "200");
const TIME_UNIT = __ENV.TIME_UNIT || "1s";
const DURATION = __ENV.DURATION || "60s";
const PRE_ALLOCATED_VUS = parseInt(__ENV.PRE_ALLOCATED_VUS || String(Math.max(RATE, 50)));
const MAX_VUS = parseInt(__ENV.MAX_VUS || String(PRE_ALLOCATED_VUS * 4));

const dist = DISTRIBUTIONS[DISTRIBUTION];
if (!dist) {
  throw new Error(
    `unknown DISTRIBUTION=${DISTRIBUTION}; add it to distributions.js (have: ${Object.keys(DISTRIBUTIONS).join(", ")})`,
  );
}

// Counted separately from k6's built-in http_reqs so core_sim_tps.py only has to
// filter on one metric name to get "successful transfer" TPS (201 OR 200 — a 200 is
// an idempotent replay, still a real committed transfer from the caller's view).
const transfersCommitted = new Counter("transfers_committed");
const insufficient = new Counter("transfer_insufficient_funds");
const duplicates = new Counter("transfer_duplicates");
const okRate = new Rate("transfer_ok");

export const options = {
  scenarios: {
    transfers: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: TIME_UNIT,
      duration: DURATION,
      preAllocatedVUs: PRE_ALLOCATED_VUS,
      maxVUs: MAX_VUS,
    },
  },
  thresholds: {
    // Loose on purpose — insufficient-funds is a legitimate outcome, not a failure.
    // Only 5xx/timeouts are real errors.
    http_req_failed: ["rate<0.05"],
  },
};

export function setup() {
  return dist.setup(__ENV, N_ACCOUNTS);
}

export default function (state) {
  const from = dist.pick(state, N_ACCOUNTS);
  let to = dist.pick(state, N_ACCOUNTS);
  if (to === from) to = (to + 1) % N_ACCOUNTS; // self-transfer is rejected by the script

  const res = http.post(
    `${BASE}/transfer`,
    JSON.stringify({
      from_account: from,
      to_account: to,
      amount: AMOUNT,
      currency: CURRENCY,
      memo: "dynamodb-ingestion-bench",
      // Always send one. Without it a retry double-spends (ARCH_DESIGN.md D6).
      idempotency_key: `${__VU}-${__ITER}-${Date.now()}`,
    }),
    { headers: { "Content-Type": "application/json" } },
  );

  if (res.status === 201) {
    transfersCommitted.add(1);
    okRate.add(true);
  } else if (res.status === 200) {
    transfersCommitted.add(1);
    duplicates.add(1);
    okRate.add(true);
  } else if (res.status === 422) {
    insufficient.add(1);
    okRate.add(false);
  } else {
    okRate.add(false);
  }

  check(res, {
    "no server error": (r) => r.status < 500,
  });
}

export function teardown() {
  // The check that makes every throughput/delay number here trustworthy
  // (ARCH_DESIGN.md §6.1). Compare against the value /admin/seed printed before the run.
  const res = http.get(`${BASE}/admin/conservation`);
  console.log(`conservation after run: ${res.body}`);
}
