# Testing — tiers, the corpus contract, and what a run costs

The rules an agent needs while writing a test are in [`src/test/CLAUDE.md`](../src/test/CLAUDE.md). This file holds the detail behind them: one example per tier, the corpus authoring contract, which compiler a runner exercises, and the by-hand emit-diff A/B method. No gate runs that selector.

Moved here from `src/test/CLAUDE.md` on 2026-09-19. Re-checked that day: every directive below is read by `src/test/corpus/run.ms`; `msc test src/test/fixedbugs/bug048.ms` took 12 s wall at load 18 (historical path; the scope regression now lives in [`src/test/lang/testBlockScope.ms`](../src/test/lang/testBlockScope.ms)). NOT re-measured: every other timing and count in the emit-diff section keeps the date it was taken on, and the tier examples were not recompiled. An older timing/counter record without an explicit
source tree has **tree not recorded**; it is not a current budget or fresh certification.

Terminology: a gate **lane** is a stage; a backend/configuration run of one corpus program is
a **cell**. Historical transcripts and environment names such as `MSCORPUS_LANES` retain the
spelling used then; they do not add another current meaning of “lane”.

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

### Regression contracts

Name the compiler invariant and the consumer boundary, not the event that
found it. A checker refusal belongs with its `handoff/` family; an observable
program belongs under `lang/` or in a standalone semantic corpus entry;
emitted ABI details belong under `c/` or `js/` only when the emitted form
itself is the contract. Reuse an existing owner before adding a file.

Keep a repro variant when it catches an independent mechanism; drop
emitted-token and compile-only assertions once a real consumer proves their
intended behavior. A contract that is red only because of an open compiler bug
sits in `<module>Parked.ms` beside its module: no index imports it, the inbox
card names it on its `Parked at:` line, and the fixing session moves it into
the module and registers it.

Ownership measurements from the 2026-10-03 root sweep:
- `spliceSelfAliasing` keeps an inserted borrowed string/ref alive before deleting
  its source slot. The pre-fix string probe aborts with ASan heap-use-after-free in
  `msStringArraySplice3`; after retaining/copying before mutation, DRC and ORC
  print `splice-self-alias all-ok`, with ledger `alloc=5 destroy=5`.
- `arcContextualLiteral` exercises local and returned `Arc<T>` literals. Before
  native boxing, both values print correctly but ledger `alloc=2 destroy=0`.
  Routing through existing `msBoxArc` makes DRC/ORC ledger `2/2`; C and JS print
  `arc-contextual 8 first 9 second`.
- `checker3pass/scenarios/arcLiteralSafety` applies the constructor's existing
  deep-immutable pointee gate to contextual literal creation. Before the gate,
  an `Arc<SharedData>` containing a class reference checks clean; after it,
  C and JS reject it naming `SharedData`. The primitive/string literal consumer
  above remains accepted.

The explicit `new Arc(...)` constructor was separately checked on C; this does
not claim JS constructor support or coverage of every atomic-container operation.

Generic distinct value-read recovery (2026-10-04), source tree
`f34e8238f2e2952c4d9f54986cf0dd8caf083dce`: the old root-sweep candidate
rejects `genericDistinctValueRead` on C and JS because integer arithmetic and unary
reads reach fitting as `float64`/`number`. Preserving the substituted distinct body
before inspecting a generic template restores the existing value-read protocol;
the new C/ORC/JS consumer prints `generic-distinct-value 14 21 3 true 4`.
`MSC=./msc-next MSCORPUS_ONLY=genericDistinctValueRead MSCORPUS_LANES=c,orc,js
MSCORPUS_BUILD_JOBS=1 MSCORPUS_JOBS=1 ./msc-next run --target=raiser
src/test/corpus/run.ms` reports `4 pass · 0 fail · 0 xfail · 0 xpass`.
This is a historical recipe/result: `orc` is not a current corpus cell. Current cell names
and selection rules are the runner's header; do not copy this old environment unchanged.
`msc-next test <file> --tests-in-dir` passes `lang/macroHiddenConversions` 9/9,
`handoff/valueOfProtocol` 19/19 and `c/protocols` 31/31; the macro file also
passes with `--target=js` (9 local tests, 70 including std dependencies).
This covers integer/float bodies, operand order, single evaluation and protocol
visibility/refusal; it does not establish a full integration gate.

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

Compiler-source contracts run in a **native test binary**; adding `--target=js`
asks the JS backend to compile the checker itself, not to exercise the checked
program on JS. For example, run
`msc test src/test/handoff/intLiteralBoundary.ms --tests-in-dir`.
Its runtime sibling is [`013-int64Fidelity.ms`](../src/test/corpus/programs/013-int64Fidelity.ms),
run through the real C and JS backends rather than duplicated in the helper tier.
Measured 2026-09-27 with installed build `b899f456`, source baseline tree
`2eaafb12be3cc19060f2ed49feebdf7a6186f3c5`: the original and moved diagnostic
contracts both passed 14/14 natively; the runtime sibling printed
`int64-fidelity all-ok` on C and JS. This is not a whole-tier green claim.

### Corpus programs (`corpus/programs/`)

Standalone programs (not `test {}` files) print deterministic stdout and exit.
Use a semantic entry name (`topicName.ms`, or `topicName/main.ms` with sibling
modules); the older `NNN-topic` names remain discoverable. `corpus/run.ms`
discovers both forms and runs each entry through its selected cells.

Authoring contract — the runner stays a dumb executor; the program's
contract lives entirely in its directive head (leading `// @...` comment
lines), and ALL determinism obligations live on the program:

- **Directive head** — one directive per line; the supported directives and their meaning
  are the header of `src/test/corpus/run.ms`, not a second copied inventory here.
  Pin the whole `@stdout` line: `acc=` passes on any value and `prevented` passes inside
  `not prevented`. Byte comparison across cells remains the primary assertion; add an
  absolute output oracle when all cells could be wrong together (`013-int64Fidelity`).
  `@ledger-slack` is exact, not a broad exemption: never replace it with `@xfail`, which
  would hide every future real leak in that program.
- **Programs WITHOUT `@maxrss` are parity programs**: run through the `c`,
  `danger` and (unless `@skip-js`) `js` and `esm` cells, plus `raiser` when
  `MSCORPUS_RAISER=1` turns it on.
- **EVERY program is byte-compared across all of its cells** — no golden
  files, nothing to bless, nothing to drift. The axes are independent and
  each catches its own class: C↔JS (backend), O0↔danger (UB the optimizer is free to exploit,
  and DCE masking leaks). A program whose output legitimately differs on
  one axis is classified out with `@xfail(<lane>)` and a reason — never
  by weakening the comparison.
- **Deterministic stdout only**: no timers, no randomness, no
  pointer/address or RSS/timing prints. Ordered output, fixed loop bounds.
- **Name new programs by the invariant**, not the date or bug number. Merge a
  new variant into its existing owner's program when it has the same consumer
  and oracle; create a separate entry when its failure mechanism is distinct.
  The older numbered entries stay runnable while their contracts are reviewed.
  Measured on Windows with the candidate built from `252fadec`: a direct
  `MSCORPUS_ONLY` run of 17 semantic entries reported `88 pass · 11 fail`;
  twelve entries passed C, ORC, danger, JS and ESM plus parity, while five
  exposed target-specific failures and stayed outside the repo. Raiser and
  SAN were not exercised for these entries. The `e8431cc9` land selector
  picked two unrelated known-red programs, so its green verdict is not
  evidence that the newly added corpus entries ran.
  Follow-up Windows VM measurement with the retained ESM gate compiler
  (compiler key `2f1a29cdbb3a5d21d8ab012b43184341e34b45b2`): direct
  `msc run <entry> --target=raiser` runs of all thirteen installed semantic
  successor entries matched their exact stdout, **13 pass / 0 fail**; the
  staged integer-width variant printed `widths -128 2 24464 32767 -1`.
  This clears the six previously observed VM consumer failures on that
  candidate, not the remaining unregistered families or remote integration.
  No new native full-gate, SAN or thin-LTO claim accompanies this VM slice.
  On landed ESM base `cd52b8e1`, seven changed checker/runtime owner files
  passed **112/112 native tests** via
  `msc test <owner> --tests-in-dir --target=c --emit-jobs=1`; the directory
  selector excluded compiler dependency tests, so this is not a full-suite
  verdict. The strengthened generic-module consumer also ran natively with
  `1 r0 3`. Mandatory unregistered owners still require their own proof.
- **Write RC-stress shapes deliberately**: churn in loops, values relayed
  through calls then dropped unread, throw/catch unwinding mid-build,
  refcounted values held across await. The plain cell asserts behavior;
  the same program under the sanitizer lane becomes a leak/double-free
  probe for free.

Divergences between cells are CONTRACTS, not normalizations: when cells
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

### Flow A/B (`src/bench/compiler/run.ms`)

Not a pass/fail tier: it tables what one change moved, flow by flow, between two compilers. Use and reading: [`BUILD-PERF.md`](BUILD-PERF.md) §Measuring by flow.


## Which compiler is under test — the two-tree convention

A compiler resolves `std/` and `runtime/` **relative to its own location**
(verified, not assumed), so the binary you run decides which support trees
come with it:

| binary | is | reads std/ + runtime/ from |
|---|---|---|
| `./msc` (repo root) | the candidate you just built | **this repo** — your edits |
| `msc` (PATH → `~/.metascript/bin/msc`) | the last PUBLISHED build | `~/.metascript/` — the last sync |

The table covers what a binary *reads* when it compiles a program. What it
*carries* is the std/ + runtime/ of the compiler that built it, compiled in:
Raiser host bridges (`src/compiler/meta/hostTable.ms`) run that copy. A
candidate built by `msc build … --output=msc` carries `~/.metascript/`, the
last sync, and its link response file `msc_link.rsp` names that root in every
`-iquote <root>/std/…` flag. Measured 2026-10-21 on 60cddf0ab: such a build ran
`execCaptureKeepsEveryByte` on Raiser with the 16 MiB cap a sync had already
removed from the repo, while the same source built by `./msc build` (the repo
root) printed every byte.

So the loop is: edit the repo → `./msc build src/index.ms --danger --cc=clang --output=msc`
(`msc build` only when no `./msc` exists yet, then once more with `./msc`) →
**test the candidate** → `./msc run --target=raiser tools/syncLocalBinary.ms`
only once green (publish: candidate + repo std/runtime become the installed
ones). The sync refuses a binary whose `_link.rsp` is missing, was written by
another build, or names a root other than the checkout it publishes. Between
build and sync the two trees legitimately differ — that gap is the whole
reason the runners must be told which compiler to exercise.

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
  A home missing `vendor` fails with `'stdint.h' file not found`. A build run from a tree root finds the bundle at
  `~/.metascript/msc-toolchain` (`nativeToolchainPath`); with no bundle anywhere, a build fails with
  `no prepared toolchain bundle is published for host` and names `--cc=zig` and `--cc=<path>`. A header
  edit re-keys the object cache: after appending `#error` to
  `runtime/core/string.h`, a warm rebuild failed on it (measured 2026-09-19,
  v0.2.55), so no `rm -rf out` is needed after a runtime edit.
- A type error in a file you did not touch that names a `std/` type, or an
  undeclared runtime symbol at link, means the binary reads a different tree
  than you edited: `diff -rq std ~/.metascript/std` first. An unresolved builtin
  reported inside `std/**` means the builder is older than the commit that
  introduced it (`git log -S'<Name>' -- src/checker`); rebuild `./msc` with the
  installed `msc`.
- **Bootstrap-only std guards:** when std needs a compiler change the previous
  builder lacks, guard it with a capability symbol `when (msc<Capability>)`,
  defined in `createDefineTable` (`src/compiler/defines.ms`), and drop the
  guard once every builder carries the change. The guarded declarations are not
  optional behavior for the new compiler.
- **A source-matched binary can still carry its builder's codegen bugs.** When
  the change fixes codegen or lowering used by the compiler itself, build stage 1
  with the previous builder, then build the candidate with stage 1. Keep both
  binaries at the tree root so each reads this tree's support files:

  ```bash
  ./msc build src/index.ms --danger --lto=off --output=msc-stage1
  ./msc-stage1 build src/index.ms --danger --lto=off --output=msc-stage2
  ```

  Measured 2026-10-04: earlier old-builder candidates failed corpus
  1031/1032/1034 on Raiser; the stage-2 candidate of source tree
  `f88ea688515a01a79ddbff3043dd7c95a9fb0c3f` passed them on C, ORC, danger,
  JS, ESM and Raiser. Program 1031's Raiser output starts
  `0.10000000149011612 1 16777216 16777216 0.10000000149011612`;
  1032 starts `0.10000000149011612 0.01666666753590107 0.3333333432674408`.
  Run with `MSC=<stage-2 binary> MSCORPUS_ONLY=1031-float32Parity,1032-float32ConstantSlots,1034-numericIntoUnionMember MSCORPUS_RAISER=1 ./msc run src/test/corpus/run.ms`.
  This is local bootstrap/parity evidence, not an installed-binary or release
  fixpoint claim, nor an isolation of every source/bootstrap change between the
  earlier candidates and this tree. Syncing remains a separate operation.

  A second measured bootstrap on source tree
  `80e7b14e66bc590e0a38b4ce1bbf181cc9d29977` used
  `./msc-n2s-roots3 build src/index.ms --gc=drc --danger --lto=off --cc=clang --output=msc-n2s-staticfix`,
  then the same command with `./msc-n2s-staticfix` as builder and
  `--output=msc-n2s-static-stage2`. Both built 349 modules. Stage 1 compiled
  the corrected Symbol-keyed Raiser global code but
  `./msc-n2s-staticfix run --target=raiser src/test/corpus/programs/255-staticStorage.ms`
  printed `static-storage FAIL builds=9`. The same command using
  `./msc-n2s-static-stage2` printed `static-storage PASS`. A native probe
  of the corrected Raiser source emitted the value global and its guard with
  `LoadGlobal` / `StoreGlobal` on both slots.
  C/DRC, C/ORC and JS printed `static-storage PASS`; SAN subset 255 passed
  1/1. This is not an installed-binary, HCR or whole-gate verdict.

Other rules that make these numbers real:

## Native watch boundaries

On 2026-11-04, source tree `7f4551e76f172d04f46f5e58779372b927166fda`, the stock JSON control in `tools/bundler-plugin/rollup.test.js` reproduced a missing rebuild on RTX/Linux 7.0.0-42, Node 24.1.0 and Rollup 4.44.1. The one-core remote job used `--no-msc`; no compiler or MetaScript plugin participated in the selected watcher.

```sh
ROLLUP_MODULE=<isolated-rollup>/dist/es/rollup.js node --test --test-concurrency=1 --test-reporter=tap \
  --test-name-pattern='^stock Rollup observes immediate external JSON updates after initial BUNDLE_END$' \
  tools/bundler-plugin/rollup.test.js
```

The unchanged control and a separate public-observer/strace variant each reached the original 15000 ms timeout: `# tests 1`, `# pass 0`, `# fail 0`, `# cancelled 1`, `# skipped 0`; each returned 1. Other cells were filtered, not passes. The observational variant changed only this test body (patch SHA256 `2a59c7ae9661b4ce697a2b23fbe8032874a74103b5833fe777a0874490cfdd6c`). Collection returned 2 after a TAP-escaping decoder error; read-only recovery from complete child stdout writes did not turn the wrapper green.

In that diagnostic execution, the changed JSON write completed before the process created its first inotify descriptor. Its exact JSON watch was registered 1.694 ms after write completion, and the parent directory 4.190 ms after. BUNDLE_END and END had already been emitted; no `onInvalidate`, change, restart or second build followed before timeout. Later kernel records were fixture teardown, not delivery of the changed write. This proves initial native coverage was absent for this diagnostic write, not the syscall order of the untraced control, the other recovery cases, a throttle cause, or a production fix.

Reference: Rollup commit [`5a7f9e215a11de165b85dafd64350474847ec6db`](https://github.com/rollup/rollup/tree/5a7f9e215a11de165b85dafd64350474847ec6db), `src/watch/watch.ts` `Task.run` / `updateWatchedFiles` and `src/watch/fileWatcher.ts` `FileWatcher.watch`: terminal build events do not await asynchronous native registration. Awaiting END alone would not cover the observed write. Do not replace the retained immediate-write/recovery requirements with retries or delays. Other versions/platforms and all remaining Rollup recovery roots are unverified by this observation.

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
- **Compiler-source handoff contracts run natively.** `--target=js` on a
  source-importing checker test asks JS to compile the compiler itself; a
  JS behavior claim needs a standalone language/corpus consumer instead.

## Crypto assurance suite

`src/test/crypto/suite.sh [--slow]` runs every test of the native MetaScript crypto port (`std/crypto/pure`): `portTests.ms` on C and JavaScript (known-answer vectors, Wycheproof, differentials against the public surface), `portDiffTests.cms` on C (X25519 against the public surface, the hardware-path probe), the differentials against the vendored C from `src/test/crypto/port` over the oracle in `src/test/crypto/oracle` (`diffTests.ms` on C and JavaScript, `cDiffTests.cms` on C), and with `--slow` `portSlowTests.ms` (P-256/P-384 Wycheproof), `rsaKeyGeneration.ms` and `pbkdf2LongVector.ms`. No gate runs it; run it for a slice that changes `std/crypto/pure` or `runtime/crypto`, and before the public std/crypto switches to the port. The public API vectors (`src/test/crypto/index.ms`) stay in the land gate's tests lane. It refuses a compiler outside the repository root, because that compiler would test its own std. A new `*Test.ms` beside the port joins `portTests.ms` by hand (a C-only one joins `portDiffTests.cms`), and one that imports the oracle lives in `src/test/crypto/port` and joins `diffTests.ms` or `cDiffTests.cms`, because nothing under `std/` imports the oracle; a test red because of an open compiler card moves to a `*Parked.ms`, as `ecNativeParked.ms` does.

Measured 2026-11-06 with the host's copied compiler: m1m (Darwin arm64), default cells **3/3 green** with `portTests.ms` C 298/298 in 74 s, JS 295/295 in 46 s, `portDiffTests.cms` 18/18 in 14 s; rtx (Linux x86_64, msc 251a01c4f41), `--slow` **8/8 cells green, 650/650 tests** in about 6.5 min (C 51 s, JS 40 s, diff 34 s, slow Wycheproof C 74 s / JS 7 s, key generation 58 s, PBKDF2 2^24 iterations C 92 s / JS 29 s). Its first runs found an intermittent memory corruption in a spread of a module const on worker threads (compiler card `2026-11-06-spread-of-a-module-const-array-races-on-worker-threads`): the suite binary crashed 1 run in 12, the EC worker-thread test alone 7 in 60. After the oracle moved into `src/test/crypto/oracle` (2026-11-09, rtx, candidate of 1e028d2d254 with `TMPDIR` off the full `/tmp`): **6/6 cells green, 673/673 tests** (`portTests.ms` C 285/285, JS 279/279; `portDiffTests.cms` 67/67; `port/diffTests.ms` C 16/16, JS 16/16; `port/cDiffTests.cms` 10/10). A cell reads `0/0 exit 0` when `/tmp` is full, because the suite's own log cannot be written. What it does not cover: constant-time behaviour and erasure of secrets (taint/dudect, not yet wired), and performance.

## Edit-loop check costs

Measured per-file costs of edit-loop checks, and the checks that do not fit the 60 s budget (`src/test/CLAUDE.md` §Edit loop).

- **Native driver parity diagnostic, 2026-11-13:** rtx, tree `ea61317549e4b0f40ef9829ea2fa99c6b8620f54`, admitted quiet window **361 s** (queue wait excluded). This batch builds the candidate and four `src/bench/iter/bench.ms` binaries (zig/bundle × release/danger), runs each three times with reversed middle-round order on CPU 6, and checks the cc/toolchain owners plus `src/index.ms`. Owner output: **216/216**, **152/152**, check exit 0; all 20 C files match within each driver/mode pair. This is a slow diagnostic, not a repeatable edit-loop recipe: carry it while its source/driver inputs are unchanged, and compare only the affected mode/arms for a narrower change. Measurements and limits: `BUILD-PERF.md` §Recheck after the HCR fix landed; raw `out/postHCRquiet.remote.log`, local probe `.probe/toArrayTrace.sh` (fingerprint `out/postHCR-probe-manifest.txt`).

- **Meta frame throw and VM ownership pins, 2026-11-13:** Linux candidate, 8 declared cores, tree of `wt/fix-meta-frame-throw` (aac8953b2946): `msc test src/test/handoff/metaFrameThrow.ms --tests-in-dir` and `metaVmOwnership.ms` each compile the whole 242-file handoff import graph, about **190 s** per file (`Tests 5413 passed (5413)` / `5415`); `msc test src/compiler/meta/hostPolicy.ms --tests-in-dir` about **13 s**. Measured once by the lane; host load not controlled. Slow checks, not under-60 s edit-loop recipes.

- **`MSC_FLOWS=<file>` splits a test run** into graph, phases A/B/C, cc, link and the run of the test binary. `msc test src/analyzer/inject.ms --tests-in-dir` on lc-1 alone, tree 54af0f26a, ms:

  | run | graph | A | B | C | cc | link | test run | total |
  |---|---|---|---|---|---|---|---|---|
  | default, warm | 9538 | 18564 | 3610 | 1178 | 31 | 922 | 3056 | 36900 |
  | `--release`, warm | 9228 | 17044 | 3548 | 1085 | 22 | 123 | 379 | 31431 |
  | default, cold | 9887 | 18340 | 4119 | 1663 | 28219 | 926 | 7121 | 70276 |
  | `--release`, cold | 9828 | 20222 | 5421 | 3569 | 80089 | 145 | 847 | 120121 |

  The front end (graph and phase A) is three quarters of a warm check. `--release` saves 5.5 s warm and costs 52 s of clang cold, so test builds stay at the default.
- **`msc test <file> --tests-in-dir` per owner, lc-1 alone, tree 3f19df9e0, seconds cold / warm:** `src/test/lang/accessorContexts.ms` 4.9 / 2.4, `src/codegen/c/types.ms` 53 / 25, `src/checker/checkPass.ms` 87 / 47, `src/test/js/accessCheck.ms` 81 / 55, `src/codegen/raiser/eval.ms` 98 / 62, `src/compiler/compile.ms` 138 / 79. One corpus program with `MSCORPUS_RAISER=1` took 9.8 / 4.1.
- **Cold over-budget observation, 2026-10-26:** `msc test src/test/c/spawnCaptureCursor.ms --tests-in-dir` took 66.96 s cold on gc-sd (Linux, 16 vCPU), then 47.74 s warm. Cold source: `bb03b63af` plus the tests in `25412d9e2` (8 passed / 2 expected new assertion failures); warm candidate tree `1d6aacfba9f72f4e09f606630ff21b9d858baabd` passed 10/10. The test body took 6.63 s cold; most of the cost preceded execution.
- **Cold over-budget observation, 2026-10-26:** `msc test src/test/c/referenceTransfer.ms --tests-in-dir` took 61.53 s cold on gc-sd (Linux, 16 vCPU), then 38.55 s warm. Matched `bb03b63af` builder with the regression tests in `f545e18c3` gave 3 passed / 1 expected new assertion failure; the combined capture/materialization candidate passed 4/4. Logs: `~/metascript/.scratch/pi-capturefollow-01a1795d/remote-evidence/evidence/{old-transfer,new-transfer}.log`.
- **Generic-default checks, 2026-11-01:** after a candidate build on shared RTX, tree `dc1042f79c8d31515f05c064de1932aab375b25b`, `./msc test src/test/handoff/genericDefaultValidation.ms --tests-in-dir` reported `Tests 7 passed (7)` in **180.309 s** (12.335 s test body); `./msc test src/checker/preludePack.ms --tests-in-dir` reported `Tests 801 passed (801)` in **96.596 s** (41.888 s body). These are slow checks, not repeatable edit-loop recipes. On oci-u, tree `7355a2992aa6df7275ae1668459eba4e0c9dd4f5`, the expanded metadata check reported `Tests 13 passed (13)` in **55.24 s** (12.599 s body), and `./msc test src/test/handoff/genericDefaultClone.ms --tests-in-dir` reported `Tests 4 passed (4)` in **5.19 s**. Different hosts and test matrices, with cache warmth/load uncontrolled: this is not an A/B or a general warm-cost guarantee. Use the clone-only pin for clone edits; another pack edit needs a focused under-60 s check rather than repeating the slow owner run.
- **Macro-default retention, 2026-11-01:** on oci-u, candidate source tree `c2b99a18bdfffa5b873ce59c7fb80f87069feadb`, `./msc test src/test/handoff/genericDefaultMacro.ms --tests-in-dir` reported `Tests 7 passed (7)` in **63.649 s** (18.213 s test body). The identical pin on the old adoption implementation reported `6 passed | 1 failed (7)` in **131.982 s** (66.896 s body), reaching the expected missing-header/default assertions for all four declaration kinds. These are slow-check observations with uncontrolled load/cache warmth, not a speed A/B; the aggregate file is not an under-60 s edit-loop recipe. No cheaper selector or Windows/macOS timing was verified.
- **Defining-scope body-read pin, 2026-11-01:** on oci-u, restored source tree `831484abdce1d032a5e82ad0518add8cc6746ac9`, `./msc test src/test/handoff/genericDefaultMacro.ms --tests-in-dir` took **71 s** and reported `Tests 1 passed (1)` (1 ms body) with the input temporarily restricted to its imports and first, defining-scope recorder test. Tested prefix SHA256: `1b4d3328cb32d3b53847d1bbcb95cdd3508fa1b3fef93bc8363a99d57cb82194`; the full file was restored afterward. This is an isolated slow-check observation, not a full macro-aggregate result or an under-60 s recipe. No cheaper native compilation or other-platform timing was verified.
- **Committed type-replay consumers, 2026-11-01:** on oci-u, source tree `15dcaf423fc03eb50a6850232e33833901f40b16`, `./msc test --time <file> --tests-in-dir` reported `Tests 19 passed (19)` for `src/test/c/cFunctionPointer.ms` in **86.988 s**, `Tests 11 passed (11)` for `src/test/handoff/aggregateRelation.ms` in **63.540 s**, and `Tests 13 passed (13)` for `src/test/handoff/genericDefaultValidation.ms` in **63.990 s**. Each was run once after the candidate build; these include compilation and exceed the edit-loop budget. The lexical endpoint/diagnostic pins in `src/parser/typeAnnotation.ms` and `src/parser/statements/declaration.ms` passed 98/98 and 269/269 in 5.704 s and 13.587 s respectively; use those owners for that contract, retaining the native consumers when their boundary changes. Load/cache warmth were uncontrolled; no speed A/B or other-platform timing was verified.
- **Checked declaration projection, 2026-11-01:** `./msc test src/test/js/declarations.ms --tests-in-dir` took **103 s wall** on oci-u; stdout reported **35 passed (35)** and **35258 ms** in the test binary. Measured compiler/test bodies are now in `20117e62a66`; the actual pre-commit source snapshot was 5,454 files, aggregate SHA256 `28719531e2e423842c07e04a39c8ffeab16d9f093544ed76abf2bffba5e7bd16` (`/tmp/declarationIntegratedEvidence10ab/local.final.json`), not a claim that the later commit itself was executed. The raw log says `INTEGRATED native rc=0 wall=103s`. This is a slow native check, not a sub-60 s edit-loop recipe; select the changed contract rather than rerunning all 35 for a package-fixture-only change. No cold/warm or cross-host speed comparison was measured.
- **Completion-context native consumer, 2026-11-04:** on oci-u (Linux, actual affinity/nproc 8), `MSC_NO_GLOBAL_CACHE=1 MSC_CACHE_DIR=<fresh-private-dir> ./msc test src/test/handoff/editorRecovery.ms --tests-in-dir --verbose --time` took **73 s wall**, printed `compiled in 71603.ms`, then `running tests`, and reported **3 passed (3)** in **1 ms**. Candidate SHA256 `330f428669bcd8fe85c9c9f3a741a4f4a5711bf395bcfa06a84e1e007583acc7`; measured source was committed tree `caeb024464899796cb648063bbd46fbb95567b2f` plus uncommitted completion/context pins (5,979-file src/std/runtime manifest `5dcba33c867edc174175831ec767515b006e1c6e04ba8e590755c76d0b9b888d`). This is a slow native check, not a sub-60 s recipe or a speed A/B. No other-platform timing or cheaper native compilation was verified.
- **Dispatch-family check, 2026-11-05:** on shared RTX with 8 declared cores, source tree `1861fce0379dd32ac548e5882b7c1ebeed352631`, `./msc test src/compiler/transam/dispatch.ms --tests-in-dir` took **61 s wall** and reported `Tests 280 passed (280)` across 15 files (18,666 ms test-binary duration). This aggregate is a slow check, not a repeatable edit-loop recipe. With the same candidate, `MSC=<candidate> IC_ONLY=<case> ./msc run src/test/ic/run.ms` passed `overrideInImporter`, `overrideThroughGrandchild` and `bodyIfaceNoop` individually in **29, 33 and 26 s**; use the named warm/cold consumer for the changed contract. Load and cache warmth were uncontrolled; no speed A/B or other-platform timing was measured.
- **Lazy dispatch readers, 2026-11-05:** native Windows d87, 8 declared cores, source tree `30c19aba0a3053299c4dc73aad6f55435193e805`: `./msc test src/test/handoff/icDispatchReads.ms --tests-in-dir` reported `Tests 5 passed (5)` in **81 s wall** (18,325 ms test-binary duration). The same candidate passed the three named IC cases in the preceding row in **95, 88 and 72 s** respectively. These are slow checks on d87, not under-60 s edit-loop recipes. Its self-host g1 → g2 → g3 check compared **482 byte-identical C files** from g2/g3. Load and cache warmth were uncontrolled; the earlier RTX timings use another tree and are not a host-speed A/B. No cheaper Windows native check was verified.
- **Dispatch ownership checks, 2026-11-05:** on m1m with 8 declared cores, a checkout-local builder produced the candidate with `--danger --lto=off`; each remote job used a fresh `MSC_CACHE_DIR` and `MSC_NO_GLOBAL_CACHE=1`. Measured source: tree `cd3e0c1f49de123d4d6e6c684f7463546b608e3e` plus uncommitted ownership edits; src/std/runtime manifest SHA256 `ca14f7d9142712a3dffbe86b8ce5a0fdc93f757c59e56bf9cf10d03ebc8e77c1` (sorted tracked/unignored file paths, each followed by NUL and its raw SHA256 digest). `./msc test <module> --tests-in-dir` reported: `src/test/handoff/icDispatchReads.ms` **8 passed (8), 110 s wall**, 19.121 s runner; `src/compiler/transam/index.ms` **281 passed (281), 123 s wall**, 26.779 s runner; `src/test/handoff/raiserProjectImage.ms` **19 passed (19), 68 s wall**, 16.738 s runner; `src/codegen/raiser/eval.ms` **458 passed (458), 80 s wall**, 40.046 s runner. Selecting `transam/dispatch.ms` repeated the same 15-file, 281-test directory in 64 s: do not run both selectors on unchanged source. These are slow checks, not under-60 s recipes; no cheaper native recipe, Linux/Windows result, warm/cold output comparison or speed A/B was verified in these runs.
- **Prelude dispatch owner pin, 2026-11-05:** on m1m with 8 declared cores and the same isolated-cache recipe as above, `./msc test src/test/handoff/icDispatchReads.ms --tests-in-dir` reported **8 passed | 1 failed (9)** before the prelude-view owner fix, naming the owner-identity assertion, in **111 s wall** (19.244 s runner). A rebuilt candidate with the fix reported **9 passed (9)** in **111 s wall** (19.206 s runner). Its `./msc test src/compiler/transam/adoptParity.ms --tests-in-dir` reported **287 passed (287)** across 16 files in **76 s wall** (27.362 s runner). Green source: the preceding committed tree plus ownership edits, src/std/runtime manifest `1fa188b76cb7a10953b2ec40146cecf05f67d235ffc27938494e8810dc540015`, using the preceding manifest recipe. These are slow checks; the red/green establishes the pin, not a speed comparison or Linux/Windows parity. No cheaper native check was verified.
- **Pack-enabled dispatch ownership, 2026-11-05:** Linux RTX, 8 declared cores; candidate built with global cache disabled, tests with a fresh local cache and an enabled private global store. Source manifest `c911b8a71bbaa4334fc8fe8e7511827542fc50277d83f1b1a3fdcf6c06b0f0e3` by the preceding src/std/runtime recipe, on the same committed tree plus ownership edits. `./msc test src/test/handoff/preludePackParity.ms --tests-in-dir` reported **2 passed (2), 58 s wall**, 13.558 s runner. `./msc test src/test/handoff/icDispatchReads.ms --tests-in-dir` reported **9 passed (9), 65 s wall**, 14.980 s runner. The latter is a slow check, not an under-60 s edit-loop recipe. This exercises the pack-enabled ownership boundary; it is not a cold/warm speed comparison, full pack audit, or proof of JS incremental output parity. No cheaper native ownership recipe was verified.
- **Copied prelude-body owner and real consumers, 2026-11-06:** shared Linux RTX, 4 declared cores, checkout-local builder, fresh local cache; candidate build disabled the global store and tests enabled a private global store. Committed tree `cd3e0c1f49de123d4d6e6c684f7463546b608e3e` plus ownership edits. Before the body-selector fix, src/std/runtime manifest `80b1de2ca40c764feddc166b5b71b7b21c11bc87b990d82e92052d5bd6dae106`, `./msc test src/test/handoff/icDispatchReads.ms --tests-in-dir` reported **9 passed | 1 failed (10)** at the copied-owner assertion in **71 s wall**, 13.665 s runner. After the fix and an additional source-prelude fallback control, manifest `9882405291f395dab520bd350c104e68744963c67d8475b90e112a6d67a1cdd7`, the same command reported **11 passed (11), 92 s wall**. `./msc test src/test/handoff/preludePackParity.ms --tests-in-dir` passed **2/2 in 50 s**; `./msc test src/compiler/transam/adoptParity.ms --tests-in-dir` passed **287/287 in 65 s**. Ownership and adoption are slow checks, not sub-60 s recipes. With the same candidate, `MSC=<candidate> IC_ONLY=<case> ./msc run --target=raiser src/test/ic/run.ms` passed `overrideInImporter`, `overrideThroughGrandchild`, and `bodyIfaceNoop` in **33/35/30 s**, each with **0 expected red, 0 failed**. These compare warm/cold emitted C; the last case also asserts that a private body edit checks only its edited module and a no-op checks/lowers none. The selected corpus `overrideDispatchThroughBase`, lanes `c,js,raiser`, passed **4/4 in 8 s**, including identical output. No JS incremental parity, full-suite result, cheaper native owner recipe, or speed A/B was established. Builder for this run: `0f0dadecf35`.
- **Current-source self-host, 2026-11-06:** shared Linux RTX, 4 declared cores, the preceding `9882405…` source manifest; checkout-local builder `ad50eb00424`, fresh local cache and global store disabled. Three `build src/index.ms --danger --lto=off` generations succeeded in **170/110/38 s** respectively. Generation 2 and 3 link response files were byte-identical. Separate `--emit=c` runs by those two compilers listed **482 files each**, whose contents matched byte-for-byte without normalization; only paths actually listed by each emit log entered the comparison. This is a self-host/output fixed-point check, not an incremental speed measurement or a land-gate verdict. The builder changed between the consumer and self-host runs; their wall times are not an A/B.
- **Wasm boundary verification, 2026-11-05:** on m1m, source tree `f6b1c221ec1f182946426b6188950cb5aba6697e`, `./msc-simd-candidate test <file> --tests-in-dir` reported `65 passed (65)` for `src/compiler/wasmBoundary/jsSideTest.ms` in **117.74 s** and `19 passed (19)` for `src/compiler/lsp/handlers/boundaryTest.ms` in **108.03 s**. `MSC=$PWD/msc-simd-candidate ./msc-simd-candidate run src/test/wasmmix/run.ms` reported `wasmmix: 74/74 pass` in **381.89 s**. These are slow checks, not sub-60 s edit-loop recipes: select the changed boundary consumer through `WASMMIX_ONLY=<names>` instead of repeating the sweep. Load/cache warmth were uncontrolled; no cross-host cost guarantee. Raw logs: m1m `~/work/rr-recompiler-441c019f/out/simd-proof/`.
- **Array-growth retention pins, 2026-11-05:** on m1m, `./msc-r9-fixed test src/compiler/wasmBoundary/wasmSideTest.ms --tests-in-dir` reported `Tests 30 passed (30)` in **106.35 s**, source tree `84d3c1eef183d6e7a24a9d8734607e920c77e4e6`. The control reported `28 passed | 2 failed (30)` in **51.77 s**, failing the new scalar-only and Vec retention pins. The targeted wasmmix set `scalars,copies,callback,callbackThrow,spanCopyPaths,handleView` reported `wasmmix: 6/6 pass` in **41.62 s**. Cache warmth/load were uncontrolled; do not treat the owner module's 106.35 s as an under-60 s loop or the 51.77→106.35 s as a code-speed regression. Raw artifacts: m1m `~/work/rr-recompiler-441c019f/out/r9-fixed/` and `out/r9-pin/`.
- **Float32 heap-view owner control, 2026-11-05:** RTX/Linux, tested tracked tree `7294bed1dcc81d34a55352a02ffe7db645e09be4`, native candidate SHA256 `89b7c13fbdb393702589926c43bb94c1de813a16e79421eb12189a7124bce5bd`: `./msc.exe test src/compiler/wasmBoundary/wasmSideTest.ms --tests-in-dir` reported `Tests 31 passed | 3 failed (34)` in **83.76 s**; the test-file summary reported **11762 ms**. The three expected missing-HEAPF32 assertion names were verified by reparsing the saved log, excluding its separate file-summary row, without rerunning the check. This is a slow owner check, not an under-60 s recipe or a green implementation certificate. JS owner was not reached; no cheaper selector measured yet. Cache/load uncontrolled, not a speed A/B. Raw RTX log: `~/work/rr-recompiler-441c019f/out/r3-owner-red/wasmSideTest.ms.log`, SHA256 `e3bf4b6b53a640e766bf187a9d8a5ab78a0803d9e805ee19d59fcebbd6d45874`.
- **Float32 heap-view native acceptance, 2026-11-05:** d87/Windows AMD64, source-only snapshot `679e4e28d95f52d451ba210b8c16e9b346016eb6`, candidate SHA256 `ea63b04da02ed73617da9f67a154b278c860f7396efe5ea0e7cdc936a41d918b`: `./msc.exe test src/compiler/wasmBoundary/wasmSideTest.ms --tests-in-dir` reported `Tests 36 passed (36)` in **175.98 s**, including the imported two glue pins; fresh bootstrap took **130.72 s**. Slow acceptance, not a repeatable edit-loop recipe. Raw log SHA256 `a3d5825bef1ca68d8c071aebbab5f696869db83807019e9df529c012eaec2b62`, remote `~/work/rr-recompiler-441c019f/out/r3-native-portable/owner.log`. The standalone `jsGlue.ms` contract was already checked on RTX/Linux in **1.43 s** (2/2), after its old-implementation control failed exactly the new copy-in pin in **4.03 s** (1/2). The attempted JS-target metadata owner stopped before tests on native-only `std/compress/zip`; it is not a cheap substitute for this native owner. Load/cache uncontrolled; no cross-host speed comparison or generated-wasm consumer/performance/browser/GPU certificate.
- **Result-import wrappers, 2026-11-05:** m1m, checked tree `1fafa1c260a74e86fbd2fc9763fe8bf0473a15a3`, `msc test src/compiler/wasmBoundary/wasmSideTest.ms --tests-in-dir` reported `30 passed (30)` in **50.86 s** (old emitter: 26 passes / four expected shape failures, 55.90 s). Six separately selected `WASMMIX_ONLY=<name>` checks passed: `copies` **8.40 s**, `exportsDecode` **6.59 s**, `nullableCopies` **6.53 s**, `strings` **6.36 s**, `callbackThrowPoison` **6.25 s**, `resultThrowPoison` **4.07 s**. The last is the small host-result-conversion/poison check for both Vec and long string; disabling the generated enclosing guards failed both oracles. Cache/load uncontrolled; no suite/browser certificate. Raw m1m logs: `~/work/rr-recompiler-441c019f/out/r8-green/`.
- **Child option forwarding, 2026-11-05:** m1m, checked tree `c3411bdcc7b62a8cdb97b4d3b9b696057d1710c4`, `msc test src/compiler/wasmBoundary/placementBuild.ms --tests-in-dir` reported `7 passed (7)` in **17.97 s**, versus five expected failures on the uncorrected helper. `MSC=<candidate> WASMMIX_ONLY=childOptions,scalars <candidate> run src/test/wasmmix/run.ms` reported `wasmmix: 2/2 pass` in **13.73 s**. Actual CLI define-override and valid/invalid emcc-linker-option controls also passed; no GPU/browser certificate. Raw logs: m1m `~/work/rr-recompiler-441c019f/out/m5-flags-green/`.
- **LTO option and mode-aware trap checks, 2026-11-05:** on m1m, checked source tree `0a473950c980c4226b6c817df62fc72cb8eb0cd4`, owner checks reported `2 passed (2)` for `placementBuild.ms` in **17.97 s** and `168 passed (168)` for `cc.ms` plus its imported owners in **14.83 s**. The 14-program Danger consumer batches took **110.02 s** with thin and **102.94 s** with full LTO, each `wasmmix: 14/14 pass`; they are slow batches, not an under-60 s loop. Select the changed codec/ownership contract instead. `WASMMIX_ONLY=trapPoison` at its default mode reported `wasmmix: 1/1 pass` in **5.37 s**; it is the small real-engine poison check, independent of bounds-check mode. The older bounds-dependent `callbackThrowPoison` oracle passed at Debug with both strategies (9.10/7.60 s), and must not be applied unchanged to Danger. Cache/load uncontrolled; no general build-speed guarantee. Raw logs: m1m `~/work/rr-recompiler-441c019f/out/lto-fixed/`, `out/lto-remaining/`, `out/lto-final/`.
- **Packed source entry semantics, 2026-11-05:** on rtx, `./candidate test src/test/handoff/raiserSourceEntries.ms --tests-in-dir --danger` reported `Tests 3 passed (3)` in **63.495 s wall** (1.191 s test body). Candidate SHA256 `6f0d25ee3acb258e362de4348bcc1a1fcfe336695b6a3586e4bd8acf2dad864c`; source was tree `dcb55a901936fd77c5a813b73943cfea75dbedbb` plus the frozen 17-file integration manifest SHA256 `383a10c4d4069b4389b2c8faa154f41636e95c74ca0809b6963d22bac8be8fcc`. Run once; this is a slow check, not a repeatable edit-loop recipe. Carry this result while its scope is unchanged; an entry-boundary edit needs a focused pin rather than another aggregate run. Load/cache warmth were uncontrolled; no speed A/B, cheaper selector or other-platform timing was verified.
- **Dispatch ownership on the rebased tip, 2026-11-06:** shared Linux RTX, host `msc` `25b184cf867` as builder, run with the untracked consumer/self-host scripts (fresh `out/<name>.XXXXXX` for cache, global store and TMPDIR); declared cores were not recorded, and RTX `/tmp` had just recovered from a quota-full state. Source: the slice rebased onto main `7228a864969`, before the three test-helper fixes that landed with it in `59382d0c534`. `icDispatchReads.ms` **11/11, 295 s wall** (24.2 s runner); `preludePackParity.ms` **2/2, 127 s**; `adoptParity.ms` **287/287, 154 s**. IC warm/cold C `overrideInImporter`, `overrideThroughGrandchild`, `bodyIfaceNoop` passed, **0 expected red, 0 failed**, in **60/95/66 s**; corpus `overrideDispatchThroughBase` c/js/raiser **4/4 in 15 s**, outputs identical. Self-host g1/g2/g3 built in **487/149/135 s**; g2/g3 link inputs identical and **485 emitted C files byte-identical**. The ready check on `307cc504023` (patch `7de68616d9a`) passed every selected module, with `icDispatchReads.ms` 31.1 s, `preludePackParity.ms` 28.0 s, `adoptParity.ms` 24.1 s and `preludePack.ms` 40.6 s runner duration. The longer walls than the preceding rows come from a loaded host after a queue wait, not from the slice; this is not a speed A/B.
- **Native-adapter gate-tooling batch, 2026-11-01:** one-core oci-u job, baseline tree `b8b6a0ccc30df13915226fc8037e9eaabe0ac4f0` plus the gate/wrapper integration subsequently committed in `8cfc29946c5`, took **62 s overall** for the old-routing negative control, wrapper units, `bash tools/gate.sh --self-test` and isolated routing dry run. Actual outputs: wrapper **7 passed / 0 failed**, `gate: self-test ok`, terminal rc0. This is a batch cost, not an isolated self-test time or native-adapter acceptance. The later printed provisioning-guidance correction added `--ignore-scripts`; its seven wrapper units passed separately, without repeating the slow batch. Treat the batch as a slow check; use the wrapper units for changes confined to that contract. Receipts: `/tmp/nativeAdapterGateReview/validation-row-{22,26,32,40}.log`.
- **RSA key-generation consumer, 2026-11-05:** stock `run-remote.sh --cores 2` selected m1m. The tree-bound copied compiler SHA256 was `402c53e84ff11ec29516962e6083a2daad56c2ed6d06d3afebff496ad27e3d81`. `out/hostbin/compiler test --target=c --tests-in-dir src/test/crypto/rsaKeyGeneration.ms` took **74.075 s wall** and reported `Tests 1 passed (1)`, `Duration 57464ms`; its one test exercised 2048/3072/4096-bit generation plus exported-key interoperability. The JS cell took **7.275 s wall**, also `1 passed (1)`. Tested source was tree `b843cf7c22800cb347f3219ced1396ebce96b873` plus uncommitted producer `std/crypto/pure/rsaNative.ms` SHA256 `bd12cc6130b7a8763b746a8353312904b7ae28b69707865343414864db49ce1a` and consumer SHA256 `7a33ad93aae67f4a513b5f9ac8b82987d555c74623c68e9db63a449fb4d6b1a5`. This is a slow C check, run once, not a repeatable under-60 s recipe or performance A/B; prime selection, load and cache warmth were uncontrolled. A changed generation contract needs a narrower size-specific check before another edit-loop run. No cheaper selector or other-host cost was verified.
- **PBKDF2 SHA-1 long-vector consumer:** `run-remote.sh --host m1m --cores 2` with tree-bound compiler SHA256 `28920ba600772f35059d729fd32339494c3d83dcca70241623d3c48786ec4252` ran `out/hostbin/compiler.exe test --target=c --tests-in-dir src/test/crypto/pbkdf2LongVector.ms` once: **92.999 s wall**, `Tests 1 passed (1)`, `Duration 88750ms`. The JS cell reported `1 passed (1)` in **31.078 s wall**, `Duration 30463ms`. Source was tree `7f6441c28bdf6f8caffd2b5b764f7a4cf7022336` plus consumer SHA256 `7a59b5592e41ed8511983704167d67d325de419ed20a270b4921a252d85b79b1` and bounded-consumer SHA256 `1e9f01526b789ace02747d159851a12fd4d602ba3fffe2703a4a8b2d78136f6d`. Keep the long vector separate from the tier index and repeated edit loop, as with the RSA generation check above; the 297-case bounded PBKDF2 oracle lives in `src/test/crypto/kdfApiVectors.ms`. Its RTX cells reported `Tests 10 passed (10)` / `Tests 9 passed (9)` with **8867ms / 23692ms** bodies, using compiler SHA256 `d4a8b3ea15b060cb3ab1fdb90776e94432bead63fb5a556ef7ce6d1f1cec0152`. These are check-cost observations, not a performance A/B; load/cache warmth were uncontrolled and other-host long-vector cost was not verified.
- **Emit-only RSA consumer and generated-C ownership review:** `src/test/crypto/fixtures/rsaOaepScratch.ms`, SHA256 `1979859067231b93e9f7f65807e9f8069ac7af9c84b28b357bfc32f3fa8a0886`, committed as `f7da06b9801` in tree `f70064b43309543fd9df2dfd89b841b96f857905`, contains one fixed-key import, one OAEP decrypt and an expected-plaintext guard/output. It does not import the test owner or load oracle JSON. Stock `run-remote.sh --cores 2` selected m1m with copied compiler `da9a9cc8…` and unchanged branch support trees. `build <fixture> --target=c --danger --lto=off --emit=c` emitted **45 C modules in 2.367 s**; the declared subject binary was absent, and no subject/test was executed. The paired check reported `OK no type errors in 507 module(s)` in **7.812 s**. Local `out/rsaScratchEmitAudit/14a9eff2-0751-4f93-af0c-4bb1765efa33/results.json` SHA256 `80ecbdb1b49165f3cc3c1859626d995711485bfa4724a7d57fc773d99150ce4f`, `emitted.json` SHA256 `645daacb5361f2359b4c6cdacc8b9249442c52bb0aecad260cacf8cc9a743c41`, and post-emission `review.json` SHA256 `135ec3abcf1d9f63bf2ff8de4703056b303780c9ea55d4774caf23b9ed188184` retain two identical pre-execution manifests/26 selected bindings each, input/log hashes and 45 content-addressed C blobs. Review of FF blob `39ec2b45…`, secret blob `6272626f…`, entry `7ff25538…` and dispatcher `7a3486e1…` confirms a separate uint32 result allocation, then calls on original `x_p1`/`t_p2`; `wideWipe` derives span data/length from the original payload, without a buffer copy, and `wipeWords64` emits `memset` followed by volatile memory-clobber asm. The ordinary dispatcher initializes the narrow fixture, not a test runner. **Limit:** generated `msErr` edges from `fromWide` can jump past the normal-path wipes; error cleanup was not injected or proved. C emission, even with `--danger`, is not optimized-machine inspection, whole-key erasure or CT assurance; there was no native subject build/run, fresh oracle replay, timing comparison or broader acceptance. Load/cache warmth were uncontrolled.
- **Post-emission RSA cleanup review — source/C only:** review snapshot tree `1cf5bd43b5c75405d9ca08e87b117c94877ac098`, using the archived C above; no new emission, subject/test execution or oracle replay. In the same local audit directory, `normal-scratch-source-trace.json` SHA256 `5869fbf96e642a31a91cd33d41d6db045c244f10107702d330d17830b1b254d4` records three source fingerprints, two indexed C blobs and two pinned reference files; `import-source-trace.json` SHA256 `35e1f3a8fb10e8f8873938aef1d9b0a9a2e84e77899b393f79b5c1fd89d8fa04` records seven sources, six C blobs and the same reference pins. Remaining cleanup targets are `ff.ms` (`uintMulAdd`, `wideMul`), `rsaArith.ms` (`rsaPrivateOperation`, `rsaKeyConsistent`) and `rsa.ms` (`privateFromSequence`); these records inventory normal/rejection exits and owned temporaries, not observed RAM contents or demonstrated leakage. Reference `76920edddcad00ac41b248e12d937b845df7bedb`, `drivers/builtin/src/rsa.c` `mbedtls_rsa_private:1527–1568`, checks before unblinding and releases owned MPI workspace; `mbedtls_rsa_parse_key:79–225` frees its temporary and failed context, with `mbedtls_rsa_free:2783` and `bignum.c` `mbedtls_mpi_free:191` clearing owned limbs. The parser route uses nonzero INTEGERs, completion and the public check, **not** the full private-key checker; this review changes no acceptance policy. Parent source trace `error-source-trace.json` (`c3fb2f22…`) found no recoverable `msErr` producer in the examined valid ordinary `fromWide` path: its generated error edge alone is not a confirmed cleanup bug, and fatal/custom-trap behavior was not tested. These post-emission source fingerprints do not retroactively bind missing pre-execution inputs or qualify all-exit/optimized erasure, CT, DCE or performance.
- **Private-import guard and native-config provenance — source argument only:** review snapshot tree `9bc86d3f89ef499fb2954b1a29628deb3e88ef05`; no new emission, subject/test execution or historical-run recertification. In the audit directory above, `entry-guard-source-trace.json` SHA256 `0bcd4c77b960d5620dd9163a442a85a9fe94483c4068245991660649aec26c02` links the cache-width argument to `rsaPrivateFromPkcs1`/`rsaPrivateFromPkcs8` in `std/crypto/pure/rsa.ms` and strict `derItem` in `asn1.ms`, not the relaxed EC parser. Its derived width precondition is confined to that entry route; it is not a global helper, fatal-error or PEM-decoding resource guarantee, nor a runtime result. `native-dispatch-source-trace.json` SHA256 `2713ebc7b93ce275500b70b01041e374f9b99a83b23810713ae0000060559fb4` records three Git-matched source inputs and eleven reference files at `76920edddcad00ac41b248e12d937b845df7bedb`: follow `drivers/builtin/src/pk_rsa.c` `mbedtls_pk_rsa_set_key`, `core/psa_crypto.c` `psa_import_key_into_slot`, and `drivers/builtin/src/psa_crypto_rsa.c` `mbedtls_psa_rsa_load_representation`. The later PK-to-PSA private-key copy must not be mistaken for the first import. Configuration declarations are anchored in `std/crypto/rsa/index.cms` and `runtime/crypto/mbedtls/mbedtlsConfig.h`. The local generated dispatcher is separately archived as blob `1a60d40629a399880d05bee0848c20272826c81e9b89840dda6ab93964efbf44`: it is not Git-pinned or pre-execution evidence. A conditional builtin reference size gate does not establish the compiled native ceiling or API parity without actual SDK/CC/config/driver provenance. These records neither fix the owned-cache scratch findings nor qualify wipe effects, optimized erasure, CT, DCE or performance.
- **Partial-import effect-pin proposal — not implemented or executed:** `partial-import-pin-plan.json`, SHA256 `1cdd6894244e8b9aaf8137bd96439680ed8062502cd4c84c7e4f9c8fe3040fe2`, binds the review above and existing `rsaPrivateImportBounds.ms`/`rsaFixtures.ms` fingerprints. It reuses that fixture-construction pattern for late zero DP/QI in both PKCS1 and PKCS8, with accepted-key and unchanged borrowed-DER controls. The candidate is a private caller-retained decoded-values workspace, following the existing FF retained-buffer effect-test idiom, not an RNG/global/allocator callback or a read after free. The load-bearing ownership constraint is that decoded values are independent of DER but shared with a successfully returned key: unconditional success cleanup would erase the accepted key. A future workspace-only baseline must preserve old cleanup so an effect assertion can go behavioral red before the wipe fix; compile/arity errors are not that red. Owner-test fixture visibility, production dependency/DCE impact and the new nested-list C/JS boundary remain **UNVERIFIED**, so this is not an implementation-ready or passing pin. It does not certify post-construction consistency scratch, RNG-failure cleanup or JS BigInt CT. Existing zero-d functional rejection receipts remain separate. No kernel/runtime/public/default change, callback/hook permission, execution or acceptance waiver follows from this proposal.
- **Wide Montgomery conversion scratch, bounded C effect check:** stock `run-remote.sh --cores 2` selected m1m ARM64 with copied compiler SHA256 `da9a9cc8cda6b62dc36a8dfab93465af79635b82ded286256c726c2aec951635` and branch support trees. `test --target=c --tests-in-dir std/crypto/pure/ff.ms` on old source tree `6ae7337a9c259d343ddca0574b8e5f7e8469f5e6` reported **0 passed / 2 failed**, **7.194 s wall / 1 ms body**, naming the nonzero one-word conversion input and multiword workspace. The identical inline tests on tree `9c003d46616089b57010cac71309a796b0b16848`, code commit `26b61377f72`, reported **C2**, **3.896 s / 1 ms**. The observed contract is limited to copied zero/nonzero results, preserved cached constants, and cleared consumed input/workspace in one-/multiword fixtures; it is not whole-key or optimized-erasure proof. Fixed `ff.ms` SHA256 is `2dc01cd9670ad1b69d4cb63a9aac3a6cc924e6d5f1a0b1720f65f929f239b7bf`. Source ownership trace at baseline `1afafca5`: `fromWide` allocates a separate result; `wideReduce` and both `widePow` paths pass owned conversion scratch, unused afterward. Cached `m.wone` is not cleared. Reference `76920edddcad00ac41b248e12d937b845df7bedb`, `drivers/builtin/src/bignum.c`, SHA256 `92bd47909c703d7297790fa50a060ea485851dc5b03c41369ba76bd17c8edbf3`, clears exponentiation workspace at `mbedtls_mpi_exp_mod_optionally_safe` cleanup and owned limbs in `mbedtls_mpi_free`; this is a source mapping, not a timing verdict. Local receipts under `out/ffFinishAudit`: `2788c6c1-3c73-4564-b71a-2371542ee2fb/results.json`, SHA256 `46fec96d38782419719f0581c5069ef3bc312bfe588adcf6ff2f815c8a8a8fb3`; `646a8bf1-ff15-4727-a504-2a1c088709d0/results.json`, SHA256 `8e86f2a69f8063325044ac6fc2ad7ef285d33f34c5ce59d40c0ce4e2437bbf53`. Old manifest/9 selected bindings and two fixed manifests/32 selected bindings each, blobs and logs were audited against their source snapshots. No observer API, overlay, optimized-code/CT/DCE measurement or speed qualification was added; load/cache warmth were uncontrolled.
- **Modulus construction scratch, bounded effect check, 2026-11-06:** `wideSetup` now takes and clears its Montgomery workspace, and `modulusFromOwnedUint` clears an owned integer after `modulusFromUint` copies it, on both kept and rejected results; `modulusFromBytes` and C `rsaModulusOf` route through it, while borrowed constructor input and the cached constants stay untouched. Stock `run-remote.sh --cores 2` selected m1m ARM64 with copied compiler SHA256 prefix `530fd274c6f0cb6e` and branch support trees. `test --tests-in-dir std/crypto/pure/ff.ms` on the fixed source (`ff.ms` SHA256 prefix `644beba8b1f15803`, `rsaArith.ms` `c03481e84513f538`) reported **C4** in **9.13 s** and **JS1** in **0.31 s**; with only the two clearing lines removed it reported **C2+2 red** (`wideSetup: workspace not erased`, `modulusFromOwnedUint: kept input not erased`) and **JS0+1 red**. Consumers `src/test/crypto/rsaPrivateImportBounds.ms` and `montgomeryBounds.ms` each reported **C4** in about 8.5 s. This observes the source-level clearing of one multiword fixture, not optimized erasure, CT, DCE or performance; no receipts manifest was archived and load/cache warmth were uncontrolled.
- **Multiply/divide and key-consistency scratch, 2026-11-06:** `uintMulAdd` now runs on a workspace `mulAddWith` clears; `uintMul` clears its widened operand copies, `reduceInto` its widened input and `uintDivRem` its normalized divisor; `rsaKeyConsistent` clears its integer copies, `p - 1`/`q - 1`, products, quotients and remainders in a `finally`, so a thrown division clears them too. Same host and copied compiler as above; source `ff.ms` SHA256 prefix `f27f7593589a2586`, `rsaArith.ms` `c9bb31ef7a9665be`. Reported: `ff.ms` **C5/JS2**, `ffTest.ms` **C12/JS9**, `rsaPrivateImportBounds.ms` **C4/JS4**, `montgomeryBounds.ms` **C4**, each under 4 s wall. With only the `mulAddWith` clear removed, `ff.ms` reported **C4+1/JS1+1 red** (`mulAddWith: workspace not erased`). The other clears are inside allocations no test can observe without a workspace parameter or observer API; they are covered only by source review and the unchanged functional results above, and the JavaScript `rsaKeyConsistent` (`rsaArith.jms`, BigInt) is unchanged. Not optimized erasure, CT, DCE or performance evidence.
- **RSA private-operation scratch, 2026-11-06:** C `rsaPrivateOperation` now clears every owned temporary (integer copies, blinding pair, blinded input and its CRT reductions, blinded exponents, partial results, widened operands, the public check and the unblinded result) in a `finally`, so the early `null` returns and a throw clear them too, and it refuses before unblinding on a failed check, as the reference's `mbedtls_rsa_private` does; `wideMul` clears its Montgomery workspace. Same host and copied compiler as above; source `ff.ms` SHA256 prefix `710f431846fdf57e`, `rsaArith.ms` `5b473d373fe15c53`. Reported on C: `ff.ms` **5**, `ffTest.ms` **12**, `rsaApiVectors.ms` **14 passed (14)** in **16.06 s wall**, `rsaPrivateImportBounds.ms` **4**. No test observes these clears (no workspace parameter or observer API); evidence is source review plus unchanged functional results, and JavaScript (`rsaArith.jms`) is unchanged. Not optimized erasure, CT, DCE or performance evidence.
- **Rejected RSA private-key parse, 2026-11-06:** `privateFromSequence` (`rsa.ms`) now clears the INTEGERs it already copied when a later one is missing or zero, and clears the private half and prime moduli (`rsaWipePrivate`, moved from `rsaNative.ms` to `rsaKey.ms` so both share it) when the size, prime-floor or consistency check rejects the key, as the reference's `mbedtls_rsa_parse_key` frees its failed context. Same host and copied compiler as above; source `rsa.ms` SHA256 prefix `5adc186b36d24c13`, `rsaKey.ms` `c6e69889ab871022`, `rsaNative.ms` `3ea7eef6d55741a6`. Reported: `rsaPrivateImportBounds.ms` **C4/JS4**, `rsaApiVectors.ms` **C14/JS12** (C 11.28 s wall). The rejected key is never returned, so no test observes these clears; the moved helper keeps its existing destruction test in `rsaApiVectors.ms`. Not optimized erasure, CT, DCE or performance evidence.
- **RSA key-generation scratch and Miller-Rabin base width, 2026-11-06:** key generation now clears rejected prime candidates and their random bytes, each small-factor division copy, every Miller-Rabin temporary and the candidate's modulus (`wipeModulus`, now in `ff.ms`), the inversion and private-exponent quotients/remainders, the `|p - q|` difference and the `p - 1`/`q - 1` divisions; `uintGcd` clears its operand copies and unused inverse. A real bug surfaced on the way: `millerRabin` drew `ceil(bits / 8)` random bytes into a `ceil(bits / 31)`-limb integer, which cannot hold them when the byte rounding exceeds the limb slack (a 92-bit candidate: 96 bits into 93), so it threw `a Miller-Rabin base does not fit its modulus` on most draws; the public 2048/3072/4096 sizes never hit it, but an internal prime size such as 527 bits (`rsaGenerateKey(1054)`) would. The draw now masks the top byte to the modulus width as `randomBelow` does. On m1m with copied compiler SHA256 prefix `ed4f50fb0e68de5f`, `rsaArith.ms` SHA256 prefix `158db1d61d39bc1b`: `test --target=c --tests-in-dir std/crypto/pure/rsaArith.ms` reported **11 passed** three times (its two new tests: Miller-Rabin keeps 2^127 - 1 and refuses (2^61 - 1)(2^31 - 1); a generated 1024-bit key is consistent and its private operation inverts the public one); with only the mask line removed it reported **10 + 1 red** twice (`Miller-Rabin keeps a large prime and refuses a product of two`, uncaught exception). Consumers on the same run: `ff.ms` C5/JS2, `ffTest.ms` C12/JS9, `rsaApiVectors.ms` C14/JS12, `rsaPrivateImportBounds.ms` C4. The clears themselves are unobserved (internal allocations); the slow 2048-4096-bit generation consumer `src/test/crypto/rsaKeyGeneration.ms` (74 s) was not rerun. Not optimized erasure, CT, DCE or performance evidence.
- **DER export, MGF1 and OAEP scratch, 2026-11-06:** `derUnsignedInteger` and `derSequence` (`asn1.ms`) clear their intermediate bodies, so `rsaPrivateToPkcs1`/`rsaPrivateToPkcs8` leave only the returned DER (they also clear their per-INTEGER parts, inner PKCS#1 and OCTET STRING); `mgf1` clears each hashed input and block; OAEP encryption clears the seed, data block, both masks and the encoded message, and OAEP decryption now also clears both masks. PKCS#1 v1.5 and PSS signing buffers stay as they were, since the signature reveals them. Same host and copied compiler as above; source `asn1.ms` SHA256 prefix `362dfbde8af1f218`, `rsa.ms` `ec40fc8a62ac223f`. Reported: `rsaApiVectors.ms` **C14/JS12**, `rsaPrivateImportBounds.ms` **C4/JS4**, `ecApiVectors.ms` **C12/JS10** (C 11.47 s), `std/crypto/tls/x509NativeTest.ms` **C27**, `tls13NativeTest.ms` **C14**. No test observes these clears. Known limit: a `push`-grown array leaves its earlier backing stores in freed memory, which no wipe reaches; OAEP decryption reads its block at the secret padding length (`block[at]`, `slice(at + 1)`) exactly as the reference does (`tf-psa-crypto` `76920edddcad`, `drivers/builtin/src/rsa.c:1976`, `p += pad_len`; only padding validity leaks, as PKCS#1 v2.2 allows), so it is no divergence; `mem_move_to_left` belongs to the PKCS#1 v1.5 decryption path, which this module does not offer. Not optimized erasure, CT, DCE or performance evidence.
- **EC owned scratch, 2026-11-06:** `weierstrass.ms` now clears the scalar copy of a SEC1 key whose embedded point is refused, the `d` OCTET STRING of SEC1 export and the inner SEC1 and OCTET STRING of PKCS#8 export, every RFC 6979 HMAC input (they hold `d`) and each replaced K and V (`rekey`/`restep`), the y coordinate of the ECDH shared point, and each rejected random draw in `ecDrawScalar`; `ecNative.ms` clears the decoded PEM DER on import, the scalar of a key whose point is null or does not match, and the SEC1 DER on export, as `rsaNative.ms` does and as the reference frees its `mbedtls_mpi` temporaries (`ecdsa.c` cleanup paths). On rtx with copied compiler SHA256 prefix `781ad173aacd21ef` (msc 25b184cf867), source `weierstrass.ms` SHA256 prefix `84e4043f1117f604`, `ecNative.ms` `82777f85933ac3d3`: `src/test/crypto/ecApiVectors.ms` **C12/JS10** (C 25.3 s wall), `std/crypto/pure/ecNativeTest.ms` **C24/JS24**, which keeps the RFC 6979 A.2.5/A.2.6 deterministic signatures through the restructured nonce loop. No test observes these clears. Known limit: `Limbs` and `Point` (`montgomery.ms`, `pcurve.ms`) are fixed-size value types, so the secret scalar, nonce limbs, `r·d`, the ECDH point and the precomputed table live in stack copies that no wipe reaches (the Zig reference does not clear them either); a failed random fill leaves its partial buffer to the held RNG-failure decision. Not optimized erasure, CT, DCE or performance evidence.
- **Ed25519 nonce hash and string copies of keys, 2026-11-06:** `ed25519Sign` now clears the 64-byte hash its nonce is reduced from, and `ed25519SignWithSecretKey` its seed copy (the scalar and prefix were already cleared; X25519, HMAC, PBKDF2 and HKDF already cleared their own scratch). A wider gap: `bytesOf` turns a `string` argument into a fresh UTF-8 buffer that nothing cleared, so a string password, HMAC key or seed stayed in freed memory. The new `wipeIfCopied` (`bytes.ms`) clears that copy and only that copy, and is called for the PBKDF2 password and HKDF ikm (`kdfNative.ms`), the Argon2 password on hash, raw hash and verify, the HMAC key (`hmacSync` on JS and the SHA-3/RIPEMD path, `Hmac.create`), the BLAKE2b key, and the ChaCha, AES, Ed25519 and X25519 key imports, error returns included; a caller's `Buffer` is never touched. On m1m with copied compiler SHA256 prefix `ed4f50fb0e68de5f`: the new `bytes.ms` pin (a caller's buffer keeps its bytes, a string's copy reads all zero) **C1/JS1**, and **C 0 passed / 1 failed** with the `typeof` guard removed; consumers C/JS `ed25519ApiVectors.ms` 11/8, `x25519ApiVectors.ms` 10/7, `ed25519NativeTest.ms` 24/26, `kdfNativeTest.ms` 40/40, `coreNativeTest.ms` 55/59, `aesNativeTest.ms` 32/32, `chachaNativeTest.ms` 16/16, `blake2bNativeTest.ms` 21/21, `argon2NativeTest.ms` 16/16, each C file under 12 s. Source SHA256 prefixes: `bytes.ms` `4191b34dec8f88c5`, `ed25519.ms` `65046eb8d53a95cc`, `kdfNative.ms` `5967741197b286ac`, `coreNative.ms` `15ed744d5b6d3b20`. Not cleared: plaintext passed as a string to an AEAD seal (a message, not key material), and the JavaScript string itself, which is immutable. Not optimized erasure, CT, DCE or performance evidence.
- **AEAD scratch, 2026-11-06:** reviewed AES-GCM, AES-CBC, ChaCha20-Poly1305 and XChaCha20-Poly1305 for owned temporaries. ChaCha (`wipeWork`: subkey, keystream block, one-time key, tag; Poly1305 and GHASH states wipe on finish) and GCM (authentication key, batch, computed tag) already cleared theirs. One gap fixed: a successful `cbcDecrypt` (`aes.ms`) returned a copy without the padding and left the full plain-text buffer behind; it now clears that buffer. On m1m with copied compiler SHA256 prefix `ed4f50fb0e68de5f`, `aes.ms` SHA256 prefix `d6df46c26cf63d23`: `aesNativeTest.ms` **C32/JS32** (its NIST SP 800-38A CBC vectors included), `src/test/crypto/aesApiVectors.ms` **C9/JS7**. No test observes the clear. Not optimized erasure, CT, DCE or performance evidence.
- **Hash finalization states, 2026-11-07:** reviewed SHA-3, RIPEMD-160 and BLAKE2b for state left after finish. SHA-3 (lanes and buffer) and BLAKE2b (block and chaining words on C; block, message, work vector and chaining words on JS; C's work vector lives in locals) already cleared theirs. One gap fixed at its root: `finishRipemd160` cleared its block but not the chaining state `h`, which the reference's `digest()` → `destroy()` zeroes (`@noble/hashes` 1.8.0 `src/legacy.ts:281`, `this.set(0, 0, 0, 0, 0)`); only `coreNative.ms` patched it from outside (`finishRipemdAndWipe`), so `ripemd160Of` and direct callers left it. The clear now lives in `finishRipemd160` and the wrapper is gone. On m1m with copied compiler SHA256 prefix `96b210a3fa54f341`, `ripemd160.ms` SHA256 prefix `c5f8c36c00c7a68e`: `ripemd160.ms` **C16/JS16** (its finish test now checks block and `h` after 6-, 200- and 0-byte inputs), and **C15+1/JS15+1 red** with only the new clear removed; consumers `coreNativeTest.ms` **C55/JS59**, `coreNative.ms` **C42/JS46**. Not optimized erasure, CT, DCE or performance evidence.
- **TLS key-schedule scratch, 2026-11-07:** reviewed `std/crypto/tls/keySchedule.ms`, `record.ms` and `aead.ms`. Secrets held by `KeySchedule` clear in its `onDestroy`, record keys and AEAD key schedules on replacement, HKDF salts, the Finished key and TLS 1.2 PRF blocks after use, and `hmacOf` leaves nothing because `finishHash` clears each state. One gap fixed: `hkdfExpand` left its `HmacState`, whose keyed states hold the compression midstate of the secret XOR the pads, as `hkdfOf` (`hmac.ms`) already avoids with `wipeHmac`; it now calls `wipeHmac` too. On m1m with copied compiler SHA256 prefix `96b210a3fa54f341`, `keySchedule.ms` SHA256 prefix `eb5c66fcd93ad098`: `tls13NativeTest.ms` **C14/JS14**, `tls12NativeTest.ms` **C9/JS9**. No test observes the clear (an internal allocation). Known limit: the TLS 1.2 PRF output and its `[...a]` input copy are push-grown, so earlier backing stores stay in freed memory. Not optimized erasure, CT, DCE or performance evidence.
- **Constant-time taint, first run, 2026-11-07:** `tools/crypto/ctTaint.sh out/ct` on oci-u (Ubuntu 24.04, glibc 2.39-0ubuntu8.9, loader build id `0d77dbd4379bf0b5af3e05be7fb6af1e4cea7c96`, kernel 7.0.0-1013-oracle, clang 18.1.3), valgrind 3.22.0 and libc6-dbg 2.39-0ubuntu8.9 from `tools/crypto/pins.tsv`, the host's copied compiler (msc bea318fe9b9, SHA256 prefix `0a2ab27956fc14e2`), tree 3705efb979b (`taintRun.ms` SHA256 prefix `6b0721da54f6370d`, `ctTaint.sh` `cd7cf50193e1a6b8`). Reported **14/28 cases as expected**: all three controls behaved (leakyBranch and leakyIndex caught at `taintRun.ms:156`/`:172`, noop status 14), and x25519, AES-GCM seal, AES-CBC encrypt, XChaCha seal, SHA-256, SHA-512, HMAC, HKDF, PBKDF2, keyed BLAKE2b and argon2i reported 0 memcheck errors. 14 cases reported findings; distinct first frames per case: Ed25519 public/sign `slide` (`ed25519.ms:284`, a branch on bit 7 of the scalar), `mulBase` identity check and `toBytes` sign bit; P-256/P-384 public, sign and ECDH the scalar range and zero checks (`montgomery.ms:218`, `weierstrass.ms:230`), result identity checks (`pcurve.ms:179`, `:484`) and the signature zero check; RSA PKCS#1 sign and OAEP decrypt 29,750 and 29,842 errors over `wideReduceOnce`, `widePow`, `powInternal`, `uintBitLenPublic`/`clz32`, `uintToBytes` and the blinding overflow check, plus the OAEP padding-length slice; AES-GCM and XChaCha open the tag verdict; AES-CBC decrypt the padding verdict and the length cut; argon2id the data-dependent index (`indexAlpha`), as RFC 9106 designs it. The harness also branches on tainted output (`sameBytes`, `taintRun.ms:173`). Line numbers come from a `--danger` build and can name an inlined caller. Not yet classified with the person: which findings are verdicts that become public by design and get declassified in the harness, and which are fixes. Log: `~/metascript/.wt/std-crypto-ms.d/ctTaint-2026-11-07-oci-u.log`.
- **Constant-time taint, findings closed, 2026-11-07:** same host, pins and copied compiler (SHA256 prefix `0a2ab27956fc14e2`) as the first run; tree b0091feec04 plus the RSA commit after it (`ff.ms` SHA256 prefix `4e4333a0c917063a`, `rsaArith.ms` `09966b67e0569326`, `secret.cms` `74897a8570d742ce`). `ctTaint.sh out/ct` reported **28/28 cases as expected**: the three controls behave, argon2id still reports its data-dependent index (`indexAlpha`, now an expected finding, since a clean argon2id would mean the taint stopped short), and every other case reports 0 memcheck errors. What closed the 14 findings: (1) verdicts the caller reveals anyway (AEAD tag match, CBC padding and plaintext length, EC scalar range and zero checks, identity results, the RSA overflow and fault checks, a zero exponent) now pass through `declassify` (`secret.cms`, C side `msDeclassify` in `runtime/crypto/ctValidation.h`), which only a build with `-DMS_CT_VALIDATION` turns into a memcheck request, the BoringSSL `CONSTTIME_DECLASSIFY` shape; (2) Ed25519 `toBytes` sets the sign bit by XOR instead of a branch, as the reference does (Zig 16d31ceed5 `edwards25519.zig:58`), and OAEP reads its 0x01 marker by a masked scan instead of a secret index; (3) RSA's real leak: clang turned the 0/all-ones masks of the Montgomery final subtraction (`wideReduceOnce`) and the window-table select (`widePow`) into `je`/`jns` jumps, found by mapping memcheck addresses through `addr2line -i` and `objdump`; both masks now pass through `valueBarrier64`, the `mbedtls_ct_compiler_opaque` shape (tf-psa-crypto 76920eddd `constant_time_impl.h:85`), and the blinded exponent is encoded at its full limb width instead of its minimal length, so its bit length no longer sets the loop count. Functional check after the change: `src/test/crypto/suite.sh` on rtx (msc bea318fe9b9, copied compiler `8125260497811e54`) **3/3 cells, 611/611 tests**. Not covered: the taint run sees one build (clang 18, `--danger`, x86_64); ARM, other compilers and optimisation levels, and timing itself (dudect) are not observed. RSA speed after the barriers, A/B on rtx in one call (old = b0091feec04 sources, both `--danger`, two interleaved runs each, host loaded so ratios are against the vendor in the same run): pure/vendor time for sign 2048 0.52/0.54 old vs 0.52/0.55 new, sign 3072 0.52/0.52 vs 0.50/0.53, OAEP decrypt 2048 0.60/0.56 vs 0.60/0.54, 3072 0.50/0.54 vs 0.52/0.54, so no change beyond noise; ARM not re-measured.
- **dudect timing, first run, 2026-11-07:** `tools/crypto/ctDudect.sh out/dd` (commit d8e7da48df4: `src/test/crypto/ct/dudectRun.ms` over the pinned upstream statistics, oreparaz/dudect `dc269651fb25`, header SHA256 checked by the runner) times each case on one fixed secret against a fresh random one, class drawn per measurement, 2000 measurements x 20 batches (about 38k per case after the warm-up batch), one random seed per host. x86-64, rtx (AMD Ryzen 9 9950X, Linux 7.0, clang 21.1.8, governor powersave, load 8-25, unpinned), seed `0xa1edee1c41f8f1d5`: **22/22 as expected**, the 14 algorithm cases plus the portable path of AES-GCM, AES-CBC, XChaCha20-Poly1305, SHA-256 and HMAC-SHA-256 (`MS_CRYPTO_PORTABLE=1`) at max |t| 0.90-2.29, the `leakyBranch` control caught at t=+55.9, both `--null` runs (both classes random) clean. AArch64, m1m (Apple M1 Pro, Apple clang 21.0.0, load 15-17), seed `0x49d3b22788440c62`: **17/17 as expected**, max |t| 0.80-3.21 (hmacSha256 highest), control at t=+108.4. Upstream calls leakage above |t| 10. Cases: x25519, ed25519Sign (secret seed), p256/p384 sign and ECDH (secret scalar), rsaSignPkcs1 (fixed 2048-bit key, secret message: the key's own exponent is not varied), aesGcmSeal, aesCbcEncrypt, xchachaSeal and blake2bKeyed (secret key), sha256 (secret message), hmacSha256 (secret key), argon2i (secret password). Not covered: argon2id (data-dependent by design, as the taint run records), the JS backend, decrypt/open paths, RSA key variation, any run past 40k measurements per case; the AArch64 timer is `cntvct_el0` (its frequency is printed in each case log, not recorded here), far coarser than the TSC, so a small difference there stays below what it can see; both hosts were loaded, which raises the noise floor. Passing is "no leakage evidence within this bound", not a proof.
- **Size matrix of the native crypto switch, 2026-11-07:** `--release` on rtx (Linux x86_64), `size` text/data of `src/test/crypto/fixtures/cryptoEmpty.ms` and `tlsConnectOnly.ms -d:cryptoImport=pure` against the vendored build (`std/core/fetch/tls.cms` pointed at the oracle's `tls`, now `src/test/crypto/oracle/tls`, `-d:cryptoImport=native`), each candidate built from the tree in the same call. Empty program text: native port 252 372 at the switch (8764b528a46), 234 614 after the start-up consts became literals, 87 086 after one out-of-line release call per site (c5fe3b07aa3) and the static const payloads picked from wt/windows-salvage, 41 082 after nested const arrays bake (bcdae530289); vendor 34 232. TLS-only text+data: 1 174 KB + 11 KB at the switch, 584 531 + 162 204 B after cdd91476ec1/a4ae8104ba4 (integer radix kernel, ASCII host-name compare); vendor 529 639 + 1 900. What stays in the TLS binary by `nm` symbol groups: P-256/P-384 window tables 111 029 B (kept in the binary, the person's choice over a table built on first use), Ed25519 base table 34 656 B, runtime symbols only the native build reaches about 50 KB, crypto code about 300 KB against mbedTLS 250 100 B. The remaining empty-program gap is module init: the `Curve` objects of `p256.ms`/`p384.ms` (an object with an array field is not baked), the OID array of `x509.ms`, and `std/process` init reached through `tls/rootStore.ms`. Exit cleanup emitted per `return` is the reference's shape (Nim `blockLeaveActions` copies the finally per exit, `injectdestructors` destroys every scope local), so it was not changed. After f5f3679eba2 (rtx, same recipe): the empty program is 34 232 text + 1 060 data, the vendor build's exact size; before it, 41 415 + 113 904, because the exit teardown of `pcurve.ms` named the P-256/P-384 tables (a read-only baked const now has no exit destroy), `p256`/`p384` and the x509 extension list were built by init code (a module const now folds the const names in its literal and bakes struct fields and a read-only object's array fields), and `tls/rootStore.ms` imported `std/process` and with it its init. TLS-only: 583 638 + 125 252; it connects to www.google.com, cloudflare.com and github.com, and `src/test/crypto/ecApiVectors.ms` passes 469/469. Not measured: macOS/Windows sizes (the Windows root-store path reading the executable path is not run), JS bundle size, speed after these changes.
- **Consumer validator failure and scope error in that run:** `test --target=c --tests-in-dir src/test/crypto/rsaApiVectors.ms` exited 0 with **14 passed (14)** in **11.748 s wall / 7707 ms body**, but the driver then exited **1**, expecting the initial adapter's 11 tests. Archived/current source declares 14; aggregate stdout does not provide per-name execution traces. Post-execution `646a8bf1-ff15-4727-a504-2a1c088709d0/manual-audit.json`, SHA256 `b90f4e85389ee0ce9034e6742507690a760def2371be992573c04978146b0c88`, records that distinction without changing the original driver or receipt. The three added source tests are existing OAEP37, PSS352 and PKCS1-776 oracle checks: invoking the whole owner therefore contradicted the announced narrow/no-oracle plan. Their JSON inputs were not among the 32 pre-execution bindings; do not turn this aggregate into fresh dataset provenance or reconstruct such provenance after execution. No repair rerun was made. Inventory any future consumer before using it; this whole-owner invocation is not a narrow recipe to repeat. No fresh legacy-JS comparison, valid-key generation, valgrind/dudect, performance result, held-policy change or broader acceptance follows from these cells.
- **RSA private INTEGER import boundary:** stock `run-remote.sh --cores 2` selected m1m (macOS ARM64), using copied compiler SHA256 `da9a9cc8cda6b62dc36a8dfab93465af79635b82ded286256c726c2aec951635` with branch support trees. `test --target=<c|js> --tests-in-dir src/test/crypto/rsaPrivateImportBounds.ms` on original source tree `01ab8781c48a5bc8fd82ba9ab66927f3fe93ce0e` reported **2 passed / 2 failed per backend**, in **4.531/0.631 s wall**, bodies **51/24 ms**. Both failures named `accepted zero private exponent`; fixture-component and valid-key controls passed, and the native-C API refused both malformed PEM formats. The identical pin SHA256 `55a319e373028c90fd016545d047851cd91fec2f2b323b169e45310e78e46024` on source tree `500e81ac0bea2d5208ac94b1e891edb9d230b49f`, committed as `4cc9c10e280`, reported **C4/JS4** in **4.061/0.626 s**, bodies **40/23 ms**. The paired source check reported `OK no type errors in 507 module(s)` in **7.695 s**, with **462 ANSI-normalized warnings**, log SHA256 `347d393a9e39c44b38be8f7c37e5477d5ccf05788f1b60e9b4fdda5f5a484fa0`. Two old and three fixed pre-execution manifests, 29 selected bindings each, input blobs and log hashes were independently audited. Local receipts: `out/rsaImportAudit/408935de-1b12-4786-9e71-dd18c3b55951/results.json`, SHA256 `e9f9e73a22785e162b35b4538b891e161ecf608b341668886c0128c7b33ad650`; `out/rsaImportAudit/3b59005d-1c11-44a1-b0b0-9bbc0d5b33e6/results.json`, SHA256 `631359076cb48e3b4d10e8b1cd249a89456663873acd5dc9829671ff862c51bd`. Remote originals are under the same UUIDs in `out/rsaImportPins`. Initial attempt `f17b28d5` stopped at typecheck because a fixture local inferred as `Buffer` could not receive `uint8[]`; its explicit base-array annotation fixes the test without a cast or checker change. That attempt is not behavioral red. No generation, unchanged RSA oracle, CT/DCE/erasure, performance qualification or fresh legacy-JS comparison was run; load/cache warmth were uncontrolled.
- **RSA parser/reference and source-safety follow-up:** reference pin `76920edddcad00ac41b248e12d937b845df7bedb`, `drivers/builtin/src/rsa.c:79`, `mbedtls_rsa_parse_key`, requires nonzero private INTEGERs, then completes the context and checks its public half. The consumer route starts at `runtime/crypto/rsa/rsa.c`, `implRsaImportPrivatePem`, through the PK/PSA import path. Do not substitute the stronger `mbedtls_rsa_check_privkey` contract for that parser; the bounded change is in `std/crypto/pure/rsa.ms:137`, `privateFromSequence`. Native `rsaArith.ms:157`, `rsaPrivateOperation`, maps blinding, blinded CRT and the public-operation fault check to `mbedtls_rsa_private`; C actually selects `ff.ms:906`, `widePow`, not its narrow fallback. This is source mapping, not a CT verdict. Ownership/wipe targets remain at `rsaArith.ms:114`, `randomBelow`, and `:142`, `blindedExponent` (random-byte and intermediate copies); `rsaPrivateOperation` (cleanup on early return/throw); `ff.ms:729`, `wideFromMont`, and `widePow` (converted/output/workspace copies); and `rsa.ms:137`, `privateFromSequence`, with `rsaArith.ms:75`, `rsaKeyConsistent` (partial/rejected-key copies). The private table's entry zero comes from cached `m.wone`; establish alias/ownership effects before treating the entire table as disposable scratch. `rsaNative.ms:20`, `privateOfPem`, clearing the decoded DER does not prove erasure of those copies. JS `rsaArith.jms:64`, `privateOperation`, keeps its explicitly non-CT BigInt path; preserving it is not an approved CT exception. These are targets for ownership-aware effect probes, optimized-code inspection and later authorized taint/dudect, not confirmed residues or an erasure certificate. RSA operations, TLS policy and held decisions were not changed.
- **Montgomery reader boundary regression:** stock `run-remote.sh --cores 2` selected m1m (macOS ARM64); copied compiler SHA256 `da9a9cc8cda6b62dc36a8dfab93465af79635b82ded286256c726c2aec951635`, paired with the branch support trees. Executed source reconstructs tree `422316081fd1d9927da86938473beed0f34ea759`, committed as `6940988efc0`. `test --target=<c|js> --tests-in-dir src/test/crypto/montgomeryBounds.ms` reported **C4/JS4**, in **8.360/0.572 s wall**, bodies **1/12 ms**. The affected class consumer, `src/test/crypto/ecApiVectors.ms`, reported **C12/JS10** in **6.561/1.343 s**, bodies **2640/876 ms**. The same copied binary's `check src/index.ms` reported `OK no type errors in 507 module(s)` in **7.869 s**, with **462 warnings**, log SHA256 `347d393a9e39c44b38be8f7c37e5477d5ccf05788f1b60e9b4fdda5f5a484fa0`. Five pre-execution manifests, 25 selected bindings each, archived input blobs and log hashes were independently checked against local bytes. Remote artifacts: `out/montgomeryBoundsFixedPins/6949b054-0054-44f0-bf6e-3f64f5bfa893`; local `out/montgomeryBoundsAudit/6949b054-0054-44f0-bf6e-3f64f5bfa893/results.json`, SHA256 `be8a6ed2e6678bea2baaf46b97758546b52e95934209725c1b95dc9fa9b8fe16`. These are bounded functional observations, not a full oracle rerun, CT/erasure/DCE assurance, a performance comparison or another-platform result; load/cache warmth were uncontrolled.
- **Reader control and setup limitations:** the identical regression test SHA256 `0c2beff4961b9514d9ebd347a833f603bf54b631243c14fbcc82eb64441b9afe` on the original reader reconstructed tree `b8c447844eede4accdacbdd8f98ffd1bee603aaf`. JS exited 1 after **5.002 s** with `Error: index -1 out of bounds (length 32)`, before any `Tests` verdict. This is a **runtime-abort control, not three assertion failures or a completed four-test matrix**; the driver's expected 1-pass/3-fail assertion rejected that output. Its 23 selected bindings, blobs and log were audited in `out/montgomeryBoundsAudit/01b31427-9489-4166-8241-8e8593b019a4/results.json`, SHA256 `e022b6c73082cc21b4816902289a8aa4f4b0188de52e2f615805442acba34783`. No unsafe old-C case was run. The earlier setup attempt `9aa05c8b` stopped before manifest/log creation because the driver selected nonexistent `pcurveBaseTable.ms`; the actual `.cms`/`.jms` paths were checked before the execution above. Its Base64 recovery also failed. Corrected transport serializes remote stderr and preserves the raw payload; neither setup failure is behavioral evidence. Completed cells were not rerun to recover evidence.
- **EC source-safety follow-up, not a dynamic verdict:** boundary reference read at Zig `16d31ceed5de91b469e010b4a8d515236ad6bf14`: `lib/std/crypto/pcurves/common.zig`, `Field.fromBytes`; `pcurves/{p256,p384}/scalar.zig`, `CompressedScalar`/`Scalar.fromBytes`. Those fixed-size arguments do not expose the dynamic-span contract of `std/crypto/pure/montgomery.ms`, `fromBytes`/`reduceBytes`. The native secret/public multiplication split maps `pcurve.ms`, `pcSelect`/`mulSecret`/`mulDoubleBasePublic`, to Zig `pcurves/{p256,p384}.zig`, `pcSelect`/`pcMul16(vartime=false)`/`mulDoubleBasePublic`; this source mapping is not emitted-code or timing proof. The existing JS BigInt path in `bigCurve.ms`, `multiplyWith`/`affineOf`, and `bigint.ms`, `modInverse`, remains outside any CT claim; keeping it is not an approved CT exclusion. Wipe follow-ups remain at `weierstrass.ms`, `nonceFor`/`signRaw`/`sharedSecret`/`ecDrawScalar`, and `ecNative.ms`, `privateOfPem`: reassigned nonce-state generations, concatenated seed inputs, secret-derived limb scratch and decoded-key scratch require ownership-aware effect probes and optimized-code inspection. Existing byte wipes and key destruction do not establish those other lifetimes. This records review targets, not confirmed post-free residues or optimizer-proof erasure. No taint/dudect run, wipe change, PEM tail policy or broader safety acceptance was made here.
- **ECDH class-API smoke and rejection checks, 2026-11-06:** stock `run-remote.sh --cores 2` selected m1m; copied compiler SHA256 `da9a9cc8cda6b62dc36a8dfab93465af79635b82ded286256c726c2aec951635`, paired with the worktree support trees. `test --target=<c|js> --tests-in-dir src/test/crypto/ecdhApiSmoke.ms` reported **2/2 per backend**, covering 64 valid agreements, in **11/1 s wall**, bodies **2788/278 ms**; restored cells took **6/1 s**, bodies **2757/272 ms**. Executed test/index bytes reconstruct tree `6d0025f082690c6623203365eb870957622c98d3`. A temporary producer byte flip made both curve tests fail at vector #1 on C and JS. Six log hashes and 13 selected source bindings were checked; `out/ecdhSmokeAudit/recovered-a68e3eed/audit.json` SHA256 `5d7345b333c11adb6f2a992104ef8aa8a09f85ac08b0446745bdc6e2515dd12a` is a **post-execution recovery**, not an execution-time archive. The original driver lacked a restoration trap and per-phase source archives; do not reuse that driver. The restored producer hash was independently checked. This establishes only the bounded smoke, not all 1,659 cases, CT, DCE, performance or another platform.
- **Remaining valid ECDH class oracle:** `src/test/crypto/ecdhValidApiVectors.ms`, `validAgreements`, uses the same m1m compiler/support pairing above. Executed bytes reconstruct tree `9069b153bd064aa232d8f62c25cd12aa15e679e4`. `MS_ECDH_CURVE=p256|p384 MS_ECDH_SHARD=<n>` with `test --target=<c|js> --tests-in-dir <file>` bounded each invocation to 128 cases: P-256 shards 0–2 cover 298 cases and P-384 shards 0–5 cover 739, excluding the 32/curve already covered by the separate smoke. All **1,037 remaining agreements per backend** passed across 18 normal cells; the normal maximum was **12.748 s wall**, their summed wall **90.673 s**. Four producer-byte-corruption cells failed at the first selected vector with `shared mismatch`, four restored cells passed, and four invalid/empty-selector cells refused their configuration. The 30 pre-execution manifests, source blobs and log hashes were verified, including exact gap-free/non-overlapping ordinal ranges and the restored producer. Remote artifacts: `out/ecdhValidApiPins/e54f5e17-514d-475d-b1fc-3cc8aaf96cbe`; recovered local `out/ecdhValidApiAudit/e54f5e17/results.json` SHA256 `9fe95b324cc488e7b390d2a5ae1c884b2fe0dbad1a4907e9de5b2587a443fddf`. The initial revision stopped at typecheck because array `indexOf` returns `number`; the integer-index selector fixes the test without weakening numeric conversion checks. Default full/no-selector invocation was **not separately executed or timed**: the under-60 s observations apply only to explicit shards. Together with the separate smoke receipts this covers all 1,101 valid vectors on C/JS with unchanged recorded producer inputs, not the 460 acceptable vectors, full vendor parity, another platform, CT/DCE or a performance qualification. The earlier raw-owner result remains a distinct measurement.
- **Non-tail acceptable ECDH class observations:** `test --target=<c|js> --tests-in-dir src/test/crypto/ecdhAcceptableApiVectors.ms` through stock `run-remote.sh --cores 2` selected m1m (macOS ARM64), with copied compiler SHA256 `da9a9cc8cda6b62dc36a8dfab93465af79635b82ded286256c726c2aec951635` and worktree support trees. Executed bytes reconstruct tree `7651055d16ad79354b9465aa6389b050ed39e0bd`. Both backends reported **2/2 passed**: 229 observations per curve, **22 exact shared-secret agreements and 436 `InvalidKey` import refusals per backend**, in **5.601/1.114 s wall**, bodies **1007/193 ms**. A remote-only producer byte flip made both curve tests fail at `#2: shared mismatch` on C/JS; restored cells passed **2/2** in **3.548/0.794 s**, bodies **1002/182 ms**. All six pre-execution manifests, 17 selected bindings each, archived blobs and log hashes were verified; the producer was restored in `finally` to SHA256 `c1aa30fa937cd726c4833a9eb22ddf0b368303af512cc36d3c6f20cb2e9edc03`. Artifacts: remote `out/ecdhAcceptableApiPins/a1d2a20c-5865-402e-92d8-8796a687ebd5`, local `out/ecdhAcceptableApiAudit/a1d2a20c-5865-402e-92d8-8796a687ebd5/results.json` SHA256 `813d83017e5bd032be41dc6fc8d94a092de725697b7d7b7965d5f2a8735f52eb`. The paired compiler's source check reported `OK no type errors in 507 module(s)` with warnings in **7.927 s**, log SHA256 `347d393a9e39c44b38be8f7c37e5477d5ccf05788f1b60e9b4fdda5f5a484fa0`. P-256 #421 and P-384 #856 are explicitly deferred, **not approved exclusions**. This observes current supported/refused outcomes; it does not establish a general acceptable-vector policy or full vendor parity. Separate valid/invalid receipts above are not one combined full-oracle run. Load/cache warmth were uncontrolled; no other platform, CT/DCE or speed qualification was verified.
- **Outside-root boundary, source-only follow-up:** at key-codec commit `76920edddcad00ac41b248e12d937b845df7bedb`, `drivers/builtin/src/pkparse.c`, `mbedtls_pk_parse_subpubkey` bounds the parsed key to its declared sequence; the public-PEM caller returns without checking that the decoded buffer was exhausted. Compare the legacy JS caller `publicOfPem` in `std/crypto/ec/index.jms` with `ecPublicFromSpki` in `std/crypto/pure/weierstrass.ms`. At strict-codec commit `16d31ceed5de91b469e010b4a8d515236ad6bf14`, `lib/std/crypto/codecs/asn1/der.zig`, `decode` expresses whole-input consumption as `std.debug.assert`, not a checked parse error. These source anchors explain the unresolved compatibility boundary; no new legacy-JS execution or tail-case agreement/export measurement was made, and no root-exhaustion policy change is authorized by this trace.
- **ECDH invalid-input class oracle:** `test --target=<c|js> --tests-in-dir src/test/crypto/ecdhInvalidApiVectors.ms`, same host/compiler, tree `885fdb8207afca89b43655c845bd44e2b446a4e8`, reported **2/2 C and JS** for all 98 invalid vectors plus two positive controls in **5.110/1.015 s wall**, bodies **950/241 ms**. Relabeling valid vector #3 as invalid in each corpus produced **0 passed / 2 failed** on both backends with `invalid ECDH accepted` diagnostics; this is a **classification-oracle control**, not a producer bypass. Restored cells passed **2/2** in **3.359/0.793 s**, bodies **945/241 ms**. The six pre-execution manifests, content-addressed input blobs and log hashes were verified in `out/ecdhInvalidApiPins/67c01c94-7f59-4225-abbf-13ebf94683ce` on m1m; recovered local `out/ecdhInvalidApiAudit/67c01c94/results.json` SHA256 is `0339263274f5d4b7f2046b6246f88e0125039487f0fc29233b99add130450d74`. Fixtures were restored in `finally` and their pinned hashes checked. The earlier test revision's helper throw only produced `uncaught exception escaped the test body` on C and was rejected as diagnostic evidence; `RejectionSummary` in the test module carries the case to an assertion instead. These checks do not decide the 460 acceptable vectors or the two outside-root cases; load/cache warmth were uncontrolled and no speed comparison was made.
- **Compiler/support pairing trap observed during these checks:** PATH `msc check src/index.ms` failed with four missing-enum-field errors (`BuiltinKind.pure`, `SymbolFlag.NoSideEffect`) because its installed `std/meta/node.ms` differed from the branch's. The **same binary bytes**, copied under the worktree to use its support trees, reported `OK no type errors in 507 module(s)` in **9.199 s**, log SHA256 `e485cad01148cff0de2bcc9ef04722f389652019acd83ed5987999606cee0dc9`; the repository pre-commit `./msc check` separately reported the same verdict in **10.739 s**. This isolates support-root selection, not a compiler-source regression or permission to ignore a failed check. See `src/utils/path.ms`, `resolveRuntimeDir`; the log digest identifies output, not the execution snapshot.
- **EC public-PEM framing consumer, 2026-11-05:** `src/test/crypto/ecApiVectors.ms`, using `out/hostbin/compiler.exe test <file> --target=<c|js> --tests-in-dir` through stock `run-remote.sh --cores 2`, reported **C12/JS10 passed** in **7.326/1.592 s wall** on m1m. The copied compiler SHA256 was `28920ba600772f35059d729fd32339494c3d83dcca70241623d3c48786ec4252`. Executed tracked-source bytes reconstruct tree `ed85926d5b6a29c758b8e1fcafdea3097d8fe706`, subsequently committed as `357ca55adcc`; the 73 selected input bindings and archived test/logs were verified before the commit in `~/work/rr-recompiler-182168b2/out/ecPemLengthPins/green.manifest.json` (SHA256 `337a11f0babb9745b2a63fcfec9b3f29b43fe0a960878f4512ab8d1999895e0e`). The same test on the old producer reported **C11+1red/JS9+1red**, both `bounded BER public PEM refused 20/20`, bound by `red.manifest.json` SHA256 `49c0ff0cbac72f1a06a926878c1a738838cef4b1d6428ddc522879f4893d9aa7`. The 20 selected encodings exercise definite BER lengths through PEM import and exact class-API ECDH shared secrets; raw DER and signature length/exhaustion controls remain strict. This is not the full 1,659-case ECDH consumer oracle, a speed comparison, CT/DCE assurance or another-platform result. The two legacy-native-accepted inputs with bytes outside the root remain unresolved, not approved exclusions. Reference read: key-codec commit `76920edddcad00ac41b248e12d937b845df7bedb`, `drivers/builtin/src/asn1parse.c:28–58`; strict-codec commit `16d31ceed5de91b469e010b4a8d515236ad6bf14`, `lib/std/crypto/codecs/asn1.zig`, `Element.decode`; [RFC 7468 §13](https://www.rfc-editor.org/rfc/rfc7468#section-13) permits BER for PUBLIC KEY payloads but does not justify bytes outside the root. Load/cache warmth were uncontrolled; the slow owner below was not rerun.
- **EC point-codec/Wycheproof owner:** stock `run-remote.sh --cores 2` selected m1m; copied compiler SHA256 `28920ba600772f35059d729fd32339494c3d83dcca70241623d3c48786ec4252`. `out/hostbin/compiler.exe test --target=c --tests-in-dir std/crypto/pure/pcurveWycheproofTest.ms` took **102.120 s wall**, reporting `Tests 17 passed (17)`, `Duration 92899ms`; the JS cell reported **17 passed (17)** in **5.528 s wall**, `Duration 4979ms`. The oracle rows covered 2,556 ECDSA and 1,659 ECDH cases without skips. Executed tracked-source bytes reconstruct tree `ff18af902c81346256c8e20dfdbb734857000752` from base tree `cb117355ffa9b07ebba4ea51b6bb2eaca3deaf67` plus five then-uncommitted files, before the final width/prefix checks were moved ahead of the point copy; the 16 selected input hashes and archived owner are bound by `out/ecCompressedPins/owner.manifest.json` SHA256 `95c021f4f62ceffcee650500e8768aea179ec7ccd378e833041d9cd6cd28e8d6` in `~/work/rr-recompiler-182168b2` on m1m. This is a slow native check, run once, not an under-60 s edit-loop recipe or performance A/B; load/cache warmth were uncontrolled. The narrower compressed-key consumer `src/test/crypto/ecApiVectors.ms` reported C9/JS7 in **5.925/0.876 s wall** on the same compiler and unchanged codec bytes, after old-producer C7+2red/JS5+2red controls. Use that consumer for its import/export contract; another shared-arithmetic edit needs a narrower oracle check before repeating the slow owner. The pre-guard `weierstrass.ms` is preserved as `out/ecCompressedPins/owner-weierstrass.ms` (SHA256 `f44a1abb5f81f2012b3afe7866fc66c732fe29f2d60518772bfa2132b2309852`). The final guard-ordering snapshot (SHA256 `2e6ed780e92ab6555138af5ee49e2fca127ba7040b61d63e5cb418f189142812`) passed the narrow consumer C9/JS7 in **8.876/0.767 s wall**, bodies **1780/213ms**, bound by `bounded.manifest.json` SHA256 `2598e2469eea33e805be49f50b453cd1f2b190f1ce35d7467d372247f2070b9e`; the other 15 owner inputs were unchanged. The slow owner was not rerun on that guard-only change. No narrower full-oracle selector or other-host cost was verified. SEC1 reference read: Zig `16d31ceed5de91b469e010b4a8d515236ad6bf14`, `lib/std/crypto/pcurves/{p256,p384}.zig`, `fromSec1`/`recoverY`.
- **Dispatch-family check, 2026-11-05:** on shared RTX with 8 declared cores, source tree `1861fce0379dd32ac548e5882b7c1ebeed352631`, `./msc test src/compiler/transam/dispatch.ms --tests-in-dir` took **61 s wall** and reported `Tests 280 passed (280)` across 15 files (18,666 ms test-binary duration). This aggregate is a slow check, not a repeatable edit-loop recipe. With the same candidate, `MSC=<candidate> IC_ONLY=<case> ./msc run src/test/ic/run.ms` passed `overrideInImporter`, `overrideThroughGrandchild` and `bodyIfaceNoop` individually in **29, 33 and 26 s**; use the named warm/cold consumer for the changed contract. Load and cache warmth were uncontrolled; no speed A/B or other-platform timing was measured.
- **Lazy dispatch readers, 2026-11-05:** native Windows d87, 8 declared cores, source tree `30c19aba0a3053299c4dc73aad6f55435193e805`: `./msc test src/test/handoff/icDispatchReads.ms --tests-in-dir` reported `Tests 5 passed (5)` in **81 s wall** (18,325 ms test-binary duration). The same candidate passed the three named IC cases in the preceding row in **95, 88 and 72 s** respectively. These are slow checks on d87, not under-60 s edit-loop recipes. Its self-host g1 → g2 → g3 check compared **482 byte-identical C files** from g2/g3. Load and cache warmth were uncontrolled; the earlier RTX timings use another tree and are not a host-speed A/B. No cheaper Windows native check was verified.
- **Dispatch ownership checks, 2026-11-05:** on m1m with 8 declared cores, a checkout-local builder produced the candidate with `--danger --lto=off`; each remote job used a fresh `MSC_CACHE_DIR` and `MSC_NO_GLOBAL_CACHE=1`. Measured source: tree `cd3e0c1f49de123d4d6e6c684f7463546b608e3e` plus uncommitted ownership edits; src/std/runtime manifest SHA256 `ca14f7d9142712a3dffbe86b8ce5a0fdc93f757c59e56bf9cf10d03ebc8e77c1` (sorted tracked/unignored file paths, each followed by NUL and its raw SHA256 digest). `./msc test <module> --tests-in-dir` reported: `src/test/handoff/icDispatchReads.ms` **8 passed (8), 110 s wall**, 19.121 s runner; `src/compiler/transam/index.ms` **281 passed (281), 123 s wall**, 26.779 s runner; `src/test/handoff/raiserProjectImage.ms` **19 passed (19), 68 s wall**, 16.738 s runner; `src/codegen/raiser/eval.ms` **458 passed (458), 80 s wall**, 40.046 s runner. Selecting `transam/dispatch.ms` repeated the same 15-file, 281-test directory in 64 s: do not run both selectors on unchanged source. These are slow checks, not under-60 s recipes; no cheaper native recipe, Linux/Windows result, warm/cold output comparison or speed A/B was verified in these runs.
- **Prelude dispatch owner pin, 2026-11-05:** on m1m with 8 declared cores and the same isolated-cache recipe as above, `./msc test src/test/handoff/icDispatchReads.ms --tests-in-dir` reported **8 passed | 1 failed (9)** before the prelude-view owner fix, naming the owner-identity assertion, in **111 s wall** (19.244 s runner). A rebuilt candidate with the fix reported **9 passed (9)** in **111 s wall** (19.206 s runner). Its `./msc test src/compiler/transam/adoptParity.ms --tests-in-dir` reported **287 passed (287)** across 16 files in **76 s wall** (27.362 s runner). Green source: the preceding committed tree plus ownership edits, src/std/runtime manifest `1fa188b76cb7a10953b2ec40146cecf05f67d235ffc27938494e8810dc540015`, using the preceding manifest recipe. These are slow checks; the red/green establishes the pin, not a speed comparison or Linux/Windows parity. No cheaper native check was verified.
- **Pack-enabled dispatch ownership, 2026-11-05:** Linux RTX, 8 declared cores; candidate built with global cache disabled, tests with a fresh local cache and an enabled private global store. Source manifest `c911b8a71bbaa4334fc8fe8e7511827542fc50277d83f1b1a3fdcf6c06b0f0e3` by the preceding src/std/runtime recipe, on the same committed tree plus ownership edits. `./msc test src/test/handoff/preludePackParity.ms --tests-in-dir` reported **2 passed (2), 58 s wall**, 13.558 s runner. `./msc test src/test/handoff/icDispatchReads.ms --tests-in-dir` reported **9 passed (9), 65 s wall**, 14.980 s runner. The latter is a slow check, not an under-60 s edit-loop recipe. This exercises the pack-enabled ownership boundary; it is not a cold/warm speed comparison, full pack audit, or proof of JS incremental output parity. No cheaper native ownership recipe was verified.
- **Copied prelude-body owner and real consumers, 2026-11-06:** shared Linux RTX, 4 declared cores, checkout-local builder, fresh local cache; candidate build disabled the global store and tests enabled a private global store. Committed tree `cd3e0c1f49de123d4d6e6c684f7463546b608e3e` plus ownership edits. Before the body-selector fix, src/std/runtime manifest `80b1de2ca40c764feddc166b5b71b7b21c11bc87b990d82e92052d5bd6dae106`, `./msc test src/test/handoff/icDispatchReads.ms --tests-in-dir` reported **9 passed | 1 failed (10)** at the copied-owner assertion in **71 s wall**, 13.665 s runner. After the fix and an additional source-prelude fallback control, manifest `9882405291f395dab520bd350c104e68744963c67d8475b90e112a6d67a1cdd7`, the same command reported **11 passed (11), 92 s wall**. `./msc test src/test/handoff/preludePackParity.ms --tests-in-dir` passed **2/2 in 50 s**; `./msc test src/compiler/transam/adoptParity.ms --tests-in-dir` passed **287/287 in 65 s**. Ownership and adoption are slow checks, not sub-60 s recipes. With the same candidate, `MSC=<candidate> IC_ONLY=<case> ./msc run --target=raiser src/test/ic/run.ms` passed `overrideInImporter`, `overrideThroughGrandchild`, and `bodyIfaceNoop` in **33/35/30 s**, each with **0 expected red, 0 failed**. These compare warm/cold emitted C; the last case also asserts that a private body edit checks only its edited module and a no-op checks/lowers none. The selected corpus `overrideDispatchThroughBase`, lanes `c,js,raiser`, passed **4/4 in 8 s**, including identical output. No JS incremental parity, full-suite result, cheaper native owner recipe, or speed A/B was established. Builder for this run: `0f0dadecf35`.
- **Current-source self-host, 2026-11-06:** shared Linux RTX, 4 declared cores, the preceding `9882405…` source manifest; checkout-local builder `ad50eb00424`, fresh local cache and global store disabled. Three `build src/index.ms --danger --lto=off` generations succeeded in **170/110/38 s** respectively. Generation 2 and 3 link response files were byte-identical. Separate `--emit=c` runs by those two compilers listed **482 files each**, whose contents matched byte-for-byte without normalization; only paths actually listed by each emit log entered the comparison. This is a self-host/output fixed-point check, not an incremental speed measurement or a land-gate verdict. The builder changed between the consumer and self-host runs; their wall times are not an A/B.
- **Wasm boundary verification, 2026-11-05:** on m1m, source tree `f6b1c221ec1f182946426b6188950cb5aba6697e`, `./msc-simd-candidate test <file> --tests-in-dir` reported `65 passed (65)` for `src/compiler/wasmBoundary/jsSideTest.ms` in **117.74 s** and `19 passed (19)` for `src/compiler/lsp/handlers/boundaryTest.ms` in **108.03 s**. `MSC=$PWD/msc-simd-candidate ./msc-simd-candidate run src/test/wasmmix/run.ms` reported `wasmmix: 74/74 pass` in **381.89 s**. These are slow checks, not sub-60 s edit-loop recipes: select the changed boundary consumer through `WASMMIX_ONLY=<names>` instead of repeating the sweep. Load/cache warmth were uncontrolled; no cross-host cost guarantee. Raw logs: m1m `~/work/rr-recompiler-441c019f/out/simd-proof/`.
- **Array-growth retention pins, 2026-11-05:** on m1m, `./msc-r9-fixed test src/compiler/wasmBoundary/wasmSideTest.ms --tests-in-dir` reported `Tests 30 passed (30)` in **106.35 s**, source tree `84d3c1eef183d6e7a24a9d8734607e920c77e4e6`. The control reported `28 passed | 2 failed (30)` in **51.77 s**, failing the new scalar-only and Vec retention pins. The targeted wasmmix set `scalars,copies,callback,callbackThrow,spanCopyPaths,handleView` reported `wasmmix: 6/6 pass` in **41.62 s**. Cache warmth/load were uncontrolled; do not treat the owner module's 106.35 s as an under-60 s loop or the 51.77→106.35 s as a code-speed regression. Raw artifacts: m1m `~/work/rr-recompiler-441c019f/out/r9-fixed/` and `out/r9-pin/`.
- **Float32 heap-view owner control, 2026-11-05:** RTX/Linux, tested tracked tree `7294bed1dcc81d34a55352a02ffe7db645e09be4`, native candidate SHA256 `89b7c13fbdb393702589926c43bb94c1de813a16e79421eb12189a7124bce5bd`: `./msc.exe test src/compiler/wasmBoundary/wasmSideTest.ms --tests-in-dir` reported `Tests 31 passed | 3 failed (34)` in **83.76 s**; the test-file summary reported **11762 ms**. The three expected missing-HEAPF32 assertion names were verified by reparsing the saved log, excluding its separate file-summary row, without rerunning the check. This is a slow owner check, not an under-60 s recipe or a green implementation certificate. JS owner was not reached; no cheaper selector measured yet. Cache/load uncontrolled, not a speed A/B. Raw RTX log: `~/work/rr-recompiler-441c019f/out/r3-owner-red/wasmSideTest.ms.log`, SHA256 `e3bf4b6b53a640e766bf187a9d8a5ab78a0803d9e805ee19d59fcebbd6d45874`.
- **Float32 heap-view native acceptance, 2026-11-05:** d87/Windows AMD64, source-only snapshot `679e4e28d95f52d451ba210b8c16e9b346016eb6`, candidate SHA256 `ea63b04da02ed73617da9f67a154b278c860f7396efe5ea0e7cdc936a41d918b`: `./msc.exe test src/compiler/wasmBoundary/wasmSideTest.ms --tests-in-dir` reported `Tests 36 passed (36)` in **175.98 s**, including the imported two glue pins; fresh bootstrap took **130.72 s**. Slow acceptance, not a repeatable edit-loop recipe. Raw log SHA256 `a3d5825bef1ca68d8c071aebbab5f696869db83807019e9df529c012eaec2b62`, remote `~/work/rr-recompiler-441c019f/out/r3-native-portable/owner.log`. The standalone `jsGlue.ms` contract was already checked on RTX/Linux in **1.43 s** (2/2), after its old-implementation control failed exactly the new copy-in pin in **4.03 s** (1/2). The attempted JS-target metadata owner stopped before tests on native-only `std/compress/zip`; it is not a cheap substitute for this native owner. Load/cache uncontrolled; no cross-host speed comparison or generated-wasm consumer/performance/browser/GPU certificate.
- **Result-import wrappers, 2026-11-05:** m1m, checked tree `1fafa1c260a74e86fbd2fc9763fe8bf0473a15a3`, `msc test src/compiler/wasmBoundary/wasmSideTest.ms --tests-in-dir` reported `30 passed (30)` in **50.86 s** (old emitter: 26 passes / four expected shape failures, 55.90 s). Six separately selected `WASMMIX_ONLY=<name>` checks passed: `copies` **8.40 s**, `exportsDecode` **6.59 s**, `nullableCopies` **6.53 s**, `strings` **6.36 s**, `callbackThrowPoison` **6.25 s**, `resultThrowPoison` **4.07 s**. The last is the small host-result-conversion/poison check for both Vec and long string; disabling the generated enclosing guards failed both oracles. Cache/load uncontrolled; no suite/browser certificate. Raw m1m logs: `~/work/rr-recompiler-441c019f/out/r8-green/`.
- **Child option forwarding, 2026-11-05:** m1m, checked tree `c3411bdcc7b62a8cdb97b4d3b9b696057d1710c4`, `msc test src/compiler/wasmBoundary/placementBuild.ms --tests-in-dir` reported `7 passed (7)` in **17.97 s**, versus five expected failures on the uncorrected helper. `MSC=<candidate> WASMMIX_ONLY=childOptions,scalars <candidate> run src/test/wasmmix/run.ms` reported `wasmmix: 2/2 pass` in **13.73 s**. Actual CLI define-override and valid/invalid emcc-linker-option controls also passed; no GPU/browser certificate. Raw logs: m1m `~/work/rr-recompiler-441c019f/out/m5-flags-green/`.
- **LTO option and mode-aware trap checks, 2026-11-05:** on m1m, checked source tree `0a473950c980c4226b6c817df62fc72cb8eb0cd4`, owner checks reported `2 passed (2)` for `placementBuild.ms` in **17.97 s** and `168 passed (168)` for `cc.ms` plus its imported owners in **14.83 s**. The 14-program Danger consumer batches took **110.02 s** with thin and **102.94 s** with full LTO, each `wasmmix: 14/14 pass`; they are slow batches, not an under-60 s loop. Select the changed codec/ownership contract instead. `WASMMIX_ONLY=trapPoison` at its default mode reported `wasmmix: 1/1 pass` in **5.37 s**; it is the small real-engine poison check, independent of bounds-check mode. The older bounds-dependent `callbackThrowPoison` oracle passed at Debug with both strategies (9.10/7.60 s), and must not be applied unchanged to Danger. Cache/load uncontrolled; no general build-speed guarantee. Raw logs: m1m `~/work/rr-recompiler-441c019f/out/lto-fixed/`, `out/lto-remaining/`, `out/lto-final/`.
- **Packed source entry semantics, 2026-11-05:** on rtx, `./candidate test src/test/handoff/raiserSourceEntries.ms --tests-in-dir --danger` reported `Tests 3 passed (3)` in **63.495 s wall** (1.191 s test body). Candidate SHA256 `6f0d25ee3acb258e362de4348bcc1a1fcfe336695b6a3586e4bd8acf2dad864c`; source was tree `dcb55a901936fd77c5a813b73943cfea75dbedbb` plus the frozen 17-file integration manifest SHA256 `383a10c4d4069b4389b2c8faa154f41636e95c74ca0809b6963d22bac8be8fcc`. Run once; this is a slow check, not a repeatable edit-loop recipe. Carry this result while its scope is unchanged; an entry-boundary edit needs a focused pin rather than another aggregate run. Load/cache warmth were uncontrolled; no speed A/B, cheaper selector or other-platform timing was verified.
- **Dispatch ownership on the rebased tip, 2026-11-06:** shared Linux RTX, host `msc` `25b184cf867` as builder, run with the untracked consumer/self-host scripts (fresh `out/<name>.XXXXXX` for cache, global store and TMPDIR); declared cores were not recorded, and RTX `/tmp` had just recovered from a quota-full state. Source: the slice rebased onto main `7228a864969`, before the three test-helper fixes that landed with it in `59382d0c534`. `icDispatchReads.ms` **11/11, 295 s wall** (24.2 s runner); `preludePackParity.ms` **2/2, 127 s**; `adoptParity.ms` **287/287, 154 s**. IC warm/cold C `overrideInImporter`, `overrideThroughGrandchild`, `bodyIfaceNoop` passed, **0 expected red, 0 failed**, in **60/95/66 s**; corpus `overrideDispatchThroughBase` c/js/raiser **4/4 in 15 s**, outputs identical. Self-host g1/g2/g3 built in **487/149/135 s**; g2/g3 link inputs identical and **485 emitted C files byte-identical**. The ready check on `307cc504023` (patch `7de68616d9a`) passed every selected module, with `icDispatchReads.ms` 31.1 s, `preludePackParity.ms` 28.0 s, `adoptParity.ms` 24.1 s and `preludePack.ms` 40.6 s runner duration. The longer walls than the preceding rows come from a loaded host after a queue wait, not from the slice; this is not a speed A/B.
- **Over budget now, warm:**
  - `src/compiler/compile.ms`: 79 s.
  - `src/codegen/raiser/eval.ms`: 62 s, mostly `numericCondsFailure`.
  - `src/compiler/lsp/handlers/lifecycle.ms`: 76 s warm, 151 s first run after a candidate build (lc-1, 2026-10-27, tree 103e61415).
  - `src/compiler/lsp/server.ms`: 82 s warm, 105 s first run; it runs `lifecycle.ms`'s tests too (same run).
  - A first run of a compiler-module test is over 60 s for every file that imports most of the compiler, because its test build redoes the front end of that graph. Making the front end reachability-driven, as the reference transforms a routine only when codegen first needs it, saves an estimated 3–4 s: the `inject.ms` test build still reaches 72% of the function-body nodes. The remaining lever is reusing each module's front-end output across builds.
- **Reach the land gate found and the edit loop missed, std-crypto-ms, 2026-11-09** (gates q1109111829, q1109132710, q1109161900 on rtx, each `--full`, 69 to 97 min; all three caught and fixed before the land):
  - A change to which module globals `src/analyzer/inject.ms` tears down at exit reaches the Raiser and SAN cells of the corpus programs that declare module consts, not only C: run `MSCORPUS_RAISER=1` and then `MSCORPUS_SAN=1` on the programs a grep finds for a top-level `const x: T[N] = [` or `const x: Readonly<` (24 programs on 2026-11-09; Raiser 132 pass 0 fail 3 xfail, SAN 24 pass on the landed fix). The Raiser builds a const C emits as static data on the heap, so skipping its teardown there left `borrowLocalReadsThroughAddress [raiser]` with two holders at exit.
  - Turning a std const into static data moves the exact `@ledger-slack` of a program that leaves by `process.exit`: `readonlyConstReadByTaskAtProcessExit [san]` went from 2 to 1 heap `msStringArrayRefCell` when `std/process` `WIN_EXE_EXTS` became static.
  - After a rebase across commits that touch the warm session (kept checks, held-beyond notes, the compile-time engine), run `HCR_ONLY=hcrWatchAsync,hcrIcOracle MSC=$PWD/msc ./msc run --target=raiser src/test/hcr/run.ms`: `hcrIcOracle` took **818 s** on a main candidate and **872 s** on the fix, rtx, so it is a slow check run once per such rebase. It caught engine prelude notes landing in the first program module checked (`watch: rebuilding from scratch: the types accepted behind an interface or record by app.ms changed`).

## Emit-diff A/B — by hand, for narrow fixes

Measured 2026-09-05 on the bug130 fix (checker identity-fit for narrowed
union refs): 180 programs × 2 binaries = **334 s**, 2309 emitted C files
hash-compared, **0 diffs** — with the selector's sensitivity PROVEN on the
bug shape first (20-line C diff on the minimal repro). That historical selector used the matching emits to skip its corpus run. Matching C is a
control for emitted C, not a universal proof about diagnostics, JS output, lifetime or every
runtime environment. Do not carry that selector's inference forward as a safety certificate.

**`tools/gate.sh` emits no program to select what the corpus lanes run.** The land gate runs
corpus and SAN on the programs the slice adds or edits and those its owner names with
`gate-queue submit --programs`; `--full`, `--release` and a corpus lane named in `--with` run every
program. The pass-record selector it replaced emitted every program once with the candidate (plain C,
`--danger` C and JS) and skipped those with a recorded pass for that emit. Over the 105 gates to
2026-10-30 that ran it (`~/metascript/.gate-host/logs/*/gate-*.log`) it took 22.5 h, 0.43 s a program,
while running a program took a median 0.73 s in corpus and 0.36 s in SAN; it skipped 14% of corpus
and 28% of SAN programs, at most 11 h, and 62 of the 105 skipped no corpus program, because records stay
on the host that wrote them and a change to the support stamp voids them. It pays only above about a 40%
hit rate across both lanes. The selector it replaced built a control
compiler at the merge base and emitted every program on both sides; its select took a
median of 1231 s over 105 host logs.

Measured 2026-09-19 with that retired control selector (14 cores, load 15–20),
candidate `832301f3` against control `08ac0858`, a range that holds the
`needsTry` analyzer fix:

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

Historical retired-selector behavior, not today's lane-selection algorithm: the gate did
not narrow — it ran the lane whole — under
`--lanes`, `--release` and `--record`. A change no emit can show (`runtime/`,
`vendor/`, a `std/` file that is not a module, the corpus runner, the compiler
files that choose build flags) moves the support stamp instead, so no record
matches and the lane runs whole without a stated reason.

The `solana` lane runs after `san`, offline, with the candidate: `msc test` on
`std/solana/test.cms`, `idlTest.ms`, `accountCodecTest.ms` (C, then `--target=js`),
`examples/escrow/program.ms`, `examples/escrow/idl.cms` and
`examples/anchorBench/helloworld/program.ms`, one command per entry, each red named by its path.
`std/solana`, `runtime/solana` and `tools/solana` changes also bring in the `guard` lane
(every `solana*` guard lives there). It joins when a path under `std/{solana,crypto,meta,serialize/json}`,
`runtime/solana`, `runtime/manual.h`, `tools/solana`, `examples/{escrow,anchorBench}` or
`src/test/c/solana*` changes, or the compiler passes SDK expansion and `--os=solana` go through change:
`src/{checker,codegen/c,monomorphize}/`, `src/compiler/meta/`,
`src/compiler/{buildConfig,cc,compile,defines,options,toolchain}.ms`, `src/module/cparse/target.ms`.
The LiteSVM replays (`accountValues`, `escrow`, `heapExhausted`, with their `--os=solana` builds, node
and `tools/solana/node_modules` required) run under `--release` or when a `tools/solana` path changed.
Measured 2026-10-09, one command at a time, on the lane-c candidate: host tests 21–31 s each, 150 s
for the seven; replays ~30 s for `accountValues` plus `heapExhausted` (the escrow build was red on that
tree and is unmeasured). NOT verified: a gate run of the lane end to end.

Why not just run the corpus: the toolchain stamp content-hashes the msc
binary + `runtime/` + `vendor/` (`src/compiler/cache.ms`), so EVERY new
candidate binary starts cold — a full run never gets cheaper while
iterating.

For a narrow manual A/B, choose the exact real consumers from the changed contract first.
Build/control and candidate checks use remote admission and matched support/input/toolchain
provenance. Emit each selected consumer separately so output paths cannot collide, and keep
its required backend variants distinct. A matching emit answers only the emitted-code question;
run the smallest consumer that observes the behavior, including native lifetime/SAN when owed.

Do not emit every corpus program as an edit-loop selector, invent a control worktree outside
the worktree rules, or use the retired `MSCORPUS_FILTER` recipe. Named corpus selection uses
`MSCORPUS_ONLY` as defined by `src/test/corpus/run.ms`. A new failure shape still needs a
registered regression with an absolute oracle even if an older corpus sample emitted no diff.

Traps, all paid for on 2026-09-05:

- **Prove sensitivity FIRST.** Emit the minimal repro (as a PLAIN program —
  `build` never emits `test {}` bodies, a test-block repro diffs 0 and proves
  nothing) with both binaries and confirm the C actually differs / the
  control actually fails. `assert` is test-block-only; plain repros narrow
  with `if (x.kind === ...)`.
- **Const-foldable repros lie**: one literal-based repro folded to a
  composite temp on the control binary and compiled fine there. Build values
  through a function call so the argument is a real local.
- The historical substring filter could match unintended programs. Use exact named selection
  and the current cell names from the corpus runner, not a copied old environment recipe.
  `MSCORPUS_LANES` retains its historical variable name; its values select backend cells.
- The selector degenerates for broad changes (codegen/runtime/analyzer work
  that rewrites most programs' C): |A| large ⇒ the full run is the honest
  option. |A| is self-calibrating, no guessing up front.
- Missing sanitizer support is environment-blocked, not a program red. Host
  selection and capability checks live in `src/test/corpus/run.ms`
  `sanWindowsClang` / `asanLinkGap`.
- Windows capability measurement (2026-09-30, LLVM 23.1.0 + MinGW 16.1.0,
  x64): `MSC=C:/Users/metacraft/.metascript/bin/msc.exe MSCORPUS_SAN=1
  MSCORPUS_ONLY=820-float32ConstFold MSCORPUS_BUILD_JOBS=1 MSCORPUS_JOBS=1
  <installed-msc> run src/test/corpus/run.ms` returned
  `1 pass · 0 fail · 0 xfail · 0 xpass` in 16.78 s. Subject and support trees
  were installed build `35601908`, not the current integration compiler;
  the harness was `4225315e` plus the stricter capability-probe follow-up.
  Its clean C control printed `asan-control=42`; the planted fault had to
  exit nonzero with `ERROR: AddressSanitizer: stack-use-after-scope`.
  With `ASAN_OPTIONS=detect_leaks=notbool`, the runtime instead reports
  `AddressSanitizer: ERROR: Flag parsing failed` (exit 1): that is not evidence
  of fault detection and must not satisfy the capability check.
  Other toolchain versions/architectures and a full current integration SAN
  run were not verified by this measurement.
- Windows integration followup, 2026-10-06, source tree `2220eaeb47c5`, one recovery
  build and serial focused runs after a machine restart: compiler source check 373
  modules clean; lexer 376/376; CC 741/741 with the gate's `NO_COLOR`/`FORCE_COLOR`
  clearing (`tools/gate.sh` `test_one`). Direct CC testing under `NO_COLOR` made
  eleven unchanged color-length assertions fail; that was not an observed linker
  regression. Absolute-link and compile-time metadata guards print `GUARD-OK` on
  DRC/ORC with balanced ledgers. SBF entry emission assertions execute before the
  existing missing-SDK `GUARD-SKIP`; the real SBF link/account-limit matrix remains
  unverified on this host.
- The same followup's exact corpus subset (`MSCORPUS_ONLY=headerImportSpelledInAString,objectLiteralAssignedInPlace`,
  `MSCORPUS_RAISER=1`, build slots 1) prints `14 pass · 0 fail · 0 xfail · 0 xpass`:
  twelve cells plus two parity comparisons. The in-place assignment oracle is
  unchanged; each Span is now last-read before its owner's assignment, instead of
  carrying a borrowed view across a source write. The danger driver fell back to
  the auto-detected compiler without LTO, so whole-program DCE is not proved.
- Windows guard loader followup, 2026-10-06: the previous default bare-ASan launch
  exited 53 because LLVM's `lib/windows` was outside the DLL search path.
  `src/test/guard/run.ms` now discovers that directory from clang and temporarily
  extends the native process PATH around the synchronous child launch.
  Runner blob `b237e3b4a2b0`, based on tree `2ce918893f31`, was exercised with
  `MSC=$PWD/out/recovery/msc.exe GUARD_SHARD=25/285 out/recovery/msc.exe run --target=raiser src/test/guard/run.ms`:
  `bareArenaReallocCopy [bare]` and `[bare asan]` both pass, `ALL GREEN (2 cells)`.
  A throwaway overlapping-memcpy binary built with `clang -fsanitize=address -O0`
  and launched through the same runner launch block reports
  `ERROR: AddressSanitizer: memcpy-param-overlap`; the launcher checks failure and
  PATH restoration, printing `ASAN-FAULT-DETECTED PATH-RESTORED`.
  An environment block containing both `Path` and `PATH` previously failed to
  resolve the DLL; no machine PATH change or DLL copy is needed.
  This proves the x64 Windows loader and sanitizer sensitivity, not the full
  integration guard/SAN lane or the arm64/i386 runtime filenames.
- Heap corruption inside the compiler itself: build it under ASan with the
  DRC slab off, `msc build src/index.ms --sanitize=address
  --passC=-DMS_SLAB_MAX=0 --output=/tmp/msc-asan`, then compile a real
  program with it. Slab recycling hides use-after-free (`runtime/drc.h`).
  Fixing one layer often exposes the next; re-run until clean. Measured
  2026-11-13 on m1m (msc `1b493b622aca`, bundle `be33328d1c99`): the build
  takes 64 s and links `libclang_rt.asan_osx_dynamic.dylib`, and the result
  builds `tools/managedToolchain/matrix/hello.ms` in 51 s with no report.
  Name no `--cc` for it: `--cc=zig` cannot link the ASan runtime on macOS
  (`undefined symbol: ___asan_handle_no_return`).

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
