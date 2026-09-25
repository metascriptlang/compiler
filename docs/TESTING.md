# Testing — tiers, the corpus contract, and what a run costs

The rules an agent needs while writing a test are in [`src/test/CLAUDE.md`](../src/test/CLAUDE.md). This file holds the detail behind them: one example per tier, the corpus authoring contract, which compiler a runner exercises, and the emit-diff recipe `tools/gate.sh` runs.

Moved here from `src/test/CLAUDE.md` on 2026-09-19. Re-checked that day: every directive below is read by `src/test/corpus/run.ms`; `msc test src/test/fixedbugs/bug048.ms` took 12 s wall at load 18. NOT re-measured: every other timing and count in the emit-diff section keeps the date it was taken on, and the tier examples were not recompiled.

## Tiers

### Inline `test "name" { ... }` block

Use for **local, function-level invariants**. Most tests in `src/**/*.ms`
modules are this kind.

```ms
test "createResult — ok type accessible via getResultOkType" {
    const r = createResult(numberType(), stringType());
    assert isResult(r);
    const ok = getResultOkType(r);
    assert ok !== null && ok.kind === TypeKind.Number;
}
```

Rules:
- One assertion concept per test.
- Test name = the invariant in plain language.
- Place in the same file as the code under test (close to source).
- `assert` only — no `expect()`-style chaining.

### Language tests (`lang/*.ms`)

End-to-end, user-visible language behavior. No compiler imports — the file
must compile cleanly to C via the self-host pipeline.

```ms
test "Generic DU — multiple instantiations coexist" {
    const a = eitherDivStr(10, 2);
    const b = eitherDivInt(10, 0);
    if (a.ok) assert a.value === 5;
    if (!b.ok) assert b.error === -1;
}
```

Rules:
- One file per feature group.
- Every `lang/foo.ms` must be imported in `index.ms`.
- Use only the standard library and language features — never reach into
  `src/checker/`, `src/codegen/`, etc.

### Regression tests (`fixedbugs/bugNNN_*.ms`)

One file per shipped bug. Append-only — old entries never get deleted or
refactored, even if the underlying API changes.

Required header block:
```ms
// bugNNN — <one-line summary>
//
// Symptom:    <what the user observed>
// Root cause: <where the actual fix lives, file path optional>
// Fix:        <what changed — one line>
//
// Body: minimal repro as a `test "bugNNN: <slug>" { ... }`.
```

Rules:
- File name: `bugNNN_short_slug.ms` where `NNN` is the next free 3-digit
  number. Look at the highest existing number in `fixedbugs/` and add 1.
- Test name: `"bugNNN: <slug>"` so failures point back to the file.
- Keep the repro minimal — the smallest program that triggers the bug.
- Add the import to `fixedbugs/index.ms`.

### Pipeline tests (`c/*.ms`, `js/*.ms`)

Test the FULL pipeline (parse → check → transform → analyze → codegen)
using `compileToC` / `compileToJS` from `helpers.ms`. Inspect the emitted
C/JS source directly.

```ms
test "Result.ok lowers to tagged union literal" {
    const out = compileToC("function f(): Result<number, string> { return Result.ok(42); }");
    assert out.ok;
    if (out.ok) {
        assert out.value.contains("._tag = ");
        assert out.value.contains(".v0.value = 42");
    }
}
```

Rules:
- Useful for asserting **that codegen emits a specific C/JS pattern**.
- Avoid pinning every byte of output (brittle); pin the load-bearing tokens.
- These are NOT a substitute for runtime behavior tests — pair with a
  `lang/*.ms` test that runs the same code.
- `compileToC` puts only the test source in the module graph — the prelude gives it
  the NAMES of `std/`, never the declarations. A source that reaches a std
  declaration needs `compileToCWithStd`, and an `import` is not what decides it: a
  prelude call whose type mentions a std type is enough. Measured 2026-09-20 —
  `const r = parseJson("…"); const v = r.value;` (no import at all) fails under
  `compileToC` as `check: Property 'value' does not exist on type 'object | object'`,
  or reaches codegen as `internal: unresolved type (kind=48)` when the checker lets
  it through; the same source is green under `compileToCWithStd` and under `msc run`.
- `compileToJS` checks and transforms ONE module, without monomorphization or
  macro expansion, so transforms see different shapes than a real build
  (`arr[i]` arrives without the `HiddenDeref` a real JS build wraps around
  `arr`; measured 2026-08-20, not re-measured). A JS-emission claim needs a real `msc build --target=js` run and a
  corpus program.
- A macro with no call site is not checked at all: a body containing
  `const x: int32 = 1.5` passes `msc check` until a call is added (measured
  2026-09-19). Every macro probe gets a call, and one known-red plus one
  known-green case on the same binary before its verdict is trusted.

### Phase-handoff tests (`handoff/*.ms`)

Pin contracts BETWEEN phases. E.g. "after transform, every `MatchExpr` is
gone" or "after analyze, every RC-typed local has a destroy call". Catches
silent contract drift between adjacent phases.

### Corpus programs (`corpus/programs/`)

Standalone programs (not `test {}` files) that print to stdout and exit —
flat `NNN-topic.ms`, or `NNN-topic/main.ms` with sibling modules for
multi-module cases. ONE runner (`corpus/run.ms`, MetaScript dogfood)
executes every program through its lanes.

Authoring contract — the runner stays a dumb executor; the program's
contract lives entirely in its directive head (leading `// @...` comment
lines), and ALL determinism obligations live on the program:

- **Directive head** — one directive per line:
  - `// @exit: <n>` — expected exit code, all lanes (default 0).
  - `// @skip-js: <reason>` — C-only program; the JS lane skips it and
    logs the reason. The skip list doubles as the JS backend's worklist.
  - `// @maxrss: <MB>` — RSS program: built + run under `--gc=drc`,
    `--gc=orc` and `--danger` (`-O3 -flto`, `--cc=clang`) via
    `/usr/bin/time -l`, asserting exit + signal + stdout + peak RSS (the
    former native/ tier semantics).
  - `// @stdout: <substr>` — merged output must CONTAIN the substring.
    Enforced on every lane (RSS, SAN **and** parity). Byte-compare across lanes stays the
    primary assertion, so most programs still want no `@stdout`; reach for
    it when the lanes cannot judge correctness on their own, i.e. when
    every lane could be wrong in the same way (see `013-int64Fidelity`,
    which additionally grades itself into the exit code).
  - `// @xfail(<lane>): <reason>` — known-fail for one lane; XPASS is
    reported loud so a stale marker cannot lie silently.
  - `// @serial` — contention-sensitive (actor/spawn stress): its run
    cells execute one at a time after the parallel drain.
  - `// @ledger-slack(<MangledType>): <N>` — san lane only: exactly N
    objects of that type legitimately survive exit (module-level RC
    values are NOT destroyed at exit — probe-verified 2026-07-29; the
    compiler-side question is open). EXACT-match: a diff other than N
    fails, and diff 0 with slack declared fails as "slack unused" so the
    marker self-cleans if global-destroy ever lands. Never use @xfail for
    a survivor — it would mask every future real leak in that program.
- **Programs WITHOUT `@maxrss` are parity programs**: run through C-drc,
  C-orc, C-danger and (unless `@skip-js`) JS-on-node.
- **EVERY program is byte-compared across all of its lanes** — no golden
  files, nothing to bless, nothing to drift. The axes are independent and
  each catches its own class: C↔JS (backend), drc↔orc (GC mode changing
  observable behaviour), O0↔danger (UB the optimizer is free to exploit,
  and DCE masking leaks). A program whose output legitimately differs on
  one axis is classified out with `@xfail(<lane>)` and a reason — never
  by weakening the comparison.
- **Deterministic stdout only**: no timers, no randomness, no
  pointer/address or RSS/timing prints. Ordered output, fixed loop bounds.
- **Name files `NNN-topic`**, clustered by hundreds (0xx basics,
  1xx strings, 2xx DU/match/types, 3xx closures, 4xx async/actor,
  5xx std, 6xx RC/DRC stress, 7xx meta/macro/jsx).
  Append-only, like `fixedbugs/`.
- **Write RC-stress shapes deliberately**: churn in loops, values relayed
  through calls then dropped unread, throw/catch unwinding mid-build,
  refcounted values held across await. The plain lane asserts behavior;
  the same program under the sanitizer lane becomes a leak/double-free
  probe for free.

Divergences between lanes are CONTRACTS, not normalizations: when lanes
legitimately differ (e.g. uncaught-error report format on stderr), the
runner documents it once (stderr is not compared for `@exit:` programs) —
it never fuzzy-matches. If float printing differs between the C and JS
lanes, fix number formatting in the runtime once; never paper over it in
the runner.

### Lifecycle guards (`guard/*.ms`)

One invariant per file, built with the DRC ledger (`-DMS_DRC_LEDGER`):
aborts on the 2nd finalize of a live pointer, dumps per-type
alloc/destroy balances at exit. A guard is only trusted after it has been
PROVEN RED against the drift it targets. Methodology and ledger details:
`guard/README.md`; runner: `guard/run.ms`, run on Raiser.


## Which compiler is under test — the two-tree convention

A compiler resolves `std/` and `runtime/` **relative to its own location**
(verified, not assumed), so the binary you run decides which support trees
come with it:

| binary | is | reads std/ + runtime/ from |
|---|---|---|
| `./msc` (repo root) | the candidate you just built | **this repo** — your edits |
| `msc` (PATH → `~/.metascript/bin/msc`) | the last PUBLISHED build | `~/.metascript/` — the last sync |

So the loop is: edit the repo → `msc build … --output=msc` (the published
compiler builds the candidate) → **test the candidate** → `./msc run tools/syncLocalBinary.ms --target=raiser`
only once green (publish: candidate + repo std/runtime become the installed
ones). Between build and sync the two trees legitimately differ — that gap is
the whole reason the runners must be told which compiler to exercise.

Convention, applied by `corpus/run.ms` and `guard/run.ms` alike:

- **Default = `./msc` when it exists**, else the installed `msc`. Plain
  `msc run src/test/corpus/run.ms` therefore tests what you just built, with
  no ceremony.
- **`MSC=<path>` overrides** (e.g. `MSC=msc` to check the published build,
  or a release binary for a bisect).
- The chosen binary is **printed in the runner header** — never silent.
- Two roles, two binaries, on purpose: `msc run <runner>` compiles/executes
  the *harness* (use the stable published one — a broken candidate must not
  stop the harness from starting), while `MSC` names the *subject under test*.
  Running `./msc run <runner>` alone inverts this: the harness gets the new
  compiler while every corpus program is still built by the old one.
- The lookup climbs at most four directories from the binary, then falls back
  to the cwd (`resolveRuntimeDir`, `src/utils/path.ms`). A binary copied to a
  directory with no `std/` above it, run from a cwd without one, fails with
  `Undefined variable 'console'` rather than naming the missing tree (KNOWN-ISSUES
  L51); run tests from the tree root.
- Probing a `runtime/` or `std/` edit with the installed `msc`: build a private
  home that symlinks every entry of `~/.metascript` except the tree you replace.
  A home missing `zig`/`vendor` fails with `'stdint.h' file not found`. A header
  edit re-keys the object cache: after appending `#error` to
  `runtime/core/string.h`, a warm rebuild failed on it (measured 2026-09-19,
  v0.2.55), so no `rm -rf out` is needed after a runtime edit.
- A type error in a file you did not touch that names a `std/` type, or an
  undeclared runtime symbol at link, means the binary reads a different tree
  than you edited: `diff -rq std ~/.metascript/std` first. An unresolved builtin
  reported inside `std/**` means the builder is older than the commit that
  introduced it (`git log -S'<Name>' -- src/checker`); rebuild `./msc` with the
  installed `msc`.

Other rules that make these numbers real:

## What a run costs

Traps, measured 2026-07-28 unless a line says otherwise:

- **`out/` caches `msc test`.** The object cache is fingerprint-keyed; a no-change
  re-run skips codegen and the C compiler. **Do not `rm -rf out` before a suite** —
  besides losing the cache it triggers the cold-build link race below.
- **Cold-build link race.** `rm -rf out` followed by a suite fails with
  `undefined symbol: __ms_tests_…` or `failed to deduplicate literals`. Re-running
  warm is clean. Any red that names a DIFFERENT file each run is this, not your
  change.
- **Timings swing 6-8× with machine load.** Another session's `zig` build put the
  8-core machine at load 28 and turned a 29s suite into 251s, and flipped
  individual files between pass and `link failed`. Check `uptime` before trusting
  any number, and never conclude from single runs — one such pair suggested a
  fresh binary was 2.3× slower than the installed one; a controlled A/B on both
  sides in the same minute showed 32.47s vs 32.25s, i.e. identical.
- **`msc test` accepts exactly one file** — no directories, no globs, no
  `--filter`. Grouping is only possible through an aggregator module.
- **A `fixedbugs/bugNNN` test runs the SOURCE checker**, so it proves red and
  green for a checker or codegen rule before any rebuild of the compiler.

## Emit-diff selector — corpus confidence for narrow fixes

Measured 2026-09-05 on the bug130 fix (checker identity-fit for narrowed
union refs): 180 programs × 2 binaries = **334 s**, 2309 emitted C files
hash-compared, **0 diffs** — with the selector's sensitivity PROVEN on the
bug shape first (20-line C diff on the minimal repro). Full corpus skipped
with evidence, not silently: every lane compiles the same emitted C, so
byte-identical C means no lane outcome can change. The C argument covers the JS lanes too: identical
C ⇒ the changed checker branch never fired for that program ⇒ the JS emitter
saw the same checker output as before.

**`tools/gate.sh` runs this recipe itself** whenever the diff pulls in the
corpus or SAN lane. Control = the compiler at the merge base (`git archive src`
built into `out/gate/ctl-<key>/msc`, `<key>` hashing the merge base's `src/` minus
`src/test` plus `std/`, the three newest kept). A select on a clean tree files its
candidate and emits under the candidate's key, so after a land the next gate
finds its control built and every unchanged program's emit reused. A program
whose C emit fails on either side counts as changed. Both binaries sit under
`out/gate/`, so they resolve the same `std/` and `runtime/`, and every program
emits from its own cwd at one path (`out/gate/emit/work/<name>`, moved to
`emit/ctl` and `emit/cand` afterwards for diffing). The signature per program
is the C of `--gc=drc` plus `--gc=drc --danger` and the JS bundle; the differing
set goes to the runner as `MSCORPUS_ONLY=<exact names>` (SAN: the C set only),
a JS-only set adds `MSCORPUS_LANES=c,drc,js,esm`, and `known-red.json` is read
for those programs alone. Changed files under `corpus/programs/` always join
the set.

Measured 2026-09-19 (14 cores, load 15–20), candidate `832301f3` against
control `08ac0858`, a range that holds the `needsTry` analyzer fix:

| step | result | time |
|---|---|---|
| select (control build + 2 × 215 programs × 3 emits) | 104 differ in C · 3 in JS · 2 touched · 110 byte-identical | 8m27s |
| corpus on 105 programs | 5 red · 5 known · 0 new | 12m32s |
| SAN on 104 programs | 4 red · 4 known · 0 new | 5m27s |

Same day, candidate against control `c6311440` (one transform refactor in
between): select 7m49s · 0 differ in C · 0 in JS ⇒ corpus skipped, gate GREEN
in 10m55s. A zero set on a FIX means the corpus has no coverage of it (step 4
below), and the gate says so.

The 110 identical programs are the A/A evidence (two different binaries, no
path or cwd noise); `011-truthy` is the sensitivity evidence (its C gained the
`msErr` check the fix adds). Which emits carry signal, measured on all 215
programs: `--gc=orc` C is byte-identical to `--gc=drc` C on 215/215, so it is
not emitted; `--danger` C differs on 34/215 (range checks dropped), so it is.

The gate does NOT narrow — it runs the lane whole and says why — under
`--lanes`, `--release`, `--record`, and when a changed path cannot show in
emitted code: `runtime/`, `std/`, `vendor/`, or a file directly under
`src/test/corpus/` (the runner). NOT verified: the give-up paths (control fails
to build, an emit pass loses programs) have never fired, and no gate run has
yet produced a JS-only set (`MSCORPUS_LANES` was exercised by hand on two
programs: 8 pass, parity `js↔esm↔c`).

Why not just run the corpus: the toolchain stamp content-hashes the msc
binary + `runtime/` + `vendor/` (`src/compiler/cache.ms`), so EVERY new
candidate binary starts cold — a full run never gets cheaper while
iterating.

Recipe:

1. Two binaries, one tree state: control = HEAD (throwaway `git worktree`,
   built with the last good binary), candidate = HEAD+fix. Run each from its
   OWN cwd — `--emit=c` writes `out/debug/<mangled>.c` relative to cwd and
   the flat mangled names collide across programs.
2. For every `programs/NNN-*` entry: `msc build <entry> --emit=c --gc=drc`,
   then sweep `out/debug/*.c` aside into a per-program dir. Shared std
   modules are identical anyway; the entry module is what carries the diff.
3. Hash-compare both sides per program. Identical ⇒ provably unaffected.
   Differing set A ⇒ run `MSCORPUS_FILTER=<exact-name>` (plain + SAN) on
   exactly those programs.
4. "A empty AND corpus green" on a brand-new bug shape means the corpus had
   NO coverage of it — the fix's repro belongs in `corpus/programs/` anyway
   (the bug-fix checklist in `src/test/CLAUDE.md`), and that new program is the one thing to run through all
   lanes.

Traps, all paid for on 2026-09-05:

- **Prove sensitivity FIRST.** Emit the minimal repro (as a PLAIN program —
  `build` never emits `test {}` bodies, a test-block repro diffs 0 and proves
  nothing) with both binaries and confirm the C actually differs / the
  control actually fails. `assert` is test-block-only; plain repros narrow
  with `if (x.kind === ...)`.
- **Const-foldable repros lie**: one literal-based repro folded to a
  composite temp on the control binary and compiled fine there. Build values
  through a function call so the argument is a real local.
- `MSCORPUS_FILTER` is substring (`name.contains`), not prefix — "2" matches
  012/102/202/…. `MSCORPUS_ONLY=a,b` takes exact names and fails loud on a
  name that is not a program; `MSCORPUS_LANES=c,drc,js,esm` builds those
  parity cells alone (unknown lane, or combined with `MSCORPUS_SAN=1`: error).
- The selector degenerates for broad changes (codegen/runtime/analyzer work
  that rewrites most programs' C): |A| large ⇒ the full run is the honest
  option. |A| is self-calibrating, no guessing up front.
- SAN on hosts without libasan (scoop MinGW: `cannot find -lasan`) is
  environment-blocked — record it, don't chase phantom code bugs.
- Heap corruption inside the compiler itself: build it under ASan with the
  DRC slab off, `msc build src/index.ms --gc=drc --sanitize=address
  --passC=-DMS_SLAB_MAX=0 --passL=-fsanitize=address --cc=clang
  --output=/tmp/msc-asan`, then compile a real program with it. zig cc on
  macOS cannot link the ASan runtime, and slab recycling hides use-after-free
  (`runtime/drc.h`). Fixing one layer often exposes the next; re-run until clean.
  Recipe from 2026-06-11, not re-measured.

More traps, measured 2026-09-06 on the pattern-default AST-slot change
(186 programs, 245 emitted C files per pass):

- **The emitted C embeds the tree's absolute path** — in the C filename, in
  module-qualified type names (`Box__ZprivateZtmpZga95w4m8ZgOms`), and in every
  `#line`. Two trees at different paths therefore hash-differ on every
  tree-local module even when nothing changed. A/A check (one binary, identical
  source at two paths): entry module 5532 bytes on both sides, raw md5 differs,
  **byte-identical after normalizing the path token + the `#line` paths**;
  instantiated generics (`Box__int32`) carry no path, so nothing semantic
  drifts. So step 1 above works, but either run both passes from ONE path
  (swapping the binary between them) or normalize before hashing — a raw hash
  compare across two trees is 100% false positives.
- **std does not move with the tree**: it resolves next to the BINARY
  (`resolveRuntimeDir` walks up from argv0), so std modules emit identical C in
  both passes (8 of 9 here) and the whole signal is the entry module plus
  `_dispatch.c`, which names it. Corollary: to build a tree with a given
  compiler, copy that binary INTO the tree — and on macOS `cp` over a mapped
  inode yields SIGKILL, so `rm` + `cp` + `codesign -s -`.
- **Both binaries must be at the same optimisation level.** A -O0 control
  (113 MB) costs 10-25 s per program against ~1 s for a release candidate
  (11 MB) — rebuild the control with the same builder and flags, or the sweep
  runs for hours and compares two different things.
- **Keep the emitted-C cache warm.** Clearing `out/debug/*.c` between programs
  costs ~25 s per program instead of ~1.1 s: 186 programs is 80 min vs 3 min.
- **The prelude pack is a GLOBAL cache** (`$HOME/.metascript/cache/prelude`),
  shared by every tree on the machine. Change a `NodeData` shape and it serves
  stale entries — clang then reports mangling errors that read exactly like a
  compiler bug (16 of them). It self-heals once the pack key rotates; rule it
  out with `MSC_NO_PRELUDE_PACK=1` (plus `MSC_NO_GLOBAL_CACHE=1`).
- **Path mangling escapes uppercase as decimal ASCII** (`/Users` → `Z85sers`,
  `_` → `95`, `.` → `O`); type names do NOT go through it. A hand-rolled
  mangler that maps C files back to sources and misses this reports every
  program as missing (179 false ENTRY_MISSING).
- Two `msc test` runs in the SAME tree race on `out/debug/.cache` — serialise
  them, or the second run's results are contaminated.

---
