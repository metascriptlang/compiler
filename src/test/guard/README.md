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
bash src/test/guard/run.sh            # both gc modes (drc + orc)
GUARD_GC=drc bash src/test/guard/run.sh
MSC=./msc bash src/test/guard/run.sh  # a specific compiler
```

Pass = clean exit, no `DOUBLE-DESTROY`, all declared balances hold.

## Adding a guard — use `/nim-guard`

1. Pin the invariant + its Nim source + NIM-REF verdict (SAME vs
   DIVERGE-INTENTIONAL). If unsure, run `/trace-nim` first.
2. Write a probe here whose header cites the Nim invariant, the NIM-REF row, and
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
```

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
  function signature (`hashType` tyProc / `sameInstantiation`; NIM-REF §1
  "Structural type-dedup keys"). Two nullable-fn fields of different arity: a
  collapse re-erases the 2nd's arity → checker "expected at most 0" → build RED.
  Proven RED on the pre-fix compiler, GREEN post-fix (drc+orc).
  - **Known gap:** the sibling `monoTypeKey` collapse is NOT guarded — its
    function case is *benign* (uniform `msClosure` repr → a collapsed
    `Holder__function` still runs correct), and its only RED case (anon-union
    type-arg → fused `msUnion` payloads) can't yet compile clean because of a
    separate union ctor-param proto/def indirection bug + generic-fn-over-union
    bug. Add that guard once those land (logged in neon `BUGS.md`).
