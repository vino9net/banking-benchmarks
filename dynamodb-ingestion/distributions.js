// Pluggable account-number distributions for transfer.js.
//
// Each entry in DISTRIBUTIONS is { setup(env, nAccounts) -> state, pick(state, nAccounts) -> index }.
// `setup` runs once, in k6's setup() (shared read-only across VUs); `pick` runs per iteration.
//
// To add a new one: write a { setup, pick } pair and add it to DISTRIBUTIONS under a new
// key. Select it at run time with `-e DISTRIBUTION=<key>`. Nothing else in transfer.js
// needs to change.

export const DISTRIBUTIONS = {
  // Every account equally likely. The baseline — no contention structure at all.
  uniform: {
    setup: () => ({}),
    pick: (_state, n) => Math.floor(Math.random() * n),
  },

  // Normal distribution over account index, clamped to [0, n). Concentrates load
  // around GAUSSIAN_MEAN (default: the middle of the account range) with spread
  // GAUSSIAN_STDDEV (default: n/6, so +/-3 stddev covers ~the whole range).
  //
  // Box-Muller: Math.random() alone is uniform, not normal — this is the standard
  // transform from two uniforms to one normal sample.
  gaussian: {
    setup: (env, n) => ({
      mean: parseFloat(env.GAUSSIAN_MEAN || String(n / 2)),
      stddev: parseFloat(env.GAUSSIAN_STDDEV || String(n / 6)),
    }),
    pick: (state, n) => {
      let u1 = Math.random();
      const u2 = Math.random();
      // avoid log(0)
      if (u1 === 0) u1 = Number.MIN_VALUE;
      const z = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
      const idx = Math.round(state.mean + z * state.stddev);
      if (idx < 0) return 0;
      if (idx >= n) return n - 1;
      return idx;
    },
  },

  // Zipfian / hot-account distribution (YCSB / Gray et al. rejection-inversion),
  // ported from core-sim/bench/transfer.js. THETA controls skew: 0 = uniform,
  // ~0.99 = brutally hot. Kept here mainly as a second worked example of adding a
  // distribution, and because it's directly useful for reproducing core-sim's own
  // theta sweep against this ingestion benchmark.
  zipf: {
    setup: (env, n) => {
      const theta = parseFloat(env.THETA || "0.99");
      if (theta <= 0) return { theta, zetan: 0, alpha: 0, eta: 0 };
      const zeta = (m) => {
        let sum = 0;
        for (let i = 1; i <= m; i++) sum += 1 / Math.pow(i, theta);
        return sum;
      };
      const zetan = zeta(n);
      const zeta2 = zeta(2);
      const alpha = 1 / (1 - theta);
      const eta = (1 - Math.pow(2 / n, 1 - theta)) / (1 - zeta2 / zetan);
      return { theta, zetan, alpha, eta };
    },
    pick: (state, n) => {
      if (state.theta <= 0) return Math.floor(Math.random() * n);
      const u = Math.random();
      const uz = u * state.zetan;
      if (uz < 1) return 0;
      if (uz < 1 + Math.pow(0.5, state.theta)) return 1;
      return Math.floor(n * Math.pow(state.eta * u - state.eta + 1, state.alpha));
    },
  },
};
