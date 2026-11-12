# nim-guard — proactive drift guards for the DRC/lifecycle model

`/trace-nim` is **reactive**: you reach for it after a crash to trace a bug back
to the Nim reference and decide whether we diverged. These guards are the
**proactive** half — probes that go RED the moment a refactor drifts from a
Nim-derived lifecycle invariant, at test time, instead of via a lucky
production crash weeks later.

## How it works

Each `*.ms` here exercises exactly one invariant. `run.sh` builds it with the
**DRC ledger** (`-DMS_DRC_LEDGER`), a test-only runtime instrumentation
(`runtime/drc.c`, off by default → zero cost in normal builds) that:

- routes every last-ref `destroyFn` dispatch through `MS_DESTROY_DISPATCH`
  (`runtime/drc.h`) and **aborts on the 2nd finalize of a live pointer**
  (`DOUBLE-DESTROY of <type>`), and
- counts per-type alloc/destroy and dumps the balance at exit
  (`LEDGER <type> alloc=A destroy=D`).

The double-destroy abort is the primary, name-agnostic signal — it fires the
instant any decref path finalizes an object that still has an owner. This is the
Nim methodology (its ARC suite counts `=destroy`/`=copy`/`=sink` and asserts
exact counts, e.g. `tests/arc/tarcmisc.nim`).

## Running

```bash
msc run --target=raiser src/test/guard/run.ms
MSC=./msc msc run --target=raiser src/test/guard/run.ms    # a specific compiler
```

Pass = clean exit, no `DOUBLE-DESTROY`, all declared balances hold.

## Adding a guard — use `/nim-guard`

1. Pin the invariant + its Nim source + NIM-REF verdict (SAME vs
   DIVERGE-INTENTIONAL). If unsure, run `/trace-nim` first.
2. Write a probe here whose header cites the Nim invariant, the NIM-REF entry ID, and
   a "RED MEANS … run /trace-nim on the named type" line.
3. Structure it so the invariant's violation is observable to the ledger
   (double-destroy for finalize-twice; per-type balance for leaks). Use high
   iteration to make timing windows deterministic.
4. **Prove it goes RED** on a build with the invariant violated (revert the fix
   / inject the divergence) before trusting it. A guard that cannot fail is
   worthless.

Optional header directive:

```
// GUARD-BALANCE <MangledType>   assert alloc==destroy for that type at exit
// GUARD-OS <os> [<flag>…]       one [<os>] lane: build --os=<os> plus the flags, never
//                               run; with GUARD-CHECK-FAIL the build must fail with every tag
// GUARD-ASAN                    with GUARD-OS bare: also build under ASan and run on the
//                               host; GUARD-OK printed and no AddressSanitizer report
<code> // GUARD-REFUSED          with GUARD-CHECK-FAIL, on each refused line: the build must
                                 report an error on that line (`// GUARD-WARNED`: a warning)
```

A CHECK-FAIL probe whose errors sit on two or more lines marks every refused shape, so
one shape that starts compiling turns it red while the others still fail. Mark a shape
from what the probe means to refuse, never from today's output: an intended shape with no
error on its line is a finding, not a mark to move.

`GUARD_SELFTEST=1` runs `selftest/`: each fixture breaks one check on purpose and must go
red with the reason it names, so a check that cannot fail shows up there.

Note: mangled type names are compiler-internal and can shift under transform
refactors — prefer the double-destroy abort (name-agnostic) as the core signal;
use `GUARD-BALANCE` only for leak guards where a stable type is available.

## Guards beyond the lifecycle ledger

Some Nim-derived invariants aren't lifecycle events the ledger can count — e.g.
**type identity**. `run.sh` still hosts them: it treats a **build failure as RED**
(a type-identity violation makes the program uncompilable), and a probe can add
an **uncaught `throw` on a wrong value** for a runtime RED (nonzero exit) if a
drift still compiles. Same `main()` + `run.sh` shape; no ledger directive.

- **`typeKeyFnSignature.ms`** — structural type-dedup keys must not drop a
  function signature (`hashType` tyProc / `sameInstantiation`; NIM-REF CK-52). Two nullable-fn fields of different arity: a
  collapse re-erases the 2nd's arity → checker "expected at most 0" → build RED.
  Proven RED on the pre-fix compiler, GREEN post-fix (drc+orc).
- **`jsBundleKeepsOnlyWhatRuns.ms`** — a `--target=js` bundle holds a top-level function, class, enum
  or effect-free binding only when something that runs names it: a statement that runs on load, a
  bundle export, or a declaration already kept, as the reference's JS backend emits a proc and a
  const on use and every top-level statement always. Builds a hello and a `JSON.parse` program as
  bundles (default and `--danger`), runs each under node and reads the text: hello holds no JSON
  parser and no `Error` class, the JSON program holds the parser and its used class and neither its
  unused class nor the function only that class calls. A host without `node` prints GUARD-SKIP.
  Proven RED on the compiler of `e21c6e7c3666` (rtx: every bundle holds the whole prelude), GREEN
  on the fix (rtx, 2026-11-12).
- **`solanaConstFoldLinks.ms`**, **`solanaWritableBinding.ms`** (`GUARD-OS solana`) —
  scalar module consts fold before the SBF link, which keeps only `.text` and
  `.rodata` (`getConstExpr`); a binding that still needs writable storage is
  FREESTANDING E02 at the binding, in the entry and in an imported module.
  Proven RED on `8be46044`; `solanaWritableBinding` alone RED with only the E02
  report in `compile.ms` removed.
  `solanaStdWritableBinding`, `solanaStdWritableBindingRelease` hold the same for a std module
  (`std/solana/writableBindingFixture.ms`) on debug and `--release`, and `solanaStdHostBindingLinks`
  that a std binding no SBF code reaches stays accepted. Proven RED on `5d59ac66e`, where std was
  exempt: the debug link failed on the discarded `.data`, the release build linked.
  - **Known gap:** the sibling `monoTypeKey` collapse is NOT guarded — its
    function case is *benign* (uniform `msClosure` repr → a collapsed
    `Holder__function` still runs correct), and its only RED case (anon-union
    type-arg → fused `msUnion` payloads) can't yet compile clean because of a
    separate union ctor-param proto/def indirection bug + generic-fn-over-union
    bug. Add that guard once those land (logged in neon `BUGS.md`).
- **`solanaMemBuiltins.ms`** (`GUARD-OS solana`) — under `MSOS_SOLANA` the runtime maps
  `memcpy`/`memset`/`memcmp`/`memmove` to the compiler builtins, so the SBF backend inlines
  small ones and calls the platform's syscall-backed symbols for large ones (NIM-REF RT-22).
  Proven RED on `36251885` (byte loops in `runtime/manual.h`).
- **`solanaComptimeCallFolds.ms`** (`GUARD-OS solana`) — a module const initialized by a call to a
  `@comptime` function, imported and in the entry, with a literal and a const-name argument, is
  evaluated while compiling and links (NIM-REF CT-32). Proven RED on `6162af93` (FREESTANDING E02
  at the module const).
- **`solanaLtoLinks.ms`**, **`solanaLtoFrameOverflowFails.ms`** (`GUARD-OS solana --release`) — a
  `--release` SBF build takes LTO (`docs/BUILD-PERF.md`, 2026-10-05): the merged bitcode is compiled
  to one SBF object before ld.lld, and an overflowing frame in it still fails the build. Proven RED
  with the merge step removed (`is incompatible with` the compiler_builtins objects) and with the
  object compiled without the SBF error check (the overflow links).
- **`solanaNumberArrayLiteral.ms`** (`GUARD-OS solana`) — a `number[]`/`float64[]` literal
  fills its elements one by one, as every other scalar literal does; SBF has no C varargs
  (NIM-REF TR-30). Proven RED on `36251885` (`undefined symbol: msNumberArrayFrom`).
- **`solanaObjectLiteralFrame.ms`** (`GUARD-OS solana`) — an object literal that initializes a
  local or is returned is built in that local or the caller's result slot, nested literals and
  `Result.ok({...})` included (NIM-REF CG-46). Proven RED on `49046b457`: `settle` needs a 5,504-byte
  SBF frame (limit 4,096); 2,624 on the fix.
- **`bareArenaReallocCopy.ms`** (`GUARD-OS bare`, `GUARD-ASAN`) — a freestanding realloc copies
  only the old block's bytes, so a growing array, Map, Set or string never copies out of the block
  it lands in; on SBF that copy stops the program with "Overlapping copy" (NIM-REF RT-31). Proven
  RED on `bead8cc6a` (ASan `memcpy-param-overlap` in the arena's realloc).
- **`helloLinksNoAsyncRuntime.ms`** — a program that starts no async work links none of the async
  runtime (exit drain, event loop, pool, actors, deferred future release), because exit work, a
  thread's exit flush and a future's count drop go through hooks the facility arms on first use, as
  Nim attaches exit procs and thread-destruction handlers. Proven RED on tree `7a70426b98c4`
  (exit drain hooked only; macOS arm64: all six forbidden symbols at `--danger` and `--release`), GREEN
  on tree `63f54c80d1bf` (macOS arm64 and Linux x86-64). Red again from the prepared LLVM 23 bundle
  (2026-11-10, macOS arm64, all six at both modes): LLVM 23 turns a call through a static slot that is
  only ever stored one function into a direct call, so every arming store hides its function with
  `MS_HIDE_FROM_OPTIMIZER` (`runtime/promise/dispatch.h`); hello `__text` at `--danger` 26,220 → 2,856 B.
- **`asyncTimerLinksNoPool.ms`** — a program that awaits timers and spawns nothing links no pool
  worker, because a wake reads the pool that exists and only a spawn or the actor system starts it,
  as Nim wakes a worker it already holds and starts workers only in its pool setup. Builds and runs
  a setTimeout + async/await program at `--danger` and `--release` and reads its symbols. Proven RED
  on tree `939e207b0891` (Linux x86-64, rtx: `msPoolWorkerLoop` at both modes, reached through
  `msPoolWakeWorker` → `msPoolGet`), GREEN with the wake reading `gPool` (rtx, 2026-11-12); that
  program's `__text` at `--danger --lto=off` 54,032 → 47,968 B (macOS arm64).
  The same program with its awaits at the top level is held to the same symbols: a blocking wait
  reaches the pool only through the wait operations `msPoolInit` arms (`msPoolWaitsArmed`), so
  `msWaitForReady` may not call `msPoolGet()` or `msPoolStartThread` through `msPoolRunEdge`,
  `msPoolCompensate` or `msPoolCompensateEnd`. Proven RED on the runtime of `e21c6e7c3666` (rtx:
  `topLevel` links `msPoolWorkerLoop` at both modes), GREEN with the armed operations (rtx,
  2026-11-12).
- **`caseDirectionLinksItsTablesOnly.ms`** — a program that calls only `toUpperCase` links no
  lower-case table or Final_Sigma span, and one that calls only `toLowerCase` no upper-case table,
  because the case kernels in `std/core/string/caseCore.ms` are expanded once per direction, as Nim
  expands its `convertRune` template per direction. Builds both at `--danger` and `--release` with
  `--lto=off` and reads the symbol table. Proven RED on tree `939e207b0891` (Linux x86-64: the upper
  program links `msLowerFull`, `msCasedSpans`, `msCaseIgnorableSpans`), GREEN on the fix (Linux
  x86-64). On macOS arm64 at `--danger` the upper-only program's `__const` goes 15,072 → 7,192 B.
- **`releaseDisposeOutOfLine.ms`** — every generic ref release macro (`msDecref`, `msDecrefAny`,
  `msDecrefCyclic`, `msAtomicDecref`, `msDecrefCyclicEdge`) decides inline and disposes through one
  out-of-line call, as Nim inlines only `nimDecRefIsLast` and calls `nimDestroyAndDispose`. Compiles
  each macro at `-O3` and reads the object's symbols. Proven RED on tree `9966bc7d6d35` (macOS arm64:
  all five reference `msUnownedOutlives`), GREEN on the slice-2 tree. Since the husk change the
  inline dispose marker is `msHeapFree`. The four plain releases also leave a last ref's cycle-root
  unregister to the out-of-line call (the edge release keeps it): RED on tree `516f13436208`, where
  `msDecref`, `msDecrefAny` and `msDecrefCyclic` call `msUnregisterCycle`.
- **`oneCharLiteralLinksNoStringTable.ms`** — a one-char ASCII literal (the `" "` between
  `console.log` arguments too) and `s[i]` on an ASCII string build their `msString` in place over
  `msCharPayloads[c]`, as every other literal is a `MS_STRING_LIT` over its static payload, so a
  program links the 128 payloads and not a second 128-entry `msString` table. Builds and runs a
  program with a one-char literal and an index at `--danger` and `--release` with `--lto=off` and
  reads the symbol table: no `msCharTable`, and `msCharPayloads` present. Proven RED on the compiler
  of `e21c6e7c3666` (rtx: `D msCharTable` at both modes), GREEN on the fix (rtx, 2026-11-12).
