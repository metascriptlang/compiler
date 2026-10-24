# Build Performance — Roadmap

## Measuring by flow

A whole-compiler A/B costs 45-60 minutes and names no flow. Every instrument below writes rows
`<source>\t<flow>\t<metric>\t<value>` (source `msc` `drc` `emit` `proc`; metric `ms` `instr` `count`
`bytes`), and `src/test/perf/run.ms` turns the rows of a base and a candidate compiler into one table
per program, so a change shows its own delta in about a minute.

| Instrument | Measures | Switch on |
|---|---|---|
| `msc` rows | the compiler's passes, analyzer steps, phases, emit and cc | env `MSC_FLOWS=<file>` |
| `drc` rows | allocations, rc operations, cycle registrations and collections of a program | build with `--passC=-DMS_DRC_STAT`, run with env `MS_DRC_STAT=<file>`; an `msc` built that way reports its own runtime flows |
| `emit` rows | per function counts in emitted C (rc ops, pins, atomics) | `msc run src/test/perf/emitCostScan.ms <emit dir>`, or `--diff A B` for a ranked table |
| `proc` rows | whole process: instructions retired, wall, max rss | the runner adds them itself |

The runner's environment and program names are the header of `src/test/perf/run.ms`.

**A/B recipe.** Build the candidate at the worktree root (`msc build src/index.ms --gc=drc --danger
--lto=off --output=msc`), keep the previous build as the base, then

```sh
MSPERF_BASE=/path/to/previous/msc MSPERF_PROGRAMS=711,self nice -n 10 msc run src/test/perf/run.ms
```

Check `uptime` first and do not start a second compile beside it. `MSPERF_SELF=1` runs one binary as
both arms: that is the noise check, and every row of it should carry no mark.

**Reading the table.** Rows sort by the size of the instruction delta, then the count delta.

- Counts and non-process bytes are exact: they do not depend on load or host. `=` means identical in
  every run of both arms; `≠` means the change moved the number. An exact row that varies inside one
  arm is read as timed.
- Timed rows (`ms`, `instr`, process bytes) compare medians. `*` marks a delta over 3 times the
  noise, the larger coefficient of variation of the two arms, and over 1%; no mark means the move is
  not shown to be real. The 1% floor exists because three runs of one binary can agree to 0.0% and
  still differ by 0.2% (711, `MSPERF_SELF=1`, 2026-10-25: `phase.A` +0.2% at noise 0.0%). Instructions retired carry far less noise than wall time under load.
- `new` / `gone` is a flow only one arm wrote. A header line names the sources each arm produced:
  a compiler without `MSC_FLOWS` yields only `proc` rows.
- Coverage: the leaf flows of phase A (`pass.*`, `analyze.*`, `a2.mono`, `a2.macro`, `a2.lower`) over
  `phase.A`, and the `phase.*` rows over the `msc total`. A low share means the table leaves a flow
  out and its delta cannot be located in it.

**Self check on the merged instruments, 2026-10-25** (`msc-cand` of `wt/perf-flows` built
`--gc=drc --danger --lto=off`, `MSPERF_SELF=1`, `711`, 3 runs, load 63-73): no row marked; coverage
97.0% of `phase.A` in leaf flows and 100.0% of the `msc total` in `phase.*` rows. `phase.setup`
(session start, cache init, parser registration) is 4.1G of 30.5G instructions here against 1.1G in
a warm run from the worktree, so it is a flow worth its own look. A compiler built without
`--gc=drc` is an orc compiler and crashes in parallel emit (compiler inbox, `sharedTypeQueries`
card); build both arms with `--gc=drc`.

**Measured noise, 2026-10-25** (macOS arm64, installed `msc` v0.3.4 as both arms, `711` built with
`--emit=c`, 3 runs, load average 100-140 during the run): process instructions 25.49G against 25.64G,
median difference +0.6% at noise 0.3% (no mark); wall time noise 17% and max rss noise 11%, so wall
time and rss under that load show nothing. Not measured: Linux (`perf stat` and the `/usr/bin/time -f`
fallback are written, not run), and `rt:` programs.

## Measured 2026-10-22 — four more front-end fixes

Same methods as 2026-10-21 below. All four leave emitted C of `src/index.ms` identical
(0 of 376 files differ).

| fix | workload (Mac, thin LTO) | rounds | instructions | user |
|---|---|---|---|---|
| 4 `std/fs/path.ms` `normalize` returns a path already in normal form; `relative` slices a descendant | emit-only | 3 | 335.1G → 318.9G (−4.8%) | noise |
| 5 `ast/visitor.ms` `forEachChild` without a closure per call | emit-only, on top of 4 | 3 | 319.4G → 311.0G (−2.6%) | 31.84 → 30.15 s |
| 6 `module/loader.ms` header-import scan by byte | `check src/index.ms`, on top of 5 | 5 | 62.96G → 62.00G (−1.5%) | 4.79 → 4.52 s |
| 7 `transform/walker.ms` one closure per walk, not per node | emit-only, on top of 6 | 3 | 313.1G → 303.4G (−3.1%) | 37.82 → 36.68 s (load 45–115) |

lc-1 (load 0.1–7), `main` = `301653fce`, `cand` = `main` + fixes 4–6, both built by one builder
with `--gc=drc --danger`; same cells as the baseline, min user CPU, wall in brackets:

| cell | rounds | main | cand |
|---|---|---|---|
| check | 5 / 5 | 13.00 s (13.9) | 13.05 s (14.0) |
| emit-only | 5 / 5 | 59.70 s (54.4) | 57.30 s (53.2) |
| rebuild 1 file | 3 / 3 | 59.70 s (54.4) | 57.72 s (52.4) |
| cold | 2 / 2 | 595.2 s (2:31) | 591.2 s (2:29) |

- Fixes 4–6 take 4.0% off emit-only and 3.3% off a one-file rebuild on lc-1; `check` does not
  move there, so fix 6's Mac gain is below that host's noise.
- Not verified: fix 7 on lc-1; Windows.

## Measured 2026-10-21 — self-host baseline, and three front-end fixes

**Baseline, Linux x64 (lc-1, 8 cores, load 1.1–5.5).** Two stage-2 compilers, each built by
its own stage 1 with `--gc=drc --danger --lto=off`: `main` = `d64faf905`, `cand` = `main` + the
string-match label count (fix 1 below). Every command ran from a clone of `main` with
`MSC_NO_GLOBAL_CACHE=1` and a private `out/`; rounds interleave the two binaries; the table
gives min user CPU (`/usr/bin/time -v`), wall in brackets. `perf` is not permitted on that
host, so there are no instruction counts.

| cell | command | rounds | main | cand |
|---|---|---|---|---|
| check | `msc check src/index.ms` | 7 / 5 | 14.34 s (15.4) | 14.20 s (15.2) |
| no-change | `build src/index.ms --gc=drc --danger --lto=off --output=… --time`, record settled | 5 / 5 | 14.80 s (16.1) | 14.83 s (16.1) |
| rebuild 1 file | same, after appending a comment to `src/utils/string.ms` | 5 / 5 | 57.73 s (52.7) | 62.40 s (57.3) |
| cold | same, `out/` moved aside | 3 / 3 | 604.3 s (2:35) | 602.5 s (2:34) |
| test | `msc test src/index.ms` | 1 / 1 | 631.1 s (6:12) | 630.1 s (6:09) |

- A no-change build costs one `check`: it stops at "Up to date" after graph load and check.
- Rebuilding one file reruns the whole front end: phase A 31 s wall (`graph load+check` 15 s),
  DCE 7 s; of a cold build's 2:35, phase C (codegen + clang) is 99 s.
- Within one binary, rebuild-1-file rounds spread 57.7–69.0 s, so main vs cand there is noise.
  Fix 1 shows no gain on this host in any cell; on the Mac it does (below).
- `test` is red on both binaries in the same 11 cases (`preludePack`, the prelude seed tests of
  `compile.ms`): they need the global cache that `MSC_NO_GLOBAL_CACHE=1` turns off.
- A build started within the same second as the last source edit drops the project record
  (`writeProjectCache`, the `modifiedTime(path) >= _buildStartedSeconds` guard), so the
  next build reruns the whole front end: 57–69 s here instead of 15 s. A first battery that
  rebuilt right after `git checkout` measured that, not a no-change build.

**Fixes, macOS arm64 (load 8–44; min of interleaved rounds, `time -l` instructions retired as
the load-independent number).** Binaries built by one builder with the same flags, A = before,
B = after; emitted C of `src/index.ms` compared file by file.

| fix | workload | rounds | instructions | user |
|---|---|---|---|---|
| 1 `matchLower.ms` counts string labels, not arms | emit-only, stage 2, `--lto=off` | 3 | 468.0G → 368.4G (−21%) | 45.37 → 30.80 s |
| 1 | emit-only, stage 2, thin LTO (shipping config) | 3 | 349.2G → 342.4G (−1.9%) | 29.70 → 26.14 s |
| 2 `loader.ms` line starts in one `split` | `check src/index.ms`, thin | 5 | 74.83G → 70.16G (−6.2%) | 4.77 → 4.52 s |
| 3 `scanner.ms` identifier sliced once | `check src/index.ms`, thin, on top of 2 | 5 | 70.25G → 64.20G (−8.6%) | 4.37 → 4.13 s |

- Fix 1 changes emitted C on purpose (15 of 375 modules gain `switch` on `msStringHash`); it
  reaches the compiler binary only at stage 2, so a published binary carries it one sync later.
  Thin LTO inlines `msStringEquals`, which hides most of the chain it removes.
- Fixes 2 and 3 leave emitted C identical (0 of 375 files differ). Fix 2: on a non-ASCII source
  `indexOf(s, from)` re-walks UTF-8 from the start, so the old newline loop was quadratic;
  `inlineHeader` time over 404 modules fell 422 → 86 ms.
- LTO axis, same source: thin vs off is −7.5% instructions on `check` (81.1G → 75.0G) and
  −7.2% on emit-only (368.6G → 341.9G); user 5.75 → 5.34 s and 32.54 → 28.78 s at load
  19–45. This contradicts the 2026-09-27 "within noise" below, which compared user time only.
  Default cc vs clang at `--lto=off`: 81.9G vs 81.2G.

Tried and dropped (no time gain): `memchr` in the non-ASCII `msStringIndexOf` path (−0.7%
`check` instructions); caching disk reads per source provider plus one module identity per
import edge (75.14G vs 75.27G). Not verified: Windows; fixes 2 and 3 on lc-1 (written after
its battery started); `test` and cold builds with fixes 2 and 3.

## Measured 2026-10-05 — output identity inside the filesystem settle window (Windows x64)

The link-cache rewrite invariant failed during integration on `e8bf07ba`; its
cache implementation was unchanged from base `5c4246fb`. The correction from
`3d58ade7` reuses the existing settle rule; implementation and deterministic
consumer tests live in `src/compiler/cache.ms`.

On the integrated tree `ea6b6ab8`, a native consumer repeated 200 times:
write `first`, record the link cache, check the fresh hit, write same-size
`other`, then check for a stale hit. Output: `fresh link hits 200/200; wrong
rewrite hits 0/200`. The compiler was the integration gate's `--danger`
candidate, compiling the current cache source; this was not an isolated speed
benchmark. The cache module and its dependencies passed 761/761.

The cache owner reported the same rewrite probe on base code yielding 71/200
and 72/200 wrong hits, then 0/200 twice with the correction; those counts were
printed in that session, not independently re-run here. The owner also
mutation-checked both new settle-window tests by removing the settle check.

A successful link-cache hit promotes its verified content record once the
output has settled. Project-level up-to-date checks remain content-based until
a later real build rewrites their record; no stamp-only project-mode warm-hit
speedup is claimed. Full-suite, HCR, corpus and SAN verification belongs to
the combined integration gate, not these focused measurements.

## Measured 2026-10-04 — prelude serialization and compiler coexistence (Windows x64)

Control source tree `ed9d96bc8e9dcaddf87835a75cb8e4ead953aa74` (`7d2fc199`).
Control and candidate used the same std/runtime root; probe binaries were built with
`--danger --lto=off`. The machine was shared, not an isolated performance host.

A native probe obtained the real prelude with
`checkPreludeFromSource(resolveRuntimeDir() + "/std", ".cms")`, then timed three
`writePreludePack` calls per process. Three interleaved control/candidate pairs
gave nine writes each: median **925.514 → 282.590 ms**, ranges 848.645–957.300
and 253.082–403.473 ms. All resulting **2,492,423-byte packs were identical**.
The implementation and storage guards live in `src/checker/preludePack.ms`.

Two compilers sharing a std root previously gave deps-seed hits **0,1,0,0**
for A,A,B,A; after compiler-key isolation a candidate and its byte-appended twin
gave **0,1,0,1,1** for A,A,B,A,B. Generated C stayed identical on cold and warm
paths. Compiler coexistence and format ownership guards failed before their
respective fixes and passed afterward.

Graph-check changes (`src/checker/orchestrator.ms`, `checkModuleGraph`) preserved
all 134 C outputs for corpus 013/515/817/821 × DRC/ORC, four JS bundles, and all
351 C outputs when emitting the control compiler itself. Those eight native
app runs and four JS runs preserved stdout/exit; retained warm/generic HCR builds
also passed. A single self-host emission pair took 32.717 → 30.625 s wall,
with a warm control seed and cold candidate seed: not an isolated speed estimate.

Rejected: concatenating unchanged runs in `mangleModuleName` instead of individual
characters, 75.266 vs 75.502 ms for 20,000 calls; no measured gain, reverted.
Not measured here: an after-change full-gate speedup, peak RSS, or other hosts.

Gate measurements on the shared Windows host are not an A/B speed comparison:
- `tools/gate.sh --release` at `e68761b9`, tree `403f10323ef8ec76489cb5c355e7fb8809b6cf2e`:
  GREEN, 0 new, **30m04s execution + 37m47s FIFO wait = 67m51s wall**. Lanes ran
  in phases; summing concurrent lane durations does not give wall time.
- The optimization land at `a98052a2`, tree `76f773b373ef73c7778d281ff1c5b51473f5ec85`:
  GREEN build/suite/tests/selected corpus, **18m27s**, of which **13m52s** was
  selection over 542 programs. Control/candidate signature files were byte-identical.
  The selector's three C "differences" were known emit failures on both sides
  (704-macroExprHoist, 762-bitSetMacro, bitSetVectorLifecycle), not changed C hashes;
  failure-inclusive selection deliberately kept them for execution. All 539
  successful C comparisons matched; JS signatures also matched.
## Measured 2026-10-05 — independent output/configuration records

The accepted slice is project build-record isolation, not a new native cache. Source
tree `151cbd4023474de8cd5f1cdf4e50db530696185f`, binary SHA-256
`523ad0cf317fde8a0f07a501050b2fe018698e98df4a349e18e2ed5dd0627408`;
source-matched control `e5e932d0`, binary SHA-256
`1aa962d7c04806883316bf9d65875ae5ea7e8839ba44ddeb691e7771858b67fc`.

Shared Apple Silicon host, isolated HOME/local directories per compiler, global objects
disabled (`MSC_NO_GLOBAL_CACHE=1`), and the same counted clang wrapper limited to two
actual compiler processes. The app was `console.log(179);`, in a root containing spaces.
Command: `<compiler> build main.ms --cc=<counted-clang> --lto=off --emit-jobs=1
--colors=off --verbose --output=<A>`; B used `--release --output=<B>` in the same local
cache. Prime A, build B, then measure returning to A; alternate compiler order between
three pairs and return to B between pairs.

| Return to A after B | Control | Candidate |
|---|---:|---:|
| Wall seconds, three runs | 2.007 / 2.095 / 2.089 | 1.084 / 1.099 / 1.206 |
| Median seconds | **2.089** | **1.099** |
| Dispatcher compilations / links, each return | 1 / 1 | **0 / 0** |
| Preprocessor calls | 0 | 0 |
| App stdout | `179` | `179` |

This workload's median improved by about 47%; all three paired returns were faster.
The deterministic gain is avoiding dispatcher preparation and linking after another
output/configuration used the cache. Graph loading and checking still run. This is not
a cold-build, cross-worktree object-reuse or general throughput claim.

Consumer pin: `src/test/nativeBuildBoundary.ms`, group `project-cache`. Two independent
roots (one with spaces) gave two old-control failures; the candidate passed
eight contracts, including debug/release values `157`/`163` and changed-native-source
invalidation to `167`. The final source check reported `OK no type errors in 367 module(s)`.
C and JS app consumers both printed `179`.

`src/compiler/cache.ms` passed 18 focused contracts. Its transitive test command was
not fully green: the same 11 color-length assertions failed on unchanged control source
and on the candidate (control 729 pass/11 fail; candidate 731 pass/11 fail). No color
implementation was changed. A separate publication probe changed from
`initial hit / stale success accepted` before the guard to
`initial hit / changed source rejected` after it.

The implementation is in `projectCacheChanged` / `writeProjectCache`; the external
reference's per-output record choice is `compiler/extccomp.nim`
`jsonBuildInstructionsFile` (1092–1096), with dependency/output validation in
`changeDetectedViaJsonBuildInstructions` (1151–1169). Native/global object protocols,
test-shard preparation and frontend persistence are unchanged. These measurements
precede the land gate; installed behavior is not claimed by this table.

## Rejected 2026-10-05 — bare native compiler input snapshots

A direct-clang input-snapshot experiment also failed the end-to-end performance bar:
three-run medians were control/candidate **0.712/1.184 s** unchanged and
**2.513/2.606 s** empty-local. Native scheduling changed 32 misses to 32 hits, but that
was not a speedup.

Materialized compiler cache results alone were also insufficient for safety: editing
external inline-assembly `.incbin` bytes should have changed output `97` to `98`,
but the bare snapshot candidate returned `97` again. A no-asm language flag was
rejected because it changes `__has_extension` behavior. Full AST reconstruction as
an eligibility guard cost **14.183 s** for a C++ cold consumer. The user reduced the
scope to independent build records; all native adapter/protocol source was removed.
Do not reintroduce any of these experiments based only on cache-hit counts.

## Measured 2026-10-03 — native restore succeeds, unconditional preprocessing regresses warm builds

Unlanded candidate tree `73b5d67d1fde4cc9acc0a3c88436bc99993c7002`, binary SHA-256
`75e4a4f5a370d57e34323e42babb24c48fb42fa29e8a2fa0b0fe344a902fddaa`; source-matched
control `e5e932d0`, SHA-256 `1aa962d7c04806883316bf9d65875ae5ea7e8839ba44ddeb691e7771858b67fc`.
Shared Apple Silicon host; isolated HOME/local caches and one counted clang driver limited
to two actual C compiler processes. Command: `<compiler> build main.ms --cc=<counted-clang>
--lto=off --emit-jobs=1 --colors=off --output=<app>`, with `HOME` and `MSC_CACHE_DIR`
set to the isolated roots. Counters distinguish `-E` preprocessing from `-c` compilation.

| Case | Control native/generated/dispatcher compiles; links; preprocesses | Candidate | App stdout |
|---|---|---|---|
| Cold root A | 32/15/1; 1; 0 | 32/15/1; 1; 79 | `42` |
| Local-warm root A | 0/0/0; 0; 0 | 0/0/0; 0; 32 | `42` |
| Empty local, warm global, root A | 32/15/1; 1; 0 | 0/15/1; 1; 47 | `42` |
| Distinct entry/root B, candidate cold then empty-local/global-warm | not re-run | 32/15/1; 1; 79 → 0/15/1; 1; 47 | `30` |

Interleaved unchanged builds with independent output paths: control **0.568 / 0.561 s**,
candidate **3.297 / 3.674 s**, zero compilation/linking on both. The candidate's 32
preprocessor calls remain on every warm project hit. These are shared-host observations,
not throughput forecasts. Successful object restoration alone is not a performance win.

The discarded experiment's `nativeBuildBoundary.ms` groups `cache-reuse` and
`cache-races` ran **9 pass**, including seven control failures and two unchanged
header-invalidation controls. Those experimental groups were removed with the
native prototype on 2026-10-05; only the independent project-record consumer remains.
The old failures covered two empty-local roots, include shadowing, optional headers,
independent records and publication races.
Both entry variants also printed identical C/JS output (`42`, `30`). Retained LSP
valid/identical/invalid/identical/repaired input produced diagnostic counts `0/0/1/1/0`
and changed hover `int32` to `string`; no query-hit or semantic-cutoff counter was exposed.

Decision: do not land this preprocessing-per-lookup candidate as the cache performance fix.
Dropping preprocessing without complete include-resolution knowledge is not safe:
[direct-mode caches document the missing-header limitation](https://ccache.dev/manual/latest.html#_the_direct_mode).
The native-input experiment was removed after the 2026-10-05 scope reduction.
Its successful probes do not establish a permanent native cache contract.

Not verified: inline cache suite, full gate, full runtime/vendor/target/GC invalidation
matrix, concurrent publication matrix or installed behavior. Generated objects are still
local-only, test dispatcher/link preparation remains unconditional, and normal select/corpus
CLI processes do not retain a frontend query database.

## Measured 2026-09-26/27 — the dev-loop link tax is thin-LTO (Apple Silicon, 14-core)

Battery: 22 runs, min-of-rounds, uptime recorded per run (logs in
`/tmp/perf-baseline/` on the measuring machine), installed binary `d9d5e4a2`,
tree `90c6fb51`, machine idle at start (load 4.8).

| Config | wall (min) | phase D link | note |
|---|---|---|---|
| rebuild 1 file (comment), thin | **23.91s** | **14.82s (62%)** | clang 0.06s — object cache hit |
| rebuild 1 file, `--lto=off` | **9.07s** | **0.20s** | same machine, interleaved A/B |
| cold `rm -rf out`, thin | 37.96s | 15.50s | clang 11.4s (bitcode compiles fast) |
| cold, `--lto=off` | 42.07s | 0.25s | clang 28.5s — codegen paid at clang, once |
| no-change build | 3.83s | — | invocation floor, see below |
| emission, default vs `--emit-jobs=1` | 0.23s vs 2.73s | — | 341 workers, overlap=true |

The 2026-07-28 note below ("LTO choice is not the win it looks like") holds
for COLD builds only. In the dev loop the .c is unchanged, every .o is a
cache hit — but a thin-LTO link re-runs whole-program codegen every time
(15s here, swinging 15→55s across identical runs), while an off link of the
same objects is 0.2s of layout. Dev loop therefore builds with
`--danger --lto=off` (see CLAUDE.md §Build Commands).

The binary does not pay the LTO gain back on this workload: `msc check
src/index.ms`, interleaved ×5 (2026-09-27, load 6.2 at start), min **4.57s
user (thin) vs 4.61s user (off)** — within noise; quiet rounds differ ±5%
with unstable sign under external load. NOT verified: compute-heavy
workloads (corpus compiles) may still favour thin-LTO — release binaries
keep it.

Also re-measured: module count **356** (was 251); the invocation floor
(no-change build / `check` ≈ 3.8–4.0s wall, 0.9GB RSS) is graph load +
prelude-pack deserialize (~1.2s) + check (~1.6s) — the incremental-compilation
arc's target, not the C toolchain's. The `toolchainStamp` fixed cost below is
GONE as of this measurement: main-tree `vendor/` is 51MB now (was 3.0GB);
hello-world from a dev-tree binary runs 3.83s vs 1.06s warm from the
installed one.

## Measured 2026-10-05 — LTO on SBF (`--os=solana`)

platform-tools v1.57 (clang and ld.lld 22.1.2), LiteSVM; stage-2 compiler of `wt/sbf-lto`
against its base `09692dc8b`. CU counts are deterministic; build times were not measured
(load 12–47 during the runs).

`--danger` (or an explicit `--lto=`) compiles every module to bitcode, always full `-flto`;
the link merges it with `ld.lld -shared --entry entrypoint --undefined=abort --plugin-opt=emit-llvm
--lto-O<2|3>` (an `-r` merge when this was measured; see the 2026-10-11 section below), compiles the
merged module with the SBF clang (its frame errors still fail the build), then links as before. A
direct LTO link is refused: ld.lld gives bitcode the SBF machine (`0x107`) while clang's
objects and platform-tools' `libcompiler_builtins` are `EM_BPF` ("is incompatible with").
A thin `-r` merge writes only its last module, so SBF merges full whatever the strategy. A
build without `--danger` is unchanged (escrow `.so` byte-identical to base).

CU per operation through `std/solana/arithmetic` (100 iterations per shape, operands from an
opaque instruction byte, (CU − loop baseline) / 100; every shape logs the same value):

| shape | base `--danger` | LTO | shape | base `--danger` | LTO |
|---|---|---|---|---|---|
| i32 `a / b` | 26.7 | 18.7 | i64 `a / b` | 18.8 | 15.0 |
| i32 `a % b` | 23.0 | 15.8 | i64 `a % b` | 18.0 | 12.1 |
| i32 `a / 4` | 23.1 | 0.6 | i64 `a / 4` | 14.1 | 2.5 |
| i32 `a / 100` | 23.1 | 2.1 | i64 `a / 100` | 14.1 | 0.6 |
| i32 `a % 8` | 20.5 | 0 | i64 `a % 8` | 13.6 | 3.5 |
| i32 `x /= b` | 33.0 | 20.7 | i64 `x /= b` | 23.6 | 15.0 |
| i32 `x %= 3` | 26.6 | 11.1 | i64 `x %= 3` | 19.1 | 1.5 |

Escrow (`examples/escrow`, `--danger`): `.so` 76,144 → 67,928 bytes; every LiteSVM scenario
passes; make 31,025 → 28,590 CU, take 24,686 → 21,132, make (refund) 38,525 → 36,090,
refund 18,787 → 16,590, refused 619 → 519.

Hibernal's `settleAttack`, unsplit (probe copy of Hibernal `0c4ad93`): frame 5,696 bytes on
base (over the 4,096 limit, the build fails) → 3,392 with LTO; with `wt/obj-constr-dest`'s
object-literal destination also applied, 4,032 without LTO → 3,200 with it. The probe runs
2,056 → 1,063 CU with the same logged value.

A release build with `--lto=thin` merges the same way (i32 `a / 4` and i64 `a / 100` 0.6 CU each).
Not verified: other platform-tools versions, Hibernal's full tree, std/solana's own deployed
programs.

## Measured 2026-10-11 — the SBF LTO merge internalizes

The merge was `ld.lld -r`, which keeps every hidden function external, so LLVM never internalized
one and the interprocedural passes saw each as callable from outside (the merged object of the
`nested` bench program listed 224 non-local functions). It is now a `-shared` link with
`--entry entrypoint`: lld internalizes every symbol the entry does not name, and the merged module
holds `entrypoint` and `abort` as its only non-local functions. `--undefined=abort` keeps the one
function the SBF backend calls to lower a trap after the merge; without it the final link stops
with `undefined symbol: abort`. The output stays `-emit-llvm` bitcode compiled by the SBF clang,
so the `.so` is `EM_BPF`, flags `0x3` as before (`llvm-readelf -h` on all five programs below).

`examples/anchorBench/<name>/program.ms --os=solana --release`, platform-tools v1.57, LiteSVM with
`tools/solana/mainnetInactiveFeatures.json`, base `f421de59b` → candidate; the 102 refusals of
`BENCH_REFUSALS=1` all still refuse with the state unchanged and every error string unchanged:

| program | `.so` bytes | compute units |
|---|---|---|
| helloworld | 4,048 → 3,064 | init 1,578 → 1,490 |
| vault | 3,784 → 3,504 | deposit 1,702 → 1,683, withdraw 490 → 482 |
| nested | 6,112 → 5,304 | initialize 2,913 → 2,827, increment 226 → 223, reset 218 → 215 |
| prop-amm | 5,504 → 4,208 | update 144 → 144, initialize 1,520 → 1,440, rotate_authority 167 → 168 |
| multisig | 15,392 → 12,296 | create 2,922 → 2,778, deposit 2,401 → 2,399, set_label 569 → 545, execute_transfer 2,919 → 2,865 |

`examples/escrow/program.ms --release`: 30,512 → 25,912 B, and `tools/solana/escrow.mjs` passes on
both. `rotate_authority` is the one operation that costs a unit more. Not verified: other
platform-tools versions, a Windows host.

## Measured 2026-10-11 — the raise check of an immediately called closure

`accounts<T>()` expands to a closure written and called in place. The raise inference could not
resolve its callee, so it counted every such call as one that can raise, and the entry, `dispatch`
and every handler above it carried `if (msErr) goto BeforeRet_`. It now follows the call to the
routine the closure was lifted to (a closure value written once, or a closure pair called in place
under manual memory), and the hooks that destroy a closure no longer count as an extern handed a
routine. A closure whose body raises, nested or not, keeps the check
(`src/test/c/raiseChecks.ms`). With the internalizing merge in both columns, the five programs
from the section above, before → after:

| program | `.so` bytes | compute units |
|---|---|---|
| helloworld | 3,064 → 2,960 | init 1,490 → 1,481 |
| vault | 3,504 → 3,504 | unchanged |
| nested | 5,304 → 5,224 | initialize 2,827 → 2,824, increment 223 → 220, reset 215 → 215 |
| prop-amm | 4,208 → 4,176 | update 144 → 144, initialize 1,440 → 1,438, rotate_authority 168 → 168 |
| multisig | 12,296 → 12,144 | create 2,778 → 2,776, deposit 2,399 → 2,397, set_label 545 → 544, execute_transfer 2,865 → 2,862 |

The same programs built `--lto=off` are byte-identical before and after the first half of the fix,
which is why the second half (the closure pair called in place, which `--gc=manual` produces and
`--gc=drc` does not) matters on this target. Not verified: a closure bound to a `let`, or copied
(`msClosureCopy`) or reassigned (`msClosureSink`), still counts as one that can raise.

## Measured 2026-10-11 — MsMain inlined

`MsMain` no longer carries `noinline` under `--os=solana` (it did since `d2835679f`). The LTO merge
folds it into `entrypoint`; a fold that overflows the 4,096-byte frame (a probe with a 2,800-byte
local reached from `main` made `entrypoint` 4,864 bytes: `Function entrypoint overflows the
maximum allowed frame space`) is caught where `linkSolana` fails, and the dispatcher is recompiled
with `-DMS_SOL_MAIN_NOINLINE` and relinked, with a `note:` on stderr. The same probe builds without
LTO unchanged. A program that needs the fallback pays one failed merge on every build.

Same five programs, before → after (the raise fix applied in both columns); the 102 refusals all
still refuse with the state unchanged and the error strings identical:

| program | `.so` bytes | compute units |
|---|---|---|
| helloworld | 2,960 → 2,912 | init 1,481 → 1,475 |
| vault | 3,504 → 3,432 | deposit 1,683 → 1,676, withdraw 482 → 475 |
| nested | 5,224 → 5,168 | initialize 2,824 → 2,817, increment 220 → 215, reset 215 → 210 |
| prop-amm | 4,176 → 4,128 | update 144 → 141, initialize 1,438 → 1,432, rotate_authority 168 → 165 |
| multisig | 12,144 → 12,000 | create 2,776 → 2,763, deposit 2,397 → 2,391, set_label 544 → 519, execute_transfer 2,862 → 2,858 |

No bench program needed the fallback (`solanaMainInlines.ms` builds one that does). Not verified: a
program whose fold overflows through code other than `MsMain` (the fallback does not help it and
the second link reports the overflow), other platform-tools versions.

## Re-measured 2026-07-28 (supersedes the tables below)

Apple Silicon 8-core, `msc build src/index.ms --gc=drc --danger --cc=clang`.
Phases 3–10 landed: **Phase A is 6.3s, not 24.7s** — it beat its own
~12–14s target, and the roadmap below is stale from that row down.

| Phase | Then (plan) | Now | Note |
|---|---|---|---|
| graph load + check | ~8s | **5.8s** | module graph load |
| A — parse + check + transform | 24.7s | **6.3s** | check 3.5s, xform 1.3s, analyze 0.8s |
| B — DCE | 0.7s | **0.4s** | |
| C — codegen + clang | 9.6s | **19.0s** | codegen 1.3s, **clang 13.7s** |
| D — link | 2.1s | **21.4s** | thin-LTO does whole-program codegen at link |
| total | 45–50s | **52.8s** | |

**The MetaScript half is now ~8s; the C toolchain is ~35s of the 53s.**
Optimising the compiler further buys little — the remaining lever is LTO
strategy. `--lto` is an axis separate from opt level (`off|thin|full`,
`cc.ms` `ltoFlags`); `--danger` defaults to thin. Measured cold, thin and
off finish within 0.2s of each other (55.6s vs 55.8s on a cold global
object cache) because the work just moves between compile and link — so
LTO choice is not the win it looks like. What actually moves the number
is cache state: the same cold-`out/` build costs **~32s** once
`~/.metascript/cache/objects/` is warm, and a rebuild after touching one
file lands **20–35s**.

Beware of comparing single runs: build wall time in this tree swings
20s→65s purely on cache state. Two measurements taken minutes apart
suggested a fresh binary was 2.3× slower than the installed one; a
controlled A/B (`rm -rf out` for both) showed **32.47s vs 32.25s** —
identical. Always re-measure both sides under the same cache state before
attributing a regression.

### Test suite — the real dev-loop cost, and where it went

`msc test src/index.ms` test-execution time: **419.6s → 17-19s (~23×)**,
3342/3342 unchanged. Wall clock for the whole command is ~40s, because
compiling the test binary (~21s warm) is now the larger half. The entry-by-entry
cost table that followed from this (full battery cheaper than a single-module
entry) was dropped on 2026-09-19: `msc test src/test/fixedbugs/bug048.ms` took
12 s wall at load 18 that day, and the full suite was not timed beside it, so the
comparison is open. The scope regression now lives in [`src/test/lang/testBlockScope.ms`](../src/test/lang/testBlockScope.ms); the timing above remains historical. Cache and load traps: [`TESTING.md`](TESTING.md).

Root cause was not codegen or clang: `checkProgram()` — the convenience
wrapper every inline test uses — called `buildPreludeContext()` on
**every** invocation, re-parsing and re-checking the whole std prelude
(~1s each). `checkPass.ms` alone has 213 such tests → 219.7s, 52% of the
suite. The three other prelude call sites (`eval.ms` `_raiserPreludeCtx`,
transam `db.preludeCtx`, orchestrator's per-compile `baseCtx`) already
cached; `checkProgram` was the lone outlier. Fixed by a
`standalonePreludeCtx()` accessor matching the `raiserPreludeCtx()` idiom.

Do NOT push that cache down into `buildPreludeContext` itself: the
orchestrator stamps `targetOs` onto its base context, so a shared
instance would leak one build's target into the next.

Note this does **not** speed up `msc build` — the build path checks
through `checkProgramWithRegistry`, which never touches the wrapper
(controlled A/B above confirms: 32.47s vs 32.25s).

Suite time after the fix is dominated by `lsp/handlers/lifecycle.ms`
(35s ≈ 65% of what remains), then `orchestrator.ms` 9s and
`transam/index.ms` 5.4s. The harness itself is in the C runtime
(`runtime/core/test.h`) and runs one linked binary serially (~150% CPU) —
parallelising it is the next lever if the suite needs to get faster still.

---

## Context & Current State

Self-build timings on a typical dev laptop (Apple Silicon, 8-core, warm OS cache) as of this plan:

| Workload | Time |
|---|---|
| User `msc run hello.ms` — first run on machine (cold) | **2.4s** |
| User `msc run hello.ms` — global cache hit | **1.0s** |
| User build, fresh project (global cache hit) | **2.1s** |
| Compiler self-build — native `msc build src/index.ms --gc=drc` cold | **45–50s** |
| Compiler self-build — native incremental (no source change) | **8.7s** |

### Already shipped (don't re-plan)

- **Phase 1 — Global `.o` cache** at `~/.metascript/cache/objects/` (content-addressed, VERSION-stamped, safe across upgrades). Hits for all `@compile` runtime/vendor `.c` files.
- **Phase 2 — Parallel `@compile` directives** via `spawn`/`waitFor` (`processCompileDirectives` gather → dispatch → collect). Real thread-level parallelism on the C backend.
- **Lambda-lifting loop-escape fix** — closures created inside a loop body now allocate a per-closure env with a snapshot of captures. Unblocks spawn/.then/actor/stored-callback-in-loop correctness. Prerequisite for any further parallelization.

### Where the remaining time goes (native cold, per `--time` breakdown)

| Phase | Time | % | Dominant cost |
|---|---|---|---|
| A — parse + check + transform (251 modules) | **24.7s** | 55% | **DRC refcount overhead on AST infrastructure** |
| B — DCE | 0.7s | 2% | — |
| C — codegen + clang | 9.6s (codegen 4.6s, clang **only 2.5s**) | 21% | codegen walks |
| D — link | 2.1s | 5% | single clang invocation |
| startup / misc | ~8s | 17% | module graph load, project cache check |

Validated via `--gc=none` A/B: rebuilt msc without DRC, re-ran self-build.
Phase A dropped **24.7s → 14.6s** — confirms **~10s of Phase A is pure RC refcount ops**.

**We cannot ship `msc` with `--gc=none`** because `msc lsp` is long-running and would leak. The target is to reclaim that ~10s via smarter data structures and eliminated allocations, not by turning off DRC.

---

## Goal — MET, by other means. Re-justify before working the phases below.

| | Plan's target | Actual 2026-07-28 |
|---|---|---|
| Native cold self-build | ~15s | **32s** (`rm -rf out`, warm object cache); ~20s warm |
| Native Phase A | ~12–14s | **6.3s** — beat the target by 2× |

**Phases 3, 4 and 5 never shipped** — checked on the tree: `syntheticToken`
still has 12 call sites, `createNode` still assigns `comments = []`, and
`SourceLocation` is still an `interface`. Phase A got fast anyway. So every
saving estimate below is attributed to work that did not happen, against a
baseline that no longer exists.

Do NOT pick up a phase because this file lists it. Re-measure Phase A first
(`msc build src/index.ms --time`); at 6.3s out of a 53s build it is no
longer where the time is. The remaining cost is the C toolchain — clang
13.7s + link 21.4s under thin-LTO — which none of these phases touch.

---

## Phase 3 — Eliminate synthetic Token allocation in transforms

**Problem**: every `makeIdent`, `makeBlock`, `makeNumber`, `makeNull`, `makeBool`, `makeString`, and similar transform helper calls `createNode(kind, data, syntheticToken(loc))`. `syntheticToken(loc)` allocates a throwaway `Token` (heap + msRefHeader) used only to pass `.line` / `.column` into `createNode`, then immediately discarded.

`createNodeAt(kind, data, loc: SourceLocation)` already exists with 80+ per-kind overloads in `std/meta/node.ms:552+` — takes SourceLocation directly, no Token round-trip.

**Scope**:
- Replace every `createNode(K, D, syntheticToken(loc))` with `createNodeAt(K, D, loc)`
- Audit hot call sites in `src/transform/util.ms` + the lowering passes
- Delete `syntheticToken` once unused

**Files to touch**: `src/transform/util.ms`, `src/transform/lowering/*.ms`, `src/transform/native/*.ms` (grep for `syntheticToken`)

**Expected win**: **~2–3s** off Phase A.

**Risk**: low. Mechanical grep-replace. `createNodeAt` is the documented transform-builder path.

**Verification**:
- `msc check src/index.ms` — type-check green
- Cold native self-build with `--time` — phase A delta vs baseline
- Test suite — 2768 pass unchanged

---

## Phase 4 — `Node.comments = null` instead of empty-array-per-node

**Problem**: `createNode` / `createNodeAt` unconditionally set `n.comments = []`, allocating a fresh `msRefArray` (heap + RC header) per Node. Grep confirms `.comments` is read ONLY by `src/compiler/fmt/printer/*` during `msc fmt`. On `msc build` / `msc run`, `.comments` is 100% dead weight but pays the allocation cost for ~100K nodes per build.

**Scope**:
- `createNode` / `createNodeAt` in `std/meta/node.ms`: init `n.comments = null as unknown as Token[]`
- Parser `src/parser/util.ms:18` — lazy-init on first push:
  `if (node.comments === null) { node.comments = []; } node.comments.push(...)`
- Fmt readers — treat null as empty:
  `if (node.comments !== null && node.comments.length > 0) { ... }` (grep `.comments.` in `src/compiler/fmt/`)

**Files to touch**: `std/meta/node.ms`, `src/parser/util.ms`, `src/compiler/fmt/printer/*.ms` (small — ~6 call sites)

**Expected win**: **~1–2s** off Phase A. Proportional to Node count (~100K empty-array allocs eliminated).

**Risk**: low. Readers are few and localized to fmt.

**Verification**:
- `msc fmt some_commented.ms` — comments still preserved (manual spot check)
- Test suite green
- Native phase A delta

---

## Phase 5 — `SourceLocation` from `interface` to `struct`

**Problem**: `SourceLocation` in `std/meta/node.ms:213` is an `interface` (ref-counted, heap-allocated) despite being **16 bytes of plain int32** — `line`, `column`, `endLine`, `endColumn`. No reference fields inside. Every `Node.location = loc` under DRC does `msIncref(newLoc); msDecref(oldLoc)` — pure overhead.

Every Node has one. Every Token has line/column (not a SourceLocation directly, but the pattern compounds). ~100K+ SourceLocation instances per build.

**Scope**:
- Change `export interface SourceLocation` → `export struct SourceLocation` in `std/meta/node.ms:213`
- Audit consumers: anywhere that treats SourceLocation as nullable (`null as unknown as SourceLocation`) — struct can't be null; replace with a sentinel (e.g. `makeLoc(0, 0)`) or make callers handle it explicitly
- `Node.location: SourceLocation` — field becomes inline value instead of pointer; bumps Node struct size by ~8 bytes (vs pointer + deref)
- Verify no site that aliases the SourceLocation across lifetimes (e.g. stores a pointer somewhere and expects mutation visibility)

**Files to touch**: `std/meta/node.ms`, audit `src/**/*.ms` for `SourceLocation` null assignments and mutation patterns

**Expected win**: **~3–5s** off Phase A.

**Risk**: medium. Struct semantics differ — no null, copy-by-value. Any code that mutates a `loc` after assignment and expects the shared Node to see it would break. Needs a quick audit pass.

**Verification**:
- Type-check green
- Native phase A delta
- Test suite — unchanged
- Error location rendering correct (pick an example failing `msc run` and check that error messages still point to correct line/col)

---

## Phase 6 — Replace `NameSet` with `Set<string>`

**Problem**: `src/transform/context.ms:42` defines `NameSet` as `{ items: string[] }` with O(n) `nameSetContains` (linear scan) and O(n²) `nameSetAdd` (contains-check then push). Used in hot transforms: `lambdaLifting.ms` (13 call sites), `destructorLifting.ms` (46 call sites), `dce.ms` (12), `analyzer/inject.ms` (9), `codegen/c/declarations.ms` (7), etc.

Example load: lambda lifting's `rewriteOuterRef` calls `nameSetContains(capturedNames, d.name)` for every identifier in every statement. With 20 captured names × 10,000 identifiers per module × 251 modules = **50 million string comparisons**.

`Set<string>` already exists in `std/core/struct.ms:243` — hash-based open addressing, proper O(1) avg.

**Scope**:
- Option A (safer): update `nameSetContains` / `nameSetAdd` implementations to back `NameSet` with a hash set internally, keeping the external API intact
- Option B (cleaner): replace `NameSet` type with `Set<string>` at all call sites

**Files to touch**: `src/transform/context.ms` + call-site files

**Expected win**: **~2–4s** off Phase A (algorithmic).

**Risk**: low-medium. Semantic equivalence of Set vs NameSet operations; iteration order may differ (audit where `items[]` is iterated in order and whether order matters).

**Verification**: test suite, cold build timing.

---

## Phase 7 — `lookupVarType` / `lookupVarResolvedType` hashing

**Problem**: `src/transform/lowering/lambdaLifting.ms:176-190` — backwards linear scan over `varTypes: VarTypeEntry[]` on every lookup. Same algorithmic anti-pattern as `NameSet`. Called during env-field type resolution for every captured var.

**Scope**:
- Add `varTypesByName: Map<string, VarTypeEntry>` alongside the ordered array (preserves insertion-order semantics for other callers if needed)
- Rewrite `lookupVarType` / `lookupVarResolvedType` to use the map
- Keep `varTypes: VarTypeEntry[]` for anything that needs ordered iteration

**Files to touch**: `src/transform/lowering/lambdaLifting.ms`

**Expected win**: **~0.5–1s** off Phase A (algorithmic).

**Risk**: low.

**Verification**: lambda lifting tests pass; spawn-in-loop repro still correct.

---

## Phase 8 — Per-scope symbol hash map

**Problem**: `src/checker/symbol.ms:141` `lookupSymbol` does linear scan of each scope's `symbols: Symbol[]` up the parent chain. Uses `nameId: int32` (fast cmp) but iterates every symbol. Module scopes have hundreds of symbols; checker walks the chain per identifier.

**Scope**:
- Add `symbolsByName: Map<int32, Symbol>` to `Scope`
- `lookupSymbol` / `lookupLocal` use the map
- `symbols: Symbol[]` kept for ordered iteration where needed (e.g. codegen, export enumeration)

**Files to touch**: `src/checker/symbol.ms`

**Expected win**: **~1–2s** off Phase A (algorithmic, benefits both).

**Risk**: low-medium. Need to keep both representations in sync on add/remove.

**Verification**: test suite, native phase A delta.

---

## Phase 9 — `Symbol.{overloads,defaultParams,staticFields}` default to `null`

**Problem**: `std/meta/node.ms:101` — Symbol always has three `Symbol[]` / `Node[]` fields that are empty for 95%+ of symbols (non-overloaded functions have 0 overloads, most functions have 0 default params, non-classes have 0 static fields). Every symbol allocates 3 empty `msRefArray` structs regardless.

**Scope**:
- Change default to `null`
- Update `createSymbol` / wherever symbols are constructed
- Readers null-check before iterate

**Files to touch**: `std/meta/node.ms`, `src/checker/**/*.ms`, `src/transform/**/*.ms` (searchers: grep `.overloads`, `.defaultParams`, `.staticFields`)

**Expected win**: **~0.5–1s**.

**Risk**: low. ~10-20 reader sites to audit.

**Verification**: test suite.

---

## Phase 10 — `Token` from `interface` to `struct`

**Problem**: `src/lexer/token.ms:45` — Token is an interface. Contains `kind: TokenKind`, 2 strings (`value`, `rawValue`), 2 numbers (`line`, `column`). Strings under DRC are reference types, so the struct-with-refs pattern (struct containing string fields, compiler auto-generates destroy that decrefs strings) applies naturally.

~100K tokens per module lex × 251 modules = ~25M tokens total across a self-build. Each is currently a heap alloc + msRefHeader + inherent RC traffic.

**Scope**:
- `export struct Token` (requires auto-derived destructor since it owns 2 strings)
- Tokens become values in `tokens: Token[]` — array holds them by value
- Copy / move semantics audit for existing Token consumers

**Files to touch**: `src/lexer/token.ms` + `src/lexer/scanner.ms`, `src/parser/context.ms`, `src/parser/util.ms` (reads `.comments`), plus anywhere Token is passed around

**Expected win**: **~1–2s** on native.

**Risk**: medium. Token is used widely; copy-by-value semantics change.

**Verification**: test suite (parse tests), `msc fmt` sanity check.

---

## Phase 11 — `NodeData` inline in Node (big refactor, biggest potential)

**Problem**: Every Node has `data: NodeData`, which is always an object literal heap-allocated. `{name: "foo"}` for an Identifier, `{left, right, operator}` for a BinaryExpr, etc. ~100K allocations per build just for NodeData.

One path: fold Node + NodeData into a single flat struct using a discriminant and a "fat" union of fields — trading Node struct size for zero-per-node data allocation.

**Scope**: major. Affects every NodeData variant cast in the codebase (`node.data as BinaryExprData` patterns).

**Expected win**: **~2–4s** on native (largest single allocation-elimination win).

**Risk**: HIGH. This is a compiler-wide refactor.

**Suggested deferral**: after Phases 3–10 are measured. If the target still isn't met, pursue this. Otherwise, skip.

---

## Phase 12 — Parallelize module clang compilation (P3 from earlier discussion)

**Problem**: module compilation (`compile.ms:1017-1040`) serially invokes clang for each of 251 modules. Now measurable at only **~2.5s** cold because most modules hit the module-level cache (`isCCodeCached`). On a true-cold scenario (e.g. fresh CI checkout) this is ~50s serial → ~13s 4-way parallel.

**Scope**: same gather → dispatch → collect pattern as the Phase 2 `processCompileDirectives` refactor.

**Expected win**: **~1.5s** on warm cold-build, up to **~35s** on true-cold (CI / fresh checkout).

**Risk**: low. Pattern already proven by Phase 2.

**Priority**: lower than 3–10 — the clang work is already small in the common case.

---

## Phase 13 — DRC codegen optimizations (long-term)

Optimize the native codegen to emit fewer RC ops:

- **Escape analysis**: when an object doesn't escape its scope, skip incref/decref entirely (like Rust's borrow checker for the 80% case)
- **Move elision**: detect `let x = expr; use(x)` where `x` isn't used after — emit move semantics (zero-RC)
- **Coalesce dec/inc pairs**: consecutive incref-decref of same pointer in straight-line code cancels out
- **Inline hot RC paths**: `msIncref`/`msDecref` become macros for small objects, not function calls

**Expected win**: ~5–15s on the compiler self-build, but applies to **all user programs compiled with DRC**. Compound value across the ecosystem.

**Risk**: HIGH. Each optimization needs correctness proof (no use-after-free, no double-free).

**Priority**: after Phases 3–10. This is months of work; the infrastructure fixes above are hours each.

---

## Recommended execution order

1. **Phase 3** (syntheticToken → createNodeAt) — mechanical, ~2-3s, no risk
2. **Phase 4** (comments = null) — ~1-2s, localized
3. **Phase 5** (SourceLocation → struct) — **~3-5s, the single biggest DRC win**, moderate audit
4. **Phase 6** (NameSet → Set) — ~2-4s, algorithmic, benefits both backends
5. **Phase 7** (lookupVarType hash) — ~0.5-1s
6. **Phase 8** (lookupSymbol hash) — ~1-2s, benefits both
7. **Phase 9** (Symbol arrays null) — ~0.5-1s
8. **Phase 10** (Token → struct) — ~1-2s
9. Measure. If native cold ≤ ~16s, stop here — target met.
10. **Phase 11** (NodeData inline) — only if still gap remaining
11. **Phase 13** (DRC codegen) — independent long-term project

~~Phases 3–10 together: **~10–17s** savings on native Phase A. Phase A 24.7s → ~8–15s → native cold self-build ~15–25s.~~ **VOID** — Phase A reached 6.3s without any of them (see Goal). The projected savings exceed the phase's entire current cost; re-measure before believing any number in this section.

## Verification common to every phase

Each phase lands independently:

1. `msc check src/index.ms` — type-check green
2. `msc test src/index.ms` — test suite 2768 pass / 8 fail (baseline unchanged)
3. Cold native self-build with `--time`: measure Phase A delta

How to time anything on this shared machine:

- Report the **minimum** round per cell, never a sum or a mean. Run an untimed warmup first. A summed benchmark at load 4-54 once reported `direct` 0.74x of `tree`, and the min-of-rounds rerun of the same sweep gave 1.38-1.45x, with the opposite sign (2026-08-11).
- Interleave the cells within a round and reverse their order on alternate rounds. A fixed order measures the later cells warmer.
- Record `uptime` with the result. Ratios between interleaved cells survive load, absolute numbers do not, so say which one a conclusion rests on.
- If runs of one binary disagree on the sign of a difference, the measurement is broken. Fix it before averaging anything.
- `msc run` and a plain `msc build` compile at `-O0`. Time C output built with `--danger`.

## Non-goals

- Shipping `msc` compiled with `--gc=none` — breaks `msc lsp` (long-running, would leak)
- Rewriting the compiler in a different language
- External profilers / instrumentation harnesses — timing breakdown via `--time` is sufficient

---

## Measured 2026-09-05 — `toolchainStamp()` content-hashes ALL of `vendor/` on every invocation

**Symptom**: any `msc` binary sitting in the dev tree pays a ~45-60s FIXED cost per invocation (hello build: 44-64s real, user 23-27s, sys 10-16s), while the installed `~/.metascript/bin/msc` does the same build in 2.5s. Measured on two independent dev-tree binaries (one from a clean worktree, one from the main tree) in fresh target dirs; binary sizes are equal (~11.3MB), so it is NOT an optimization-level difference. `sample` puts the time in `collectFilesSorted` (`src/compiler/cache.ms`) plus memmove/malloc churn.

**Cause**: `toolchainStamp()` = hash(binary) + `stampTreeInto(runtime/)` + `stampTreeInto(vendor/)`, where `stampTreeInto` recursively content-hashes EVERY file under the tree, once per process (memoized in-process only). The tree root is the compiler-root (binary location), so a dev-tree binary scans the dev `vendor/` = **3.0GB** (rust 1.2G, zig 654M, typescript-go 507M, prettier 221M, biome 187M — reference clones, not C libs), while the installed root's `vendor/` is 51MB (argon2, mbedtls, miniz, monocypher).

**Verified fix for test rigs**: prune the worktree's `vendor/` COPY down to the installed set → same probe drops 52s → **1.74s** (30x). Do NOT prune the main tree's vendor (dev reference clones are wanted there).

**Downstream costs previously misattributed**: guard battery "~1.5 min/guard", corpus lane at ~105s/program (9h projection vs the documented ~19 min), worktree suite 228s vs 120s. All were this stamp scan, not slow binaries.

**Real fix (pending, needs design sign-off)**: `toolchainStamp` should stamp only the trees that can invalidate compiled artifacts (runtime headers + the C-source vendor libs actually reachable by `@compile`), or read a manifest, instead of walking whatever happens to live under `vendor/`.
