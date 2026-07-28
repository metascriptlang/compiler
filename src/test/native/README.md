# Native execution tier

The rest of the suite (`bun run test-ms`) transpiles MetaScript to TypeScript
and runs it on Bun — so the **C runtime never executes** there: DRC reference
counting, the ORC cycle collector, the actor scheduler, and the spawn worker
pool are all invisible to `test-ms`. That blind spot shipped real regressions
green (an over-free crash, a leak/over-free attempt) because every check passed
on Bun while the native binary was broken.

This tier closes it. Each case is a real `.ms` program compiled to a **native
binary** via clang and run under **both `--gc=drc` and `--gc=orc`**, asserting:

- **exit 0 / no signal** — catches over-free, use-after-free, misaligned access.
- **peak RSS under a bound** — catches leaks (a leak doubles RSS into hundreds
  of MB; the bound exists to catch *unbounded growth*, not police MB of jitter).
- **stdout contains `expectStdout`** (when set) — catches *correctness* bugs
  that exit 0 with low RSS (wrong output, not a leak/crash). This is what
  catches the actor heap-string corruption, which leaks/crashes nothing — it
  returns the wrong string. Gate the marker on an internal invariant (print it
  only after the result checks out).

Peak RSS comes from `/usr/bin/time -l` (kernel high-water mark — no sampling
race).

## Run

```bash
MSC=./msc msc run src/test/native/run.ms   # point MSC at a HEAD-matched binary
```

The runner is itself MetaScript (dogfood) — no Bun. Slow (clang build per case
× 2 GC modes) — run it before/after any change to DRC injection, transforms
touching RC, the actor scheduler, or the spawn/await runtime.

## Layout

```
src/test/native/
├── README.md           # this file
├── run.ms              # the runner (MetaScript; `msc run`) — builds+runs each case
├── manifest.ms         # the case list (name, program, RSS bound, xfail modes)
└── programs/*.ms       # self-contained real programs, each with a main()
```

Runner, manifest, and programs are all here under version control — the whole
tier is MetaScript, compiled + run by msc.

## Adding a case

1. Drop a self-contained `programs/foo.ms` with a `main()`. Keep accumulators
   bounded (`% n`) — a signed-overflow UBSan trap in the test program would
   masquerade as a runtime crash.
2. Add an entry to `manifest.ms`. Pick `maxRssMb` generously above the honest
   steady state.
3. If it documents an OPEN bug, set `xfail: ["drc","orc"]`. The runner reports
   XFAIL (not a suite failure) and flags **XPASS** when it starts passing — the
   signal to drop the xfail and turn it into a permanent regression guard.

## Current cases

| Case | Purpose |
|---|---|
| `clean-loop` | Always-green control — heap interface churn that must stay flat. |
| `closure-array` | bug033 native repro (closure-array scope-exit destroy) — runs the C DRC path `test-ms` can't reach. |
| `paralock-nested` | PARALOCK guard — spawn + actor + async crossed, massive interleave. Standing answer to "did my change break PARALOCK seamlessly?". |
| `actor-heapstr` | **xfail** — heap-concatenated string through an actor field reads back corrupted (a literal round-trips). The std/http multi-WS broadcast path; pre-existing at HEAD. Caught by `expectStdout`, not exit/RSS. |
| `leak-call-in-cond` | **xfail** — fresh RC call used for a non-RC read leaks (awaiting the Phase-3 call-hoist fix). |
| `array-literal-strings` | **xfail** — array literal of string elements in a hot loop leaks (found by this tier on its first run). |
