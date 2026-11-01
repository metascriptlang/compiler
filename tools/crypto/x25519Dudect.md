# X25519 dudect timing evidence

Test-only, nothing ships. Statistical timing evidence for the raw `x25519ScalarMult` export, on top of the same staticlib
and targeted-init host boundary as `x25519Taint.sh` (see `README.md`). Passing is "no leakage evidence within this bound",
never a proof of constant time.

## Parts

| part | file |
|---|---|
| upstream statistics, unedited | `src/test/crypto/harness/dudect/dudect.h`, `LICENSE` (MIT), `PROVENANCE` (commit, sha256) |
| AArch64 timer names for the unedited header | `src/test/crypto/harness/dudect/armShim/` |
| host | `src/test/crypto/harness/x25519DudectHost.c` |
| runner | `tools/crypto/x25519Dudect.sh`, building through `x25519Build.sh` with `X25519_HOST_SOURCE` |

Upstream is `github.com/oreparaz/dudect` at `dc269651fb2567e46755cfb2a13d3875592968b5`. The runner refuses a `dudect.h`
whose sha256 differs from `PROVENANCE`. Upstream runs a Welch t-test on the raw times, on 100 percentile-cropped sets and a
second-order (centered product) test; it reports the largest |t| and says "Probably not constant time" above 10 and
"Definitely" above 500 (its `t_threshold_moderate` and `t_threshold_bananas`), and nothing before 10000 measurements.

## What the host measures

Class 0 is one fixed scalar (default RFC 7748 §5.2 vector 1, `--fixed-hex` overrides), class 1 a fresh random scalar per
call, the class chosen at random per measurement. The public point is the constant of that vector. Each timed call is
`x25519ScalarMult(output, scalar, point)` on the real raw kernel plus an XOR fold of the 32 output bytes into a volatile
sink. The known answer for the default scalar is checked first (`--no-kat` skips it, for the leaky toy kernel only).
Inputs come from splitmix64 seeded by `--seed` (default drawn from `/dev/urandom` and printed), so the input and class
schedule of a run is reproducible; the timings are not. Upstream's own `/dev/urandom` helpers stay compiled and unused.

Bounds, enforced by the host: `--measurements` 1000..1000000 per batch, `--batches` 2..1000000 (the first batch only
sets the percentiles), `measurements * batches` at most 500000000. A run stops at the first batch dudect calls leakage,
as upstream does. Exit: 0 no evidence, 20 leakage, 21 inconclusive (class 0 never above 10000), 10 known answer, 16 usage.
The log keeps every `CONFIG` line (seed, counts, fixed scalar, point, timer, compiler, thresholds), every upstream
`meas:` line and a final `RESULT` line.

## Timers

Read from the pinned header, not assumed: it includes `<emmintrin.h>` and `<x86intrin.h>` and `cpucycles()` is
`_mm_mfence(); __rdtsc();`. It has no AArch64 branch and does not compile on arm64. `armShim/` supplies the two names on
AArch64 only (`dsb sy`; `isb; mrs cntvct_el0`) and is put in front by `-isystem`; the header stays byte-identical. The
counter is the generic timer, not a CPU cycle counter. On x86-64 the TSC is whatever the guest exposes: the oci-u VM lists
`tsc_known_freq` but not `constant_tsc` or `nonstop_tsc`, so TSC invariance is not confirmed there.

## Controls

A harness that cannot see a leak proves nothing, so the runner fails unless each control is detected (status 20):

| row | what |
|---|---|
| `control-leakyBranch-<mode>` | the `leakyBranch` kernel of `x25519HostEntry.ms` (loop count from `scalar[0] & 15`; wrong output, so `--no-kat`) |
| `control-hostLeak-<impl>-<mode>` | the real kernel with `DUDECT_LEAK_SPIN` (10000) volatile steps before the call when `scalar[0]` is odd |
| `null-<impl>-<mode>` | the real kernel, both classes random: must stay status 0, otherwise the host is too noisy to trust |

## Run

Off the Mac, one call (env does not cross `run-remote.sh`, so set it inside `bash -c`). Smoke, under 2 minutes with a warm
cache: `DUDECT_MODES=release DUDECT_BATCHES=12`. Defaults: 5000 measurements, 40 batches, both modes.

```
~/metascript/.gate-host/run-remote.sh --cores 2 --job "<session>: x25519 dudect" -- \
  bash -c 'DUDECT_MODES=release DUDECT_BATCHES=12 DUDECT_SEED=0x1234abcd5678ef90 tools/crypto/x25519Dudect.sh out/crypto [monocypher|pilot]'
```

Knobs: `DUDECT_MEASUREMENTS`, `DUDECT_BATCHES`, `DUDECT_SEED`, `DUDECT_MODES`, `DUDECT_CPU` (taskset core), `DUDECT_LEAK_SPIN`,
`DUDECT_TIMEOUT` (seconds per host run, 300). Long and quiet runs (host idle, pinned core, many millions of measurements) belong to
the owner of the verdict; a shared host with load near 90 (oci-u during the smoke) only validates plumbing.

## Limits

- Evidence for one compiler, one CPU and one input pair (fixed scalar and point) on the machine it ran on; other scalars,
  CPUs and compilers are not covered. A leak smaller than the noise at the sample count stays invisible.
- `--release` and `--danger` are the two builds the runner times. The `pilot` impl is the real `std/crypto/x25519/pilot.cms` and `field.cms` as they stand in the tree the run copies; a later kernel change (for example zeroization) needs a new run.
- AArch64: the full runner (staticlib, host, shim, four rows per mode) ran on macOS with `pilot` (Apple M3 Max, Apple clang 21.0.0,
  `msc` v0.4.0 binary da827695fe7, 12 batches x 5000, seed 0x1234abcd5678ef90, host not quiet: load average 23 to 57). That
  proves the plumbing and the controls on arm64, not constant time. Linux arm64 is not run. On macOS `x25519Build.sh` strips
  the one leading `_` that Mach-O `nm` puts on C names before it injects `MS_ENTRY_*`, and reads BSD `wc` numerically.
