\# PARALOCK — Locked Design for Unified Parallel/Concurrent Execution



> Status: \*\*DESIGN LOCKED\*\*. Phases 0-9 shipped. Phase 6 completed 2026-07-22 — S1/E61 + S3/E62 enforced in the checker (Amendment I4/I5, §7.3 note); Phase 9 completed 2026-07-22 — E40 sequential-await-in-loop lint shipped alongside the E3 handle-reuse lint (both run in the checkPass loop checkers). Amendment I18 (2026-07-22): actor shell reclamation is owner-scheduler-deferred — `stop()` never frees (§7.4 R1 note, §8 I18). Amendment I19 (2026-07-22): pid indirection — pids are generation-checked table handles packed in 53 bits; ops on a stale pid are clean no-ops; shell free is hazard-deferred; links/monitors/mutedBy/CD-refs/name-registry store pids, never pointers (§7.4 I19, §8 I19). Amendment I20 (2026-07-23): a CALL (reply-bearing message) to a dead / stale / stopping actor \*\*fails its reply future\*\* (BEAM `{noproc}`) at every drop site — stale-pid lookup, dead-actor send guard, and teardown mailbox drain — so the awaiting caller unblocks instead of hanging (§7.4 I20, §8 I9). Amendment I (2026-09-03): the actor boundary speaks four verbs — COPY / MOVE / BORROW / SHARE; SHARE is \*\*Arc<T> only\*\* (sendable pointee + atomic incref at the message boundary), a plain const-ref SEND is an error while an awaited CALL keeps the borrow, and shared mutable state is \*\*Locked<T>\*\* — one fused atomic-rc cell with update/read closures — superseding Amendment D's Arc<struct{lock}> pairing (§7.6 note, §8 I21/I22). Consult this document before modifying `spawn`, `await`, actor suspension, or cross-thread lifetime rules. Changes require explicit amendment.



\## 0. Scope \& Intent



PARALOCK defines the \*\*unified execution model\*\* spanning three primitives:



\- `spawn` — structured parallel tasks (Malebolgia-style, zero-copy borrowing)

\- `actor` — stateful isolated entities (Pony/Swift-grounded, message passing)

\- `await` — single surface keyword, type-directed dispatch, context-sensitive lowering



It \*\*locks\*\* the following decisions:



1\. `await` is the only keyword the user ever writes. No `awaitAll`. No `Promise.all` ceremony for spawn groups.

2\. \*\*One surface type: `Promise<T>`.\*\* `async function`, `spawn(...)`, actor CALLs, and `.parallel().collect()` all produce `Promise<T>`. Origin (async/spawn/actor) is tracked internally via flag bits (`AwaitableAffine`, `AwaitableScopeBound`) — developers never learn a second type name.

3\. `await` lowers differently based on the static type of its operand \*\*and\*\* the surrounding execution context (sync / async / actor method).

4\. Spawn-inside-actor is \*\*legal\*\* via cooperative actor suspension (not banned). Enforced by a small set of static and runtime rules.

5\. All concurrency primitives share one runtime: `runtime/promise/pool.c`'s fixed worker pool (one thread per CPU core). There is no second pool.

6\. Cancellation and timeouts are first-class on spawn groups; they plumb through to the actor supervision tree.



What PARALOCK \*\*does not\*\* change:



\- Existing `Promise<T>` + `async`/`await` semantics outside actors (they continue to work as today).

\- Existing actor SEND / CALL message protocol.

\- The three transfer rules (COPY / MOVE / SHARE) for cross-actor arguments.

\- The Sendable checker for actor boundaries.



\---



\## 1. Executive Summary



\*\*The one-paragraph version.\*\* Users write `await` on a `Promise<T>` — whether it came from an `async function`, a `spawn(...)`, an actor CALL, or an array/tuple of mixed origins. The compiler looks at the static type (and its flags — some Promises are affine and scope-bound because they came from `spawn`) and the enclosing function context, then picks one of three lowerings: cooperative yield (current Promise behavior), cooperative actor suspension (when inside an actor method), or Malebolgia-style thread blocking (when inside sync code). All three share the existing worker pool, so spawn tasks, promise continuations, and actor messages interleave across the same N workers. Inside actor methods, spawn children can borrow the actor's fields (zero-copy fan-out over actor-owned state), provided they don't capture `this` and don't CALL back into the suspended parent. Cancellation and timeouts propagate through a shared `AwaitGroup` primitive.



\*\*The diagram version.\*\*



```

&#x20;                      await  (single keyword, type-directed)

&#x20;                             │

&#x20;                ┌────────────┼─────────────────────────┐

&#x20;                │            │                         │

&#x20;        Promise<T>     Promise<T>                 Promise<T>\[]

&#x20;      (plain, from     (affine bits,             (mixed origins

&#x20;        async/actor)   from spawn)              unify to plain)

&#x20;                │            │                         │

&#x20;                ▼            ▼                         ▼

&#x20;      cooperative yield  AwaitGroup of 1         AwaitGroup of N

&#x20;                │            │                         │

&#x20;                └────────────┴─────────────┬───────────┘

&#x20;                                           │

&#x20;                      ┌────────────────────┴────────────────────┐

&#x20;                      │  Context-sensitive lowering picks ONE:  │

&#x20;                      │                                          │

&#x20;                      │   sync function / main                   │

&#x20;                      │      → block caller thread on futex      │

&#x20;                      │                                          │

&#x20;                      │   async function                         │

&#x20;                      │      → cooperative yield (existing)      │

&#x20;                      │                                          │

&#x20;                      │   actor method                           │

&#x20;                      │      → cooperative actor suspension      │

&#x20;                      │        (new)                             │

&#x20;                      └──────────────────────────────────────────┘

&#x20;                                           │

&#x20;                                           ▼

&#x20;                         Shared worker pool (runtime/promise/pool.c)

&#x20;                         N = msDetectCPUs(), main = scheduler 0

&#x20;                         Promises + Actors + Spawn tasks interleave

```



\---



\## 2. Current State (What Already Exists)



PARALOCK is an \*\*evolution\*\*, not a greenfield design. Baseline as of 2026-04-05:



| Subsystem | Status | Location |

|---|---|---|

| Fixed worker pool (one per CPU core) | Shipped | `runtime/promise/pool.c` |

| `Promise<T>`, `async`/`await`, `Promise.all`, `Promise.race` | Shipped | `runtime/promise/\*` |

| `spawn(closure)` returning `Promise<T>` | Shipped | `runtime/promise/pool.c` + transform |

| Zero-copy borrowing via structured concurrency (sync context) | Shipped | documented in `docs/LANG-ASYNC.md` |

| Actor runtime (SEND/CALL, linking, monitors, supervisors) | Shipped | `runtime/actor/actor.h` |

| Sendable checker at actor boundaries | Shipped | `src/checker/checkExprPass.ms` |

| Three transfer rules (COPY/MOVE/SHARE) | Shipped | documented in `docs/LANG-ASYNC.md` |

| `AbortController` / `AbortSignal` for Promise cancellation | Shipped | `runtime/promise/\*` |



PARALOCK layers the following on top:



| Capability | Status |

|---|---|

| Affine `Promise<T>` from `spawn(...)` (compile-time escape check via `AwaitableAffine`/`AwaitableScopeBound` flags) | \*\*Shipped\*\* (Phase 1, via REPROMISE T2 flag-based unification) |

| Type-directed `await` dispatch over affine-Promise groups | \*\*Shipped\*\* (Phase 2, awaitLower fused + deferred paths) |

| `AwaitGroup` blocking primitive (sync context) | \*\*Shipped\*\* (Phase 2, runtime/promise/awaitGroup.h) |

| Typed future readers (`msFutureReadDouble` etc.) | \*\*Shipped\*\* (Phase 2 refinement, zero unbox for primitives) |

| Actor message type dispatch (array 2-slot packing, typed completion) | \*\*Shipped\*\* (Phase 2 bugfix, actorLower.ms) |

| Spawn/async array boxing (`msSinkBoxStruct`/`msUnboxStruct`) | \*\*Shipped\*\* (Phase 2 bugfix, spawnLower + asyncBridge) |

| `return await` split in async functions | \*\*Shipped\*\* (Phase 2 bugfix, asyncDesugar pre-pass) |

| Cooperative actor suspension during `await` on affine Promise | \*\*Shipped\*\* (Phase 5: `MS\_ACTOR\_SUSPENDED` flag, `suspendedFut` field in actor.h) |

| `spawn`-inside-actor with zero-copy borrowing of actor fields | \*\*Shipped\*\* (Phase 5-6: actor suspension + actorLower transform) |

| No-self-capture rule for spawn closures inside actor methods (S1) | \*\*Pending\*\* — not enforced; `spawn(() => doWork(this))` inside actor method currently compiles without error |

| Read-only field borrows in spawn thunks (S3) | \*\*Pending\*\* — not enforced; `spawn(() => { this.field = x; })` currently compiles without error |

| Out-of-band actor stop flag (R1) | \*\*Shipped\*\* (Phase 6: `stopRequested` atomic in actor.h, `msActorStop` sets it, `msActorResumeFromFut` checks and fails reply future on stopped resume) |

| `AwaitGroup` cancellation + timeout | \*\*Shipped\*\* (Phase 3: timed wait, `spawn(fn, {timeout})`, safe-point injection) |

| Async cooperative spawn await (single) | \*\*Shipped\*\* (Phase 4a: stepper + future callback — no code changes needed) |

| Async cooperative spawn groups (`doneFut`) | \*\*Shipped\*\* (Phase 4b: `doneFut` field in awaitGroup.h, MPSC completion in finishSlot) |

| \~\~Ancestor CALL deadlock prevention (R2)\~\~ | Dropped — no actor-system precedent |

| Help-first scheduling for nested spawn saturation | \*\*Shipped\*\* (Phase 8: `msPoolHelpOne` in pool.c, help-first wait in awaitGroup.c) |

| \~\~`detach` builtin\~\~ | Removed — actor SEND covers fire-and-forget |

| Typed `Promise.all` over primitive / string / ref / int32/int64 / user-struct element types (heap-built `msNumberArray` / `msStringArray` / `msRefArray` / `int32\_tArray` / `T##Array` respectively) | \*\*Shipped\*\* (2026-04-17: per-element-type `MS\_PROMISE\_ALL\_FOR` instantiation; silently broken by the 2026-06/08 rep changes and repaired 2026-08-28 — result-cell + collect-consume contract in §2.1; dispatch is the call-site intercept (`expressions.ms`) → `ensurePromiseAllInstance` (`types.ms`) per I14; generic `msPromiseAll` kept as void-only fallback) |

| `nodeType` restored to "result type only" contract (no more sizeof-hint abuse) | \*\*Shipped\*\* (2026-04-18, Step 4: `msFutureCreateInline` carries `Promise<T>`, `msSinkBoxStruct` carries `void\*`; codegen reads T via `awaitedType` / `args\[0].nodeType`) |



\### 2.1 Implementation contracts (2026-04-18)



Cross-pass rules every future / promise intrinsic must honour. Codegen is thin

and dumb; when it needs a type, it gets it from the AST's semantic information,

not from a side channel:



\- \*\*Per-type instantiation is the only mechanism for inline-valued futures.\*\*

&#x20; For every `Promise<T>` encountered in a module, codegen emits `MS\_FUTURE\_STRUCT(msFuture\_<T>, T)`

&#x20; and — when T is reachable by `Promise.all` — `MS\_PROMISE\_ALL\_FOR(...)`.

&#x20; There is no generic fallback for collecting typed values; the old

&#x20; `msPromiseAll(msRefArray\*)` reads `f->value` as `void\*` and only remains as a

&#x20; void-only compatibility path. `race`/`any`/`allSettled` still ride that legacy

&#x20; path with zero test coverage (probed 2026-08-28, native drc, gen-2 binary of

&#x20; main `16da396`): scalar `T` happens to come out right (`race<float64>`,

&#x20; `race<int32>`, `any<float64>`, `any<int32>` all returned correct values — an

&#x20; 8-byte value fits the `void\*` slot); `T = string` is SILENT WRONG

&#x20; (`race<string>` returned an empty string; `any<string>` returned a value

&#x20; belonging to a \*different\* combinator's input future); `allSettled<T>` crashes

&#x20; loud (NULL result array on `.length` — and its decl promises `Promise<T\[]>`,

&#x20; not the JS `{status, value|reason}\[]` shape; that surface decision is open).

&#x20; NOT verified: struct `T` for race/any, string/struct for allSettled, and all

&#x20; three on the js target (there they bind the native `Promise` global via

&#x20; `std/core/promise/index.jms`). The 2026-08-28 typed-collection repair

&#x20; deliberately covered `Promise.all` only.

\- \*\*`Node.nodeType` is the expression's result type, universally.\*\*  Every call

&#x20; emitted by the transform pipeline tags its node with the call's actual

&#x20; result type:  `msFutureCreateInline` → `Promise<T>`, `msSinkBoxStruct` →

&#x20; `void\*`, `msSpawnInto` → `Promise<T>`, `msPromiseAllFor\_msFuture\_<T>` →

&#x20; `Promise<T\[]>`. DRC analysis relies on this invariant.

\- \*\*Codegen never treats `nodeType` as a sizeof-hint.\*\*  When C codegen needs

&#x20; `sizeof(T)` or `offsetof(msFuture\_<T>, value)`, it extracts T from the call's

&#x20; declared result type (`awaitedType(node.nodeType)`) or from the relevant

&#x20; argument's `nodeType` (e.g. `msSinkBoxStruct` reads `cd.arguments\[0].nodeType`).

&#x20; The only surviving `c.nodeType = innerType` in the transform is

&#x20; `awaitLower:makeUnboxCall` — legitimate, since the unbox call's result really

&#x20; is T.

\- \*\*Result arrays are refcounted cells; collect consumes.\*\* (Amended 2026-08-28,

&#x20; repairing the 2026-04 contract after three unflagged rep changes broke it: lean

&#x20; `Ref<Array>` cells + boxed struct futures (2026-06-16, `2d31060`) and

&#x20; module-mangled struct names (2026-08-17, `c2cf215`).)

&#x20; `msPromiseAllFor\_msFuture\_<T>` allocates the result `<T>Array` as a refcounted

&#x20; heap cell — `msAllocTyped` + a per-instance TypeInfo whose `destroyFn` is the

&#x20; array's destroy walker — and completes the result future with the cell pointer.

&#x20; The consumer reads via `msFutureRead` + `(arrType\*)` cast and owns the cell:

&#x20; its DRC decref releases collected elements and frees the payload. An unread

&#x20; result is released by the result future's `valueDestructor` on the drain path

&#x20; (futures still pending at process exit are exit-slack — ledger blind spot,

&#x20; `msFutureTypeInfo.destroyFn == NULL`). No inline array storage in the future

&#x20; value field.

\- \*\*Collect consumes the input future's value (msFutureRead convention: move

&#x20; out + clear slot).\*\* Ref elements move the pointer and NULL the slot; string

&#x20; elements move the inline `msString` and zero the slot; struct-like elements

&#x20; move the bits out of the heap box and free the shell — struct/tuple

&#x20; `Promise<T>` values are BOXED (generic `msFutureCreate` future, box pointer in

&#x20; the `void\*` slot, produced by `msSinkBoxStruct`; both value fields sit at the

&#x20; same first-after-base offset, so `\&f->value` is the slot on either layout).

&#x20; A duplicated input future in one `Promise.all` yields a zero/NULL slot for its

&#x20; second entry — the same second-read degradation `msFutureRead` has, never a

&#x20; double-free. Input futures are incref'd in the setup loop and decref'd exactly

&#x20; once in the completion callback, so the caller dropping the input array cannot

&#x20; free a future mid-flight.

&#x20; Guards: `src/test/guard/promiseAllTypedCollect.ms` (proven-red against both a

&#x20; bare-malloc result cell, rc=134 misaligned-TypeInfo, and an inline read of a

&#x20; boxed struct future, GUARD RED on values) and corpus `735-promiseAllTyped`

&#x20; (c/orc/danger/js parity across five element-type classes; the former

&#x20; `@xfail(js)` was lifted 2026-08-28 — `std/core/promise/index.jms` now binds

&#x20; the native `Promise` global on the js target).



\---



\## 3. Design Principles



1\. \*\*One keyword for the user.\*\* `await` everywhere. No `awaitAll`, no new `par` keyword, no context-specific variants exposed at the surface. Context handling is the compiler's job.

2\. \*\*Type-directed dispatch.\*\* The static type of the awaited expression determines the lowering strategy. Users never need to "know" which variant they're invoking.

3\. \*\*Context-sensitive lowering.\*\* The same source-level `await` compiles to different runtime calls depending on whether the enclosing function is sync, async, or an actor method. Transparent.

4\. \*\*Structured by default.\*\* `spawn` is structured and lifetime-bounded. For fire-and-forget, use actor SEND (isolation + supervision).

5\. \*\*Zero-copy is the reason to exist.\*\* If spawn couldn't borrow, sub-actors would cover every use case. Preserve zero-copy borrowing aggressively, including inside actor methods.

6\. \*\*No deadlock by construction.\*\* Every spawn-actor interaction is either statically prevented (no-self-capture) or runtime-detected (ancestor CALL check) or bounded by timeout. There must be no "hope it doesn't deadlock" paths.

7\. \*\*One pool, many users.\*\* All concurrency primitives (promise continuations, spawn tasks, actor polling) run on the same worker pool. Never introduce a second pool without proof that work stealing across subsystems cannot serve.

8\. \*\*Codegen stays thin.\*\* Every lowering decision lives in transform passes or the checker. Codegen emits calls to runtime intrinsics — it does not decide which intrinsic to call.

9\. \*\*Safety is a compile error, not a runtime panic.\*\* Borrow escape, affine violations, self-capture inside actor spawn — all caught by the checker with actionable diagnostics.

10\. \*\*One surface type for the user.\*\* `async function`, `spawn()`, actor CALL, and `.parallel().collect()` all return `Promise<T>`. The compiler tracks origin via internal flag bits — safety rules (affine, scope-bound) apply automatically when the flags are set. The user never writes a second type name.



\---



\## 4. Surface Syntax \& Semantics



\### 4.1 `spawn`



`spawn` is a \*\*builtin function\*\* (not a keyword) that takes a zero-argument thunk and schedules it on the worker pool. It immediately returns a `Promise<T>` where `T` is the thunk's return type. Surface type is the same `Promise<T>` users already know — the affine+scope-bound semantics are attached as flag bits on the resulting type so the compiler can enforce safety without forcing users to learn a second type name.



```ms

// Single task — the return is Promise<int>, internally tagged affine+scope-bound

const h: Promise<int> = spawn(() => compute(x));



// Void task — thunk returns void

const h2 = spawn(() => { backgroundCleanup(); });



// Array of affine promises

const handles: Promise<int>\[] = items.map(item => spawn(() => process(item)));



// Tuple of heterogeneous handles (compile-time fixed shape)

const group = (spawn(() => typecheck(ast)), spawn(() => lint(ast)), spawn(() => metrics(ast)));

```



\*\*Semantics.\*\* `spawn(thunk)` schedules `thunk` onto the worker pool and immediately returns a `Promise<T>` with `AwaitableAffine` + `AwaitableScopeBound` bits set on `typeFlags`. A spawn-origin Promise is an \*\*affine\*\* value: it must be consumed exactly once via `await`, `move`, or by passing it to a sink function before its creating scope exits. When the value flows into a context that can't preserve the flags (mixed awaitable array, generic `Promise<T>` parameter, explicit upcast), the flags are stripped implicitly with a lint — the safety loss is never hidden.



\*\*Why a function and not a keyword?\*\* Keeping `spawn` as a function means: no parser changes, no new grammar forms, no keyword collisions with user code. The affine semantics ride entirely on flag bits set by `createGenericInstance` on the return type, which the checker recognizes via `isAffineAwaitable(t)`. Everything that makes `spawn` special — the lifetime rules, the borrow checks on captures, the consumption tracking — happens because of those flag bits, not because of syntax or a distinct type name.



\### 4.2 `await`



```ms

// Regular Promise from async function

const data = await fetchData();



// Promise from spawn — affine flags on type, lowers to AwaitGroup of 1

const result = await spawn(() => compute());



// Array of Promises (mixed origins OK — flags unify to plain Promise<T>)

const results = await handles;



// Tuple of Promises (compile-time fixed shape)

const (types, lints, metrics) = await (

&#x20;   spawn(() => typecheck(ast)),

&#x20;   spawn(() => lint(ast)),

&#x20;   spawn(() => metrics(ast)),

);



// With timeout

const results = await handles timeout 5000;

const result = await spawn(() => compute()) timeout 1000;

```



\*\*Semantics.\*\* `await e` yields the current execution context until the awaited thing is ready. The lowering depends on the static type (and its flags) of `e`:



| `typeof(e)` | Lowering |

|---|---|

| `Promise<T>` (no affine flag — from async, actor CALL, etc.) | Cooperative yield on future (existing) |

| `Promise<T>` (affine flag — from `spawn(...)`) | AwaitGroup of size 1, fused fast-path |

| `Promise<T>\[]` | AwaitGroup of size `e.length` |

| `(Promise<T1>, Promise<T2>, …)` | AwaitGroup of fixed heterogeneous size |

| Any other type | Compile error: not awaitable |



> \*\*Status (measured 2026-08-28).\*\* The typed `Promise.all` join covers the group

> use-cases end-to-end today: a spawn-handle array (`Promise.all(\[spawn(..), ..])`,

> probe → correct values) and a mixed spawn+async array of the same T (E43 affine

> strip, probe → correct values) both build and run; corpus `735-promiseAllTyped`

> pins the async-array case on c/orc/danger/js. The bare-array form `await handles`

> is NOT lowered: it fails LOUD at codegen (`internal: unresolved type (kind=48)` —

> the flagless-unknown sentinel), not silently. Tuple await and `timeout` are

> likewise unimplemented. Whether to ship this surface as sugar over the working

> join, or amend it away and bless `Promise.all` as the permanent join (plus turn

> the kind=48 internal into a proper diagnostic), is an OPEN decision — either

> path requires an explicit amendment here.



\### 4.3 Fire-and-Forget



`detach` was originally planned as a builtin for unstructured fire-and-forget, but was \*\*removed\*\* because actor SEND covers all fire-and-forget use cases with better guarantees:



\- \*\*Isolation\*\*: Actor methods run on the actor's mailbox, no shared mutable state.

\- \*\*Error handling\*\*: Actor supervisors catch and restart on failure.

\- \*\*Backpressure\*\*: Mailbox provides natural flow control.



For fire-and-forget work, define an actor and use SEND (non-awaited method call):



```ms

actor BackgroundWorker {

&#x20;   cleanup(config: Config): void { /\* ... \*/ }

}

const worker = new BackgroundWorker();

worker.cleanup(config);  // SEND — fire-and-forget

```



\### 4.4 What `await` does NOT support



\- `await` on a non-awaitable expression → compile error.

\- `await` on an \*\*affine\*\* `Promise<T>` (from `spawn`) \*\*not\*\* owned by the current scope (received via a function parameter) → compile error. The scope-bound flag is carried on the type; handles can only be awaited where they were created.

\- `await` on a mixed array where inner `T`s differ (e.g. `Promise<int>` and `Promise<string>` in the same literal) → compile error. Mixing origins (spawn + async) of the same `T` is fine — the compiler implicitly strips affine flags and unifies to plain `Promise<T>`.



\---



\## 5. Type System



\### 5.1 `Promise<T>` — the single surface type



```ms

// Conceptually, built-in:

type Promise<T> = GenericInstance "Promise"<T> with optional flag bits:

&#x20;   AwaitableAffine      (bit 6 of typeFlags)

&#x20;   AwaitableScopeBound  (bit 7 of typeFlags)

```



There is \*\*one surface type\*\*: `Promise<T>`. Origin determines which flags are set on the instance:



| Origin | Surface type | Flags set |

|---|---|---|

| `async function f(): Promise<T>` return | `Promise<T>` | none |

| Actor CALL (`actor.method(): T` on non-actor method) | `Promise<T>` | none |

| `spawn(thunk)` | `Promise<T>` | `AwaitableAffine | AwaitableScopeBound` |

| `@awaitable` user type (stdlib extension) | `Promise<T>` | none |

| `@affineAwaitable` user type | `Promise<T>` | `AwaitableAffine | AwaitableScopeBound` |



A `Promise<T>` with both flags set is \*\*affine\*\* (must be consumed exactly once) and \*\*scope-bound\*\* (cannot escape its creating scope). A `Promise<T>` without flags is a plain async value.



Users don't read the flags — they just see `Promise<T>`. The compiler's semantic queries (`isAffineAwaitable(t)`, `isScopeBoundAwaitable(t)` — currently collapsed into `isAffineAwaitable` since both bits move together) test the flags when enforcing R1-R6.



\### 5.2 Affine tracking



For spawn-origin `Promise<T>` (both flags set), the checker tracks each value from creation to consumption. Rules:



\- \*\*R1 (Must consume).\*\* Every affine `Promise<T>` must be consumed by `await`, `move`, passing to a sink function, or explicit upcast (`h as Promise<T>` strips flags) before its binding goes out of scope.

\- \*\*R2 (Single consume).\*\* Consuming an affine Promise invalidates its binding. Re-use after consume is a compile error.

\- \*\*R3 (No escape).\*\* An affine Promise cannot be returned, stored in a struct field, placed in a global, captured by an outlasting closure, or passed to a function parameter typed as plain `Promise<T>` without losing its flags.

\- \*\*R4 (Array homogeneity for affine).\*\* An array of affine Promises (`Promise<T>\[]` where every element is spawn-origin) stays affine: all elements must be consumed via one `await` on the array.

\- \*\*R5 (Tuple consumption).\*\* Tuples of affine Promises are consumed as a whole via `await`. Partial consumption is forbidden.

\- \*\*R6 (Conditional consume).\*\* If an affine Promise is created in a branch, it must be consumed on all paths that reach scope exit. `if` / `match` branches are tracked individually.



For plain `Promise<T>` (no flags), none of R1-R6 apply — it behaves like TypeScript's `Promise<T>`.



\### 5.3 Borrow capture tracking



Spawn closures can capture:



| Capture form | Allowed? | Rule |

|---|---|---|

| `const x` from outer scope (immutable binding) | Yes | Borrow checker ensures `x` outlives the await |

| `let x` from outer scope (mutable binding) | No | Compile error: "mutable capture forbidden in spawn" |

| Field access `this.f` (inside actor method) | Yes, \*\*read-only\*\* | See §7 for actor rules |

| Field access `obj.f` on a non-actor | Yes, treated as borrow of `obj` | Borrow checker ensures `obj` outlives await |

| `move x` (explicit ownership transfer) | Yes | `x` is dead in caller scope after spawn |



All captures are validated by the existing borrow/ownership checker, extended to understand that an affine `Promise<T>`'s "lifetime" ends at the `await` consuming it.

\*\*Amendment I enforcement note (2026-09-03, shipped in ace4d55f / 4f26ed0a / 8506c8ff — no rule change).\*\* Row 2 is now checked at every read position: `walkForMutableCaptures` delegates its default arm to `forEachChild`, so the three shapes the old hand-listed arms silently passed — a HiddenStdConv-wrapped argument, an `x++` write-back, a read inside a C-style `for` body (each a measured race: the worker read the parent's post-spawn write, or landed its write in the parent's env slot) — are errors again. Only a closure created inside a loop body gets a per-iteration env copy (a snapshot), which is why a captured loop counter needs the explicit `const it = iter` binding (corpus 411). Guard: `src/test/guard/spawnMutableCaptureShapes.ms` (proven red — the pre-fix compiler builds it clean).



\### 5.4 Affine Promise vs plain Promise — when flags strip



Both are the same surface type (`Promise<T>`). The flags are set at construction (spawn gives you a flagged Promise; `async function` gives you a flagless one) and \*\*strip implicitly\*\* when the value enters a context that can't preserve them:



| Context | Flag-preserving? | Behavior |

|---|---|---|

| Bind to `const h = spawn(...)` | Yes | `h`'s type carries flags |

| `await h` in same scope | Yes | R1 consumption satisfied, flags irrelevant after consume |

| Pass to function param of type `Promise<T>` (no flags expected) | \*\*No\*\* | Flags stripped at the boundary — callee sees plain Promise |

| Element of `Promise<T>\[]` literal mixing flagged + flagless | \*\*No\*\* | Unified to plain `Promise<T>\[]`, affine tracking dropped — compiler lints the loss |

| Explicit `h as Promise<T>` | \*\*No\*\* | User-opted strip — no lint |

| Return from function declared `Promise<T>` (flagless) | \*\*No (error)\*\* | R3 violated: affine Promise can't escape. Error unless return type explicitly requests affine. |



This gives users one mental model (`Promise<T>`) with safety-net flags that travel when they can and detach gracefully when they can't — the loss is always visible (lint or error), never silent.



\---



\## 6. Execution Model



\### 6.1 Runtime layout



```

┌─────────────────────────────────────────────────────────────┐

│                    MetaScript Runtime                        │

│                                                              │

│  Thread pool (runtime/promise/pool.c)                        │

│  ┌──────────────────────────────────────────────────────┐   │

│  │  Worker 0 (main thread)                               │   │

│  │  Worker 1, 2, …, N-1                                  │   │

│  │                                                        │   │

│  │  Each worker drives:                                   │   │

│  │    - Promise continuations (local queue)               │   │

│  │    - Actor polling (actors assigned to this sched ID)  │   │

│  │    - Spawn tasks (new: enqueued via AwaitGroup)        │   │

│  └──────────────────────────────────────────────────────┘   │

│                                                              │

│  Actor system (runtime/actor/actor.h)                        │

│  ┌──────────────────────────────────────────────────────┐   │

│  │  msSched\[N]: per-scheduler actor registries           │   │

│  │  Mailboxes per actor (lock-free MPSC)                 │   │

│  │  Cycle detector (reverse reachability)                │   │

│  │  Name registry, link/monitor tables                   │   │

│  └──────────────────────────────────────────────────────┘   │

│                                                              │

│  AwaitGroup (new: runtime/promise/awaitgroup.h)              │

│  ┌──────────────────────────────────────────────────────┐   │

│  │  Atomic counter + futex + result slots                │   │

│  │  Cancellation flag + deadline                         │   │

│  │  Optional actor-suspension continuation               │   │

│  └──────────────────────────────────────────────────────┘   │

└─────────────────────────────────────────────────────────────┘

```



\### 6.2 Lowering matrix



A single source-level `await e` compiles to one of three runtime intrinsics based on the pair `(typeof(e), enclosingContext)`:



| `typeof(e)` + flags \\\\ Context | \*\*Sync function / main\*\* | \*\*Async function\*\* | \*\*Actor method\*\* |

|---|---|---|---|

| `Promise<T>` (no flags) | `msPromiseAwaitBlocking(p)` — thread parks on future until resolved. | `msPromiseAwaitYield(p)` — yield to event loop. | `msPromiseAwaitActor(self, p)` — actor suspends, re-scheduled on resolve. |

| `Promise<T>` (affine flags set) | `msAwaitGroupBlocking(g)` — thread parks on futex. | `msAwaitGroupYield(g)` — yield to event loop. | `msAwaitGroupActor(self, g)` — actor suspends. |

| `Promise<T>\[]` | Same as single for the unified element type, with N slots | Same | Same |

| Tuple of Promises | Same as array, fixed shape | Same | Same |



The transform pass (`src/transform/lowering/awaitLower.ms`) picks the right intrinsic by inspecting the operand's resolved type and walking the enclosing function chain to find the innermost function and its context flag (sync / async / actor method). Codegen then emits a direct call.



\### 6.3 AwaitGroup lifecycle



```

1\. User writes:     const (a, b, c) = await (spawn(f), spawn(g), spawn(h));

2\. Transform emits: msAwaitGroupInit(g, 3);

&#x20;                   msSpawnTaskSubmit(g, 0, closure\_f);

&#x20;                   msSpawnTaskSubmit(g, 1, closure\_g);

&#x20;                   msSpawnTaskSubmit(g, 2, closure\_h);

&#x20;                   msAwaitGroupBlocking(g);   // (or \_Yield / \_Actor)

&#x20;                   a = g.results\[0]; b = g.results\[1]; c = g.results\[2];

&#x20;                   msAwaitGroupFree(g);

3\. Worker pool picks up tasks, runs closures, writes results to g.results\[i].

4\. Last task to complete decrements g.remaining to 0 and signals g.futex

&#x20;  (or re-enqueues the actor continuation, or resolves the async yield).

5\. Parent resumes, reads results, frees group.

```



\### 6.4 Context detection



The checker annotates every function body with its execution context during checkPass:



```ms

enum ExecContext {

&#x20;   Sync,              // plain function, main, callback

&#x20;   Async,             // async function or lambda

&#x20;   ActorMethod,       // method inside an actor declaration

}

```



`awaitLower` reads this annotation off the innermost enclosing function node. A nested closure inherits context from its enclosing function unless it is itself an `async` or actor method body.



\### 6.5 Thread behavior recap



| Lowering | Thread state | Scheduler visibility |

|---|---|---|

| `msAwaitGroupBlocking` | Caller thread parks on futex. Kernel removes it from runqueue. | Other workers continue driving everything. |

| `msAwaitGroupYield` | Caller function returns to event loop. Frame saved in state machine (stackless async). | Same worker picks up next queued task. |

| `msAwaitGroupActor` | Actor is marked `suspended`, continuation saved on heap. Scheduler thread returns to its worker loop. | Scheduler thread immediately runs next actor in its runqueue. Zero thread blocked. |



\---



\## 7. Actor Integration



This is the single most complex part of PARALOCK. It is also the primary value: \*\*spawn children running inside an actor method can borrow the actor's fields zero-copy, in parallel, for the duration of the await\*\*.



\### 7.1 The capability



```ms

actor Analyzer {

&#x20;   private ast: Program;    // large, owned by actor



&#x20;   analyze(): Report {

&#x20;       const (types, lints, metrics) = await (

&#x20;           spawn(() => typecheck(this.ast)),   // borrows this.ast

&#x20;           spawn(() => lint(this.ast)),         // borrows this.ast

&#x20;           spawn(() => metrics(this.ast)),      // borrows this.ast

&#x20;       );

&#x20;       return combine(types, lints, metrics);

&#x20;   }

}

```



Three spawn children run in parallel on worker threads, all reading the same `this.ast` instance with no copying. The actor is suspended for the duration — not blocked, not running — and its state is effectively frozen.



\### 7.2 Actor suspension state



A new actor lifecycle state: `msActorStateSuspended`. Between `msActorStateRunning` and `msActorStateIdle`:



```

States: Idle  →  Running  →  Suspended  →  Running  →  Idle  →  …

&#x20;                             │

&#x20;                             └── while waiting on an AwaitGroup

```



When a method executing on behalf of the actor calls `msAwaitGroupActor`:



1\. Actor's continuation (the rest of the method as a state machine) is saved in the actor struct.

2\. Actor flag flips to `Suspended`.

3\. The scheduler thread returns from the actor's run function — \*\*it does not block\*\*. It goes on to process the next actor in its runqueue.

4\. Spawn tasks run on the worker pool (same threads, different dispatch lane).

5\. When the last spawn task completes, it calls `msAwaitGroupResumeActor(g)`, which flips the actor back to `Running`, places it on its scheduler's runqueue, and signals the scheduler.

6\. Some scheduler thread (not necessarily the original one) picks up the actor, resumes the continuation, and finishes the method.



Zero threads are blocked. The only resource held during suspension is the heap memory for the saved continuation.



\### 7.3 Safety rules (static)



All enforced by the checker when a `spawn(...)` call appears inside an actor method body. Grounded in Swift actor isolation and Pony capability system.



\*\*S1. No `this` capture in spawn thunks.\*\*

The thunk passed to `spawn` inside an actor method may capture \*\*field borrows\*\* (e.g., `this.ast`) but not `this` itself. This prevents the child from invoking methods on the parent — which would trigger a deadlock since the parent is suspended.



Precedent: Swift `@Sendable` closures cannot capture actor-isolated `self`. Pony `recover` blocks cannot capture `ref` capabilities.



```ms

actor A {

&#x20;   process(): void {

&#x20;       await spawn(() => doWork(this));       // ERROR: 'this' captured

&#x20;       await spawn(() => doWork(this.field)); // OK: borrow of field

&#x20;   }

}

```



Note: S1 subsumes the need for a separate "no `this.method()` in spawn" rule — if `this` can't be captured, method calls on it are impossible.



\*\*S3. Spawn field borrows are read-only.\*\*

Any capture of `this.f` is treated as `\&const this.f`. Mutation of `this.f` inside the spawn thunk is a compile error. The actor is suspended — not executing — so mutations would happen during "frozen" state, which we want to forbid.



Precedent: Swift `nonisolated let` on actor properties = read-only from outside isolation. Pony `box` capability = read-only alias.



\*\*Dropped rules (not backed by Swift/Erlang/Pony):\*\*

\- \~\~S2 (no `this.method()` in spawn)\~\~: Redundant with S1 — captured `this` is the prerequisite.

\- \~\~S4 (no mutation between spawn and await)\~\~: Rust borrow-checker concept. Swift suspends the actor immediately (no window). Pony has no sync await. Erlang has full isolation. No actor-system precedent for a "frozen code window" in the parent body.

\- \~\~S5 (no `this.method()` between spawn and await)\~\~: In our model the parent is still running sequentially before await — calling `this.method()` is a normal function call, not reentrancy. Pony/Swift enforce non-reentrancy structurally (one behavior at a time), not by banning calls in a code window.



\*\*Amendment I4/I5 (2026-07-22).\*\* S1 and S3 are now enforced. Enforcement point: the spawn-capture walk (`checkSpawnCaptures` → `walkActorSpawnRules`, checkExprPass), gated on the checker's actor-body context (`currentActorName`) — the same signal the member-access isolation check uses. The walk is forEachChild-based, descends into nested closures (same `this`), skips nested spawn thunks (each spawn call runs its own pass), and peels the checker's HiddenDeref/HiddenStdConv read wrappers (ref-typed `this.f` reads arrive wrapped; assignment LHS does not). Error tags: `(PARALOCK S1/E61)`, `(PARALOCK S3/E62)`.



Clarifications locked by this amendment:

\- \*\*S3 is a deep syntactic write ban\*\* — any assignment, compound assignment, `++`/`--`, `move`, or `out` argument whose target chain roots at `this` (`this.f = x`, `this.f.g = x`, `this.f\[i] = x`) errors. Pony `box` (deep read-only alias) is the precedent; Swift `nonisolated let` covers only the shallow case. (`out this.f` is unparseable today — out-args accept identifiers only; the walker's OutExpr arm is defensive so the ban survives if out-member ever parses.)

\- \*\*S1 also rejects `this.<method>`\*\* as a call or as a value — both re-enter a suspended actor (mailbox CALL deadlocks on the suspended parent; a direct `\_impl` call would bypass mailbox serialization). This is the subsumption note above, made operational.

\- \*\*E69's catalog row citing S4 is stale\*\* — S4 was dropped; the enforced rule is S3, and it reports at the in-thunk write site. Parent-body mutation between spawn and await remains legal.

\- \*\*Known v1 limits\*\* (documented, not bugs): alias laundering (`const self = this;` then capturing `self`) is not tracked — deliberate opt-out, same family as the E12 affine upcast; interior mutation via method calls (`this.f.push(x)`) needs capability-style mutability analysis the type system doesn't have; generic actor methods re-checked at instantiation run outside the actor-name context and skip S1/S3 (same pre-existing gap as the member-access isolation check).

\- \*\*E40 ships as a warning\*\* in all five loop checkers (while/for/for-of/for-in/do-while), stopping at closure boundaries (deferred execution is not per-iteration sequential) and nested loops (each runs its own scan). Its suggested fix names `await Promise.all(handles)` — the §4.2 array-await surface (E41, E8, E11, E44, tuple await, `timeout`) is designed but \*\*unimplemented\*\*; `Promise.all` is the shipped join (I14). Related doc-impl gap recorded: `await` on a non-awaitable currently types `unknown` silently instead of erroring per §4.4 — out of this amendment's scope.



\### 7.4 Safety rules (runtime)



\*\*R1. Out-of-band stop.\*\*

When a supervisor (or any code) calls `stop(actorPid, reason)` on a suspended actor, the runtime sets a flag on the actor struct \*\*without touching the mailbox\*\*. The flag is checked in two places:



\- Immediately when `msActorResumeFromFut` tries to resume the actor: if stop flag is set, the resume cancels the AwaitGroup (propagating cancellation to spawn children) and unwinds the actor method via an exception.

\- Inside `msActorSuspend`, before actually suspending: if stop already came in during a race, cancel immediately.



This prevents "supervisor can't kill a stuck actor" deadlocks.



\*\*Amendment I18 (2026-07-22).\*\* `stop()` never tears down or frees the actor shell on the caller's thread — the shell may be a live run-queue node, mid-process on another worker, or held as a pending resume-callback env. For awake/idle actors, `stop()` marks (`stopRequested` + `stopReason`) and queues a runtime-internal STOP signal (kind −4) through the normal mailbox lane (same lane R5 uses for exit signals), so scheduling stays on the wasEmpty edge. For suspended actors, the letter of R1 above is unchanged: flag only, mailbox untouched; the resume callback fails the reply, opens the reap gate with its last shell access (`suspendedFut = NULL` release), and the owner's reap scan collects. Teardown (`onTerminate`, links, monitors, drain) and `free` always run on the owning scheduler — see §8 I18.



Precedent: Erlang OTP `supervisor:terminate\_child/2` sends EXIT signal bypassing normal message processing. Pony ORCA protocol can collect actors regardless of mailbox state.



\*\*Amendment I19 (2026-07-22).\*\* A pid is no longer the shell pointer. `msActorCreate` claims a slot in a global segmented pid table and packs `\[generation:27 | slot:26]` into 53 bits — double-exact, because pids ride EXIT/DOWN payloads as doubles. `msActorFromPid` is the only pid→shell path: it validates the slot's generation, publishes the shell to a per-thread hazard slot, re-validates, and returns NULL for a dead or reused slot — send/stop/link/monitor/call on a stale pid is a clean no-op (BEAM process-table semantics; the I18 scheduling/reap half of the model is Pony's and is untouched). Teardown releases the pid slot (generation bump) before `onTerminate`, so no new lookup can reach a dying shell; `free(a)` consults the hazard registry and, while any in-flight lookup still pins the shell, defers the free to the owner's reap scan (hazard-pointer reclamation standing in for BEAM's thread-progress, which requires managed-thread machinery we don't have). A bounded runtime call is the maximum pin lifetime; the visited shell in `msActorProcess` is instead protected by `processing` (I18), and the suspended shell by the `suspendedFut` gate. Every persistent cross-actor edge that outlives a bounded call — links, monitor watchers, mutedBy, CD refs, name registry — stores pids, never pointers, and re-validates through the table on every use; the shell carries its own `pid` field so teardown cascades and CD emit pids without ptr→pid casts. The owner's reap scan reaps only suspended-stopped shells: the stopped resume path leaves `MS\_ACTOR\_SUSPENDED` latched, which keeps senders off the wasEmpty edge, so no run-queue entry can exist at scan-reap time — `scheduled` alone cannot prove that (a markEmpty/push overwrite race would free a live queue node). Awake and idle stops are always reaped at a STOP-msg visit's gate, which owns the pop.



\*\*Amendment I20 (2026-07-23).\*\* I19 made ops on a stale pid clean no-ops — correct for SEND/link/monitor (fire-and-forget), but a \*\*CALL\*\* carries a reply future the caller `await`s, so a silent no-op leaves that future forever uncompleted → the caller hangs. I20 completes the no-op for the reply-bearing case: a CALL to a dead / stale / stopping target \*\*fails its reply future\*\* (`msFutureFail(replyFuture, NULL)` — the same noproc primitive R1 already uses at `msActorResumeFromFut` and `msActorSuspend`), so the awaiting caller unblocks. Three drop sites in `msActorSend` / teardown now fail the reply before discarding the message: (1) stale/reused pid (`msActorFromPid → NULL`), (2) dead-actor send guard (`!alive`), (3) `msActorDestroyWithReason` mailbox drain (a CALL enqueued just before reap). SEND (`replyFuture == NULL`) is untouched — the fail branch is skipped, so fire-and-forget to a dead actor stays a clean no-op. Precedent: Erlang `gen\_server:call` to a dead process returns `{noproc}` immediately (never blocks); Pony has no sync CALL, so its async half is unaffected. Read-side policy is the existing uniform failed-future behavior: a CALL awaited \*\*inside a `try`\*\* throws (catchable noproc); awaited without a handler yields the `zeroValueForType` fallback — unchanged by I20, a separate no-handler-policy question.



\*\*R3. CD treats suspended actors as rooted.\*\* (Shipped — Phase 5)

Cycle detection excludes `MS\_ACTOR\_SUSPENDED` actors from dead-cycle candidates. Precedent: Pony ORCA treats actors with pending behaviors as live roots.



\*\*R5. Link/monitor signal deferral.\*\* (Already works)

Exit signals queue in mailbox normally, processed after resume. Precedent: Erlang EXIT signal queuing.



\*\*Dropped rules (not backed by Swift/Erlang/Pony):\*\*

\- \~\~R2 (ancestor CALL prevention)\~\~: Erlang uses timeouts for deadlock (not ancestor tracking). Pony bans sync calls entirely. Swift has no runtime deadlock detection. The ancestor-list technique is from database systems, not actor systems.

\- \~\~R4 (idle timer pause)\~\~: Implementation detail, not a safety rule. Erlang has no "pause during operation" concept. Pony has no idle timers.



\### 7.5 Interaction with actor stop / restart



If a supervisor decides to restart actor A while A is suspended:



1\. Supervisor calls `stop(A, Normal)` → runtime sets A's stop flag (R1).

2\. Runtime checks A's AwaitGroup: if present, calls `msAwaitGroupCancel(g)`.

3\. Cancel propagates to all in-flight spawn children: they hit their next safe point, see the cancellation token, unwind, and free their captured borrows.

4\. Last child to finish calls `msAwaitGroupResumeActor(g)`, which sees the stop flag, enters the unwinding path instead of normal resume.

5\. Actor's method exception-unwinds, `onTerminate` runs, supervisor restarts or removes.



All of this happens without the scheduler thread ever being blocked. Total wall time is bounded by the cancellation latency of the spawn children (which should be short — they check cancellation at every backedge and await point).



\### 7.6 Sendable rules unchanged



PARALOCK does \*\*not\*\* change how actor SEND/CALL arguments are checked. Those still go through the existing Sendable checker (`isTypeSendable`, COPY/MOVE/SHARE rules). The new rules above only apply to \*\*spawn children inside actor methods\*\*, which are a different category than cross-actor messages.

\*\*Amendment I (2026-09-03) refashions this boundary.\*\* SHARE is no longer "any const ref": the boundary speaks COPY / MOVE / BORROW / SHARE — SHARE is `Arc<T>`-only (sendable pointee, atomic incref at the msgSetter), a plain const-ref whose sender does not park on a reply (SEND-class: void method or discarded result) is a checker error, and an awaited CALL's const ref is classified as the BORROW it mechanically is (sender parked). Trigger and rules: Amendment I (deterministic SEND use-after-free, measured 2026-09-03).



\---



\## 8. Invariants



The design is sound iff the following invariants hold at all times.



| ID | Invariant | Enforced by |

|---|---|---|

| I1 | An affine `Promise<T>` (spawn-origin) is consumed exactly once | Affine checker (§5.2) |

| I2 | An affine `Promise<T>` never escapes its creating scope | Escape checker (R3) |

| I3 | A spawn closure's borrows outlive the awaiting scope | Borrow checker |

| I4 | A spawn closure inside an actor method does not capture `this` | Static rule S1 |

| I5 | A spawn closure inside an actor method does not mutate captured fields | Static rule S3 |

| I6 | Between spawn and await, borrowed fields are not mutated in the parent | Static rule S4 |

| I7 | A spawn task cannot CALL an ancestor actor | Runtime check R2 |

| I8 | A suspended actor is treated as a live GC root by CD | Runtime rule R3 |

| I9 | A suspended actor can be stopped within bounded time; a CALL to a dead / stale / stopping actor never hangs (its reply future fails with `{noproc}`) | Out-of-band flag R1 + cancellation tokens + Amendment I20 (reply-fail at all CALL drop sites) |

| I10 | Worker pool cannot deadlock through nested spawn | Help-first scheduling (§9.5) |

| I11 | `await` lowering picks a single unambiguous intrinsic for each call site | Checker context annotation |

| I12 | Promise semantics unchanged outside spawn-related code | Backward compat guarantee |

| I13 | Every AST node's `nodeType` is the expression's result type, never a sizeof-hint or transform-to-codegen side channel | Transform rules + codegen reads T via `awaitedType` / `args\[N].nodeType` only |

| I14 | Every `Promise<T>` reachable by `Promise.all` has a matching `MS\_PROMISE\_ALL\_FOR(...)` emitted in the same translation unit | Promise.all call-site intercept (`expressions.ms`) → `ensurePromiseAllInstance` (`types.ms`), which returns the exact dispatch symbol and emits the instance + array typedef in the referencing TU |

| I15 | Cross-thread completion drains via `msFutureFireCallbacks` on the dispatcher thread | Amendment A Step 1/Step 2 + `msCompletionQueueDrain`; actor CALL replies included since 2026-08-31 — `msMsgComplete*` store value+finished (Step 1, blocked waiters may read immediately) then route the callback volley via `msMsgReplyDispatch`/`msCompletionQueuePushOwned` (Step 2); inline fire on an actor-processing worker was a UAF (SAN lane 409/411) |

| I16 | A future completed by another thread is kept alive by a reference acquired before visibility (acquire-before-visible) | Amendment G: submit-time incref in `msSpawn`/`msSpawnInto`/`msAwaitGroupSetDoneFut` — and, since 2026-08-31, `msActorSend` for CALL reply futures (placed after the I20 guards, which fail replies that never acquired a ref). Windows flipped to `MS_FUTURE_SUBMIT_REF=1` the same day: the IOCP became process-global (worker posts), so the post-time incref raced the owner's decref on the non-atomic rc — the exact condition this amendment exists to prevent. Fail sites pair with `msMsgReplyFail` (fail + deferred release through the queue, Amendment H) |

| I17 | A `Promise<T>` whose lifetime spans a cross-thread completion has its owner-side decref deferred to the dispatcher via batched TLS flush — not inline | Amendment H: `msFutureDeferredRelease` + TLS ring buffer + batch-boundary flush |

| I18 | An actor shell is torn down and freed only by its owning scheduler — at a visit's reap gate (`processing` held, popped off the run queue, suspension clear) or the owner's reap scan. `stop()` only marks and wakes; the suspended lane's resume callback opens the gate with its last shell access (`suspendedFut = NULL` release) | Amendment I18: `msActorStop` / `msActorProcess` reap gate / `msActorPollLocal` reap scan / `msActorResumeFromFut` |

| I19 | No thread dereferences an actor shell except (a) via a generation-validated, hazard-pinned `msActorFromPid` lookup whose pin ends with the enclosing runtime call, (b) as the visited shell under `processing`, or (c) as the owner at teardown. Persistent cross-actor edges (links, monitors, mutedBy, CD refs, name registry) store pids only; shell free is deferred while hazard-pinned | Amendment I19: pid table + hazard slots in `msActorFromPid` / hazard-checked free + deferred-free drain in reap scan / pid migration of links, monitors, mutedBy, refs, name registry |

| I21 | A message crossing an actor boundary carries a COPY, a MOVE, a BORROW (raw pointer whose lender provably outlives the use — spawn env, awaited CALL), or an atomic-rc SHARE (`Arc<T>` with sendable pointee, incref at the msgSetter, release after the method runs). A raw refcounted pointer with no liveness proof crossing via a SEND-class invocation is a bug | Amendment I: `checkActorArgSendable` pointee + SEND-class rules + `actorLower` msgSetter boundary incref |

| I22 | Shared mutable state exists only as a `Locked<T>` cell — one allocation (atomic-rc header + inline ticket lock + typed payload), payload touched only inside `update`/`read` closures, egress value sendable. A second refcount wrapper around it (`Arc<Locked<T>>`) or a cross-thread rc op on a bare Locker handle is a bug | Amendment I: opaque `Locked` type in the checker + fused runtime cell |



Violating any invariant means either (a) we've introduced a soundness hole and the design is broken, or (b) the check that was supposed to enforce it is buggy. Every bug report must be triaged against this list first.



\---



\## 9. Edge Case Catalog



Every concrete scenario we've stress-tested, grouped by theme. Each entry specifies the \*\*expected behavior\*\* and \*\*who enforces it\*\*.



\### 9.1 Handle lifetime



| # | Scenario | Behavior | Enforcer |

|---|---|---|---|

| E1 | `spawn(f)` result discarded (`spawn(f);`) | Compile error: handle unused, must `await` or `move`. For fire-and-forget, use actor SEND. | Checker R1 |

| E2 | `const h = spawn(f);` never awaited | Compile error at scope exit. | Checker R1 |

| E3 | `const h = spawn(f);` awaited twice | Compile error on second await: handle already consumed. | Checker R2 |

| E4 | `return spawn(f);` | Compile error: handle escapes scope. | Checker R3 |

| E5 | `struct S { h: Promise<int> }` where `h` is spawn-origin | Compile error: affine Promise cannot be stored in a struct (flags would escape). | Checker R3 |

| E6 | `function foo(h: Promise<int>) { }` called with spawn-origin `Promise<int>` | Flags stripped at parameter boundary (implicit upcast) — callee sees plain Promise; affine tracking ends at call site. Compile error only if parameter is annotated as affine (future extension). | Checker R3 |

| E7 | Handle captured by a closure that outlives scope | Compile error: closure captures non-escapable handle. | Checker R3 |

| E8 | Handle in array partially awaited | Compile error: array of handles is consumed atomically. | Checker R4 |

| E9 | Handle in tuple partially destructured before await | Compile error: tuple is consumed atomically. | Checker R5 |

| E10 | Handle created in `if` branch, not awaited in `else` | Compile error: not consumed on all paths. | Checker R6 |

| E11 | Handle created in loop iteration, collected into array | OK — array is affine, must be awaited after loop. | Checker R4 |

| E12 | Explicit upcast `const p: Promise<int> = h as Promise<int>;` | OK — strips affine guarantees, proceeds as Promise. Lint warns that borrows are no longer protected. | Checker R3 exception |



\### 9.2 Capture and borrowing



| # | Scenario | Behavior | Enforcer |

|---|---|---|---|

| E20 | Capture `const x: Data` (immutable local) | OK — borrow with lifetime ≥ await. | Borrow checker |

| E21 | Capture `let x: Data` (mutable local) | Compile error: cannot capture mutable local in spawn. | Checker |

| E22 | Capture `move x` | OK — ownership transferred to the closure. `x` unusable after spawn. | Checker + move analysis |

| E23 | Capture an actor's field `this.f` inside actor method | OK read-only, subject to S3 / S4. | Checker §7.3 |

| E24 | Mutate captured ref inside spawn closure | Compile error: captures are read-only unless moved. | Checker |

| E25 | Closure captures a `Ref<T>` to shared mutable data | Compile error in actor context; allowed in sync context only if no other writers exist (borrow checker). | Checker + borrow checker |

| E26 | Spawn closure inside spawn closure (nested spawn) | OK — inner closure captures inherit from the outer closure's lifetime, which inherits from the top-level await. | Checker |

| E27 | Capturing a Promise into a spawn closure | OK — Promise is not affine; spawn child may await it. | Standard rules |

| E28 | Capturing another affine `Promise<T>` into a spawn closure | Compile error: affine Promise would escape parent scope. | Checker R3 |



\### 9.3 await in odd places



| # | Scenario | Behavior | Enforcer |

|---|---|---|---|

| E40 | `for (const x of xs) { await spawn(() => f(x)); }` (sequential, JS footgun) | Type-correct but lint warns: "sequential await on spawn in loop, did you mean to collect handles first?" | Lint |

| E41 | `const hs = xs.map(x => spawn(() => f(x))); const rs = await hs;` | OK — idiomatic parallel map. | Checker |

| E42 | `await spawn(() => f());` single spawn | OK — AwaitGroup of size 1. | Transform |

| E43 | `const g = \[spawn(() => f()), fetchData()]; await g;` (mixed origins, same inner T) | OK — both are `Promise<T>`. The affine flag on the spawn element is stripped; array type unifies to plain `Promise<T>\[]`. Compiler emits a lint noting affine tracking dropped. | Checker (implicit upcast) |

| E44 | Empty array: `const hs: Promise<int>\[] = \[]; const rs = await hs;` | OK — AwaitGroup of size 0, returns `\[]` immediately. | Runtime |

| E45 | Await inside `try { … } catch { … } finally { await spawn(() => cleanup()); }` | OK in all branches; finally-block spawn must be awaited before finally exits. | Checker |

| E46 | Await inside `defer { await spawn(() => f()); }` | OK — defer body is its own scope; handle must be consumed before defer returns. | Checker |

| E47 | `await h timeout 0` (immediate) | Runtime: schedules cancellation immediately, awaits cancellation completion. | Runtime |

| E48 | `await h timeout Infinity` | OK — no timeout. Equivalent to plain `await h`. | Transform |

| E49 | Await in a generator body | Allowed in async generators; disallowed in sync generators. | Checker |

| E50 | Conditional await: `const r = cond ? await h1 : await h2;` | OK if both branches are individually well-formed (each branch consumes one handle, the other must be explicitly consumed on the opposite branch). | Checker R6 |



\### 9.4 Actor-specific



| # | Scenario | Behavior | Enforcer |

|---|---|---|---|

| E60 | `spawn` inside actor method, no `this` capture | OK — cooperative suspend on await. | S1 / §7.2 |

| E61 | `spawn(() => doWork(this))` (captures self) | Compile error S1. | Checker §7.3 |

| E62 | `spawn(() => doWork(this.field))` | OK read-only borrow. | S3 |

| E63 | `spawn` child tries to call `actorCall(self.pid, …)` via escape hatch | Runtime error `CallToSuspendedAncestor`. | Runtime R2 |

| E64 | `spawn` child SENDs to parent actor (async, fire-and-forget) | OK — message queues, processed after resume. | Normal mailbox |

| E65 | Supervisor stops actor during suspension | Stop flag set, cancellation propagates, actor unwinds within bounded time. | R1 |

| E66 | Linked actor crashes during suspension | Exit signal queues, processed after resume. | Normal mailbox |

| E67 | CD runs while actor is suspended | Suspended is treated as live root. No false positive. | R3 |

| E68 | Actor's `onIdle` timer fires during suspension | Deferred: timer paused at suspend, resumed with adjusted deadline on resume. | R4 |

| E69 | Parent actor mutates `this.field` between spawn and await | Compile error S4. | Checker §7.3 |

| E70 | Spawn children fan out to sub-actors (sending messages) | OK — each SEND is normal mailbox delivery, no blocking. | Normal mailbox |

| E71 | Spawn child creates a new actor (not a sub-actor of parent) | OK — new actor is independent; its lifetime is managed separately. | Normal actor creation |

| E72 | Two actors both suspended, both waiting on each other's spawn children | If there's no actual ancestor cycle (each is a peer), this is fine — they just wait independently. If one's spawn child calls into the other via CALL, and that CALL needs the suspended target to process → deadlock. | Needs runtime deadlock detection or acceptance |

| E73 | Actor A's method suspends; another actor B sends A a message | Message queues; processed after A resumes. Normal backpressure. | Normal mailbox |

| E74 | Actor A's method suspends; CALL from B to A comes in; B is in async await on the CALL future | OK — B is not blocked, just cooperatively awaiting. When A resumes and processes the CALL, B's future resolves. No deadlock. | Cooperative await |



\*\*E72 needs a deeper note.\*\* Two peer actors cannot create an ancestor cycle (§7.4 R2 only checks ancestors in the \*\*same\*\* spawn tree). If A's spawn child calls B synchronously via blocking `msActorCall`, and B is suspended on its own spawn children which somehow need A's state → classic cross-actor deadlock. \*\*Resolution\*\*: spawn children should prefer SEND over CALL when talking to other actors. CALL from a spawn child to a non-ancestor actor is allowed but documented as potentially blocking. For soundness without performance cost, we accept this as a "developer caution" case rather than adding runtime deadlock detection.



\### 9.5 Pool saturation and nesting



| # | Scenario | Behavior | Enforcer |

|---|---|---|---|

| E80 | All N workers blocked on AwaitGroups, no one to run child tasks | Help-first scheduling: before parking, a worker executes ready children inline. Guarantees forward progress on DAG workloads. | Runtime (new) |

| E81 | Spawn inside spawn inside spawn (3 levels) | OK — each level uses its own AwaitGroup. Help-first ensures no deadlock. | Runtime |

| E82 | 10,000 tiny spawn tasks | Works, but overhead-dominant. Document that spawn has \~microsecond per-task cost; use `.parallel()` (future) for fine-grained data parallelism. | Doc |

| E83 | Very long-running spawn child (no cancellation points) | If cancellation fires (timeout, parent stop), the child cannot be preempted — we wait for it to reach a safe point. Potential unbounded latency. \*\*Mitigation\*\*: compiler inserts cancellation checks at loop backedges and function call sites by default. | Transform (safe-point injection) |

| E84 | Spawn task allocates heavily | OK — spawn tasks can allocate freely; DRC handles cleanup on completion/cancellation. | DRC + cancellation unwinding |

| E85 | Spawn task crashes (exception or panic) | Parent's `await` throws the exception. Other sibling tasks are cancelled. | Runtime |

| E86 | Spawn task infinite loop, parent hits timeout | Timeout fires → cancellation flag set → task checks at next safe point → unwinds → AwaitGroup resolves with timeout error. | Runtime |

| E87 | Actor SEND handler crashes | Logged via the diagnostic bus; supervisor handles restart. | Runtime |



\### 9.6 Cancellation



| # | Scenario | Behavior | Enforcer |

|---|---|---|---|

| E100 | Timeout expires before any child completes | All children cancelled; await returns with timeout error; no results available. | Runtime |

| E101 | Timeout expires after some children complete | Completed results are buffered; pending children cancelled; await returns with partial-result timeout error (caller decides whether to use partial data). | Runtime + API decision |

| E102 | Cancellation during child's cleanup | Cleanup runs to completion regardless; cancellation is cooperative. | Runtime |

| E103 | Nested cancellation (parent cancelled → children cancelled → grandchildren cancelled) | Cascading cancellation via cancellation token tree. Each child's AwaitGroup links to parent's cancellation state. | Runtime |

| E104 | External `AbortSignal` wired to spawn await | Signal.abort() triggers cancellation of the AwaitGroup. Bridge via `await h withSignal sig`. | Future extension |



\### 9.7 Exception / panic / unwind



| # | Scenario | Behavior | Enforcer |

|---|---|---|---|

| E120 | Spawn child throws user exception | Sibling children cancelled; first exception propagates out of `await`. | Runtime |

| E121 | Multiple children throw simultaneously | First reported (or aggregated into `MultiError` — decide per language convention). | Runtime |

| E122 | Exception during cancellation unwind | Logged; original cancellation reason takes precedence. | Runtime |

| E123 | Panic (unrecoverable runtime error) in spawn child | Process-level fatal; not caught by parent. | Runtime |

| E124 | Parent exception between `spawn` and `await` | All still-pending children cancelled; parent's exception unwinds normally; children's handles are dropped during unwind. | DRC + cancellation |



\### 9.8 Memory and DRC



| # | Scenario | Behavior | Enforcer |

|---|---|---|---|

| E140 | Spawn closure captures a Ref<T> counted object | DRC inc on spawn, dec on completion. Standard move semantics apply. | DRC |

| E141 | Spawn closure captures borrowed reference (non-owning) | No DRC op; parent's lifetime guarantees it lives through await. | Borrow checker |

| E142 | AwaitGroup struct ownership | Stack-allocated in parent's frame (sync context) or heap-allocated (actor context, since actor frames can suspend). | Transform |

| E143 | Result slots hold primitive values | Inline in AwaitGroup. | Runtime |

| E144 | Result slots hold boxed values (Ref<T>) | DRC incremented on completion, decremented on parent consume. | Runtime |

| E145 | Suspended actor's continuation size | Equals the saved stack frame at the suspend point — typically a few hundred bytes. Lives in heap until resume. | Runtime |

| E146 | Leak: actor suspended, never resumed (bug) | Detectable via long-lived suspended actor count; diagnostic/tooling only, not a runtime fix. | Observability |



\---



\## 10. Execution Phases



PARALOCK ships in \*\*nine phases\*\*, each independently shippable and testable. Do not skip. Do not combine. Each phase has explicit entry and exit criteria.



\### Phase 0 — Preparation (no code changes) — SHIPPED



\*\*Goal.\*\* Freeze this document, communicate the design, update `docs/LANG-ASYNC.md` to reference PARALOCK, add a `SELFHOST-PARALOCK.md` tracking what works today vs. what PARALOCK lands.



\*\*Deliverables.\*\*

\- `docs/PARALOCK.md` (this file)

\- Reference from `docs/LANG-ASYNC.md` pointing here for the roadmap

\- Reference from `docs/LANG.md` actor section pointing here for spawn-inside-actor



\*\*Exit.\*\* Document reviewed, design locked, phases scheduled.



\---



\### Phase 1 — Affine `Promise<T>` + affine checker (no runtime changes) — SHIPPED



\*\*Goal.\*\* Introduce affine-Promise machinery in the checker. No behavior changes for existing `spawn(() => …)` calls — they continue to return `Promise<T>`, now with flag bits attached.



\*\*Shipped via REPROMISE T2:\*\* Flag-based unification (`TypeFlag.AwaitableAffine` + `TypeFlag.AwaitableScopeBound` on `GenericInstance.typeFlags`). No separate TypeKind — the flagged and unflagged `Promise<T>` are the same `GenericInstance "Promise"` differentiated by bits. Affine tracker in `src/checker/spawnAffinity.ms`. `@awaitable` / `@affineAwaitable` decorator support for stdlib-defined awaitables.



\*\*Exit criteria — met.\*\*

\- All existing spawn-using code compiles unchanged. ✓

\- New affine errors E1–E12 produce actionable diagnostics. ✓

\- `examples/spawnHandleAffine.ms` compiles and demonstrates affine tracking. ✓



\---



\### Phase 2 — `AwaitGroup` primitive + blocking lowering in sync context — SHIPPED



\*\*Goal.\*\* Type-directed `await` dispatch begins: `await <affine Promise>` and `await <affine Promise\[]>` in sync/main context lowers to the new blocking AwaitGroup path, independent of `Promise.all`.



\*\*Shipped deliverables:\*\*

\- `runtime/promise/awaitGroup.h` + `.c` — AwaitGroup with atomic counter, condvar, N result slots.

\- `src/transform/lowering/awaitLower.ms` — fused path (await spawn(fn) → AwaitGroup) and deferred path (await handle → msWaitForReady + typed reader).

\- Typed future readers: `msFutureReadDouble`/`Int32`/`Bool` eliminate unbox wrappers for primitives.

\- `msWaitForReady` — blocking wait without consuming value (enables typed read after wait).

\- Actor message type dispatch: `typeMsgKind` unified classifier, 2-slot array packing (reuses string macros), struct boxing for array returns via `msSinkBoxStruct`.

\- Spawn array boxing: `TypeKind.Array` added to `needsBoxing`/`boxForType` in spawnLower.ms.

\- Async `return await` split: `splitReturnAwait` pre-pass in asyncDesugar.ms.

\- Async array boxing: `makeFutureCompleteStmts` boxes arrays before future completion.

\- Async yield-resume: `msUnboxStruct` wrapping for array/struct types on state machine resume.



\*\*Exit criteria — met.\*\*

\- `examples/spawnParallelSum.ms`: parallel sum, direct `await hs`. ✓

\- `examples/actorArrayParam.ms`: actor with array params + returns. ✓

\- `examples/asyncReturnAwait.ms`: `return await` in async function. ✓

\- All 12 existing examples pass. ✓

\- Self-tests: 2298 pass / 2 fail (baseline unchanged). ✓



\*\*Known issues (pre-existing, not Phase 2):\*\*

\- `waitFor` on actor method returning array — DRC inject creates `undefined` assignment target for `msUnboxStruct` expansion.

\- `Promise.all` inside async function — `walkBridge` crashes on null TryCatchStmt body. (Since resolved: corpus `735-promiseAllTyped` awaits `Promise.all` inside an async `main` and passes c/orc/danger/js, 2026-08-28.)



\---



\### Phase 3 — Cancellation tokens + timeouts — \*\*SHIPPED\*\*



\*\*Surface API.\*\* `spawn(fn, { timeout: N })` — task-level deadline in milliseconds. The timeout is a property of the spawned task, not the await expression. Extensible: future options include `priority`, `name`, etc.



```ms

const result = await spawn(work, { timeout: 500 });

// If work() exceeds 500ms, throws "await timeout".

// Safe-point injection at loop backedges auto-cancels the task.

```



\*\*Deliverables.\*\*



Runtime:

\- `msAwaitGroup` extended with `cancelled` (atomic bool), `deadlineMs` (int64), `timedOut` (bool) fields.

\- `msAwaitGroupBlockingWithDeadline(g, deadlineMs)` — timed condvar wait, sets `cancelled` + `timedOut` on expiry. Platform-aware: `pthread\_cond\_timedwait` (POSIX), `SleepConditionVariableCS` with remainMs (Windows).

\- `msAwaitGroupCancel(g)` — sets cancelled flag for explicit cancellation.

\- `msSpawnCheckCancel(g)` — fast-path atomic load for safe-point checks (\~1ns overhead).

\- `msSpawnCtx.cancelFlag` — pointer to group's cancelled flag, wired in `msSpawnTaskSubmit`.



Transform (`awaitLower.ms`):

\- `getSpawnInfo` extracts closure + timeout from `spawn(fn, { timeout: N })` options object.

\- Fused path emits: `$deadline = msMonoTimeMs() + N`, `msAwaitGroupBlockingWithDeadline($ag, $deadline)`, then `if (msAwaitGroupTimedOut($ag)) { msAwaitGroupFree($ag); throw "await timeout"; }`.

\- Safe-point injection via `cancelSafePoints.ms`: prepends `if (msSpawnCheckCancel(group)) { return; }` at loop backedges (while/doWhile/for/forOf) inside spawn closure bodies. Stops at nested function boundaries.



\*\*Known limitations.\*\*

\- Fused path requires spawnLower closure wrapping — pre-existing Phase 2 gap. E2E blocked until that's fixed.

\- Infinite loop without safe points (e.g., tight FFI call) hangs — documented, lint warning planned.



\---



\### Phase 4 — Async function cooperative path — \*\*SHIPPED (4a)\*\*



\*\*Key discovery.\*\* Single `await spawn(fn)` in async functions already works cooperatively with zero code changes:



1\. `asyncDesugar` converts `await spawn(fn)` → `yield spawn(fn)`

2\. `asyncBridge` stepper evaluates `spawn(fn)` → gets `msFuture\_ptr\*` from `msSpawn`

3\. Stepper checks `msFutureFinished($yf\_N)`, returns it if not finished

4\. `msAsyncCb` calls `msFutureAddCallback($yf\_N, msAsyncCb)` — cooperative, no thread blocked

5\. When spawn worker completes, `msPostCompletion` fires future → `msAsyncCb` resumes stepper



\*\*Phase 4a deliverables (shipped):\*\*

\- Verified E2E: `examples/spawnInAsync.ms` — async function spawns, awaits cooperatively

\- Runtime: added `doneFut` + `completeFn` fields to `msAwaitGroup` for Phase 4b group support

\- `finishSlot` completes `doneFut` when all slots done (bridges AwaitGroup → future callback)



\*\*Phase 4b (pending): async spawn groups.\*\*

\- `const \[a, b] = await Promise.all(\[spawn(f), spawn(g)])` in async context needs AwaitGroup + `doneFut`

\- Transform emits: `$ag.doneFut = msFutureCreate(); $ag.completeFn = msFutureCompleteVoid;` then yields `doneFut`

\- Stepper treats `doneFut` like any other future — registers callback, suspends cooperatively



\---



\### Phase 5 — Actor cooperative suspension (the main event) — \*\*SHIPPED\*\*



\*\*Goal.\*\* `await` inside an actor method cooperatively suspends the actor. Scheduler thread is released; other actors run normally.



\*\*Shipped (actual implementation — differs from the earlier plan text below):\*\*

\- Actor state flag `MS\_ACTOR\_SUSPENDED` (`runtime/actor/actor.h:45`).

\- Suspension storage: `suspendedFut` + `suspendedReplyFut` fields on the actor struct (`actor.h:87-88`).

\- Runtime suspend entry: `msActorSuspend(actor, implFut, replyFut)` (`actor.h:284`) — saves futures, flips flag, registers `msActorResumeFromFut` as the future's completion callback.

\- Runtime resume: `msActorResumeFromFut` (`actor.h:254`) — clears flag, checks `stopRequested` (R1), re-enqueues actor on its scheduler's run queue with targeted wake.

\- Transform: `src/transform/lowering/actorLower.ms:284` emits `msActorSuspend` when `methodFlags === "async\_actor"` (actorLower sets this flag during the pre-async extraction pass at line 948+).

\- Cycle detection (`runtime/actor/cycle.h:27-41`): treats `MS\_ACTOR\_SUSPENDED` actors as rooted (excluded from dead-cycle candidates).



\*\*Design divergence from original plan.\*\* The plan text below mentions `msAwaitGroupActor(self, g)` and a separate `ExecContext` enum in the checker. The shipped implementation uses a simpler mechanism: the parser sets `methodFlags = "async\_actor"` on actor methods that contain `await`, and `actorLower` emits `msActorSuspend` directly — no new await-intrinsic, no `ExecContext` enum. The result is the same user-visible behavior (actor suspends, scheduler freed, resumes on completion) with less machinery.



\*\*Out of scope.\*\* Safety rules S1–S5 (next phase — only R1 shipped to date). Ancestor CALL check (dropped).



\*\*Exit criteria — met.\*\*

\- `examples/actorSpawnBasic.ms` exists and runs to completion.

\- Cycle detection correctly treats suspended actors as live roots.



\*\*Original plan (historical reference — not the shipped design):\*\*

\- \~\~New intrinsic: `msAwaitGroupActor(self, g)`\~\~

\- \~\~New intrinsic: `msAwaitGroupResumeActor(g)`\~\~

\- \~\~`awaitLower` in `ActorMethod` context emits `msAwaitGroupActor`\~\~



\---



\### Phase 6 — Actor safety rules (static + runtime) — \*\*SHIPPED\*\*



\*\*Shipped:\*\* Runtime R1 out-of-band stop (`stopRequested` atomic on actor struct; `msActorStop` sets it; `msActorResumeFromFut` checks and fails reply future on stopped-while-suspended).



\*\*Shipped 2026-07-22 (Amendment I4/I5):\*\* Static rules S1 + S3 enforced in the checker — see the §7.3 amendment note for semantics, enforcement point, and known v1 limits. Coverage: `src/test/c/actor.ms` (compile-level negative/positive tests for S1/E61, S3/E62 incl. deep writes, and E40); `examples/actorSpawnSafety.ms` (runnable positive case + commented negative recipes).



\*\*Goal.\*\* Lock down Phase 5 with compile-time and runtime safety. After Phase 6, unsafe patterns are errors — never silent corruption.



\*\*Scope (filtered to Swift/Erlang/Pony-backed rules only).\*\*

\- Static rule S1: `src/checker/spawnAffinity.ms` — reject `this` as a capture in the thunk passed to `spawn(...)` inside actor methods. (Swift `@Sendable` + Pony `recover`)

\- Static rule S3: mark all `this.field` captures as `const`; reject mutation inside spawn thunks. (Swift `nonisolated let` + Pony `box`)

\- Runtime R1: out-of-band stop flag on actor struct. `msActorStop` sets flag; `msActorResumeFromFut` checks flag before resume. (Erlang OTP supervisor + Pony ORCA)



\*\*Out of scope.\*\* Help-first scheduling, ancestor-list deadlock detection (R2), frozen-window borrow checking (S4/S5).



\*\*Exit criteria.\*\*

\- `examples/actorSpawnSafety.ms` (new): S1 and S3 negative cases produce compile errors; positive cases run.

\- Runtime stop test: supervisor stops suspended actor, actor unwinds cleanly.



\---



\### Phase 7 — `detach` primitive — \*\*REMOVED\*\*



`detach` was removed. Actor SEND covers all fire-and-forget use cases with isolation, supervision, and backpressure — making a separate unstructured primitive unnecessary.



\---



\### Phase 8 — Help-first scheduling for nested spawn — \*\*SHIPPED\*\*



\*\*Goal.\*\* Prevent pool saturation deadlock when deeply nested spawns exceed the worker count.



\*\*Implementation.\*\* Global-queue help-first (simplified from the original per-worker deque design).

Before parking on a condvar or polling the event loop, blocked workers call `msPoolHelpOne()` to

dequeue and execute one task inline from the global queue. Three blocking points patched:

\- `msAwaitGroupBlocking` (awaitGroup.c) — group-based blocking wait

\- `msAwaitGroupBlockingWithDeadline` (awaitGroup.c) — deadline variant

\- `msWaitForReady` (dispatch.c) — individual future await



Lock ordering: group mutex is dropped before `msPoolHelpOne` acquires pool mutex internally.

No per-worker deques — same deadlock prevention with \~30 LOC vs \~300+. Per-worker deques

remain a future optimization if global-queue contention becomes measurable.



Invariant: spawn task graphs must be DAGs (no cycles). Cyclic dependencies between spawn tasks

are a programmer error — not detected by runtime.



\*\*Out of scope.\*\* Full work-stealing for actors (already exist via runqueue-per-scheduler). Cross-pool stealing (no second pool exists).



\*\*Exit criteria.\*\* Met:

\- `examples/spawnNestedDeep.ms`: 5-level nested spawn with 4-way fan-out (1024 leaf tasks). Completes without deadlock.



\---



\### Phase 9 — Diagnostics, lints, and documentation polish — \*\*SHIPPED\*\*



\*\*Goal.\*\* Close the loop on developer experience.



\*\*Shipped.\*\*

\- LSP hover: spawn-origin `Promise<T>` bindings show an affine hint ("Promise (affine, scope-bound) — from spawn(), must be awaited before scope exits") in hover documentation (`src/checker/suggest.ms:570`).

\- Lint E3 (handle reuse inside loop body): `checkPass.ms:130` catches the pattern "a spawn-origin Promise is consumed inside a loop body; iteration N+1 would reuse an already-awaited handle". Note this is E3 (reuse), NOT E40 (sequential anti-pattern).

\- `docs/LANG.md` modernized: spawn section explains the unified `Promise<T>` surface with affine flags.

\- `docs/LANG-ASYNC.md` updated with affine rules on spawn-origin Promises and spawn-inside-actor section.

\- `docs/PARALOCK.md` (this file) rewritten to present the single-surface-type design.



\*\*Shipped 2026-07-22 (Amendment I4/I5).\*\*

\- Lint E40: warning on direct `await spawn(...)` inside any loop body (while/for/for-of/for-in/do-while), emitted next to the E3 loop-reuse check after the body is checked (needs resolvedSym). The walk stops at closure boundaries and nested loops. Suggested fix: "collect handles first, then `await Promise.all(handles)` after the loop" — Promise.all, not array-await, because the §4.2 array-await surface is designed-unimplemented (§7.3 amendment note).



\---



\## 11. File Inventory



Concrete files created or modified per phase. Use this as a map when starting implementation.



\### New files



| File | Phase | Purpose |

|---|---|---|

| `src/checker/spawnAffinity.ms` | 1 | Affine consumption tracking for spawn-origin `Promise<T>` (flagged via `AwaitableAffine` + `AwaitableScopeBound`) |

| `src/transform/lowering/awaitLower.ms` | 2 | Type-directed dispatch for `await` expressions |

| `src/transform/lowering/cancelSafePoints.ms` | 3 | Insert cancellation check calls into spawn task bodies |

| `runtime/promise/awaitgroup.h` | 2 | `AwaitGroup` struct and intrinsics |

| `runtime/promise/awaitgroup.c` | 2 | Implementation (futex/condvar platforms) |

| `examples/spawnHandleAffine.ms` | 1 | Phase 1 demonstration + negative tests |

| `examples/spawnParallelSum.ms` | 2 | Phase 2 baseline |

| `examples/spawnTimeout.ms` | 3 | Phase 3 cancellation |

| `examples/spawnInAsync.ms` | 4 | Phase 4 async cooperative |

| `examples/actorSpawnBasic.ms` | 5 | Phase 5 actor cooperative |

| `examples/actorSpawnSafety.ms` | 6 | Phase 6 safety enforcement |

| \~\~`examples/detachBackgroundWork.ms`\~\~ | 7 | Removed — actor SEND replaces detach |

| `examples/spawnNestedDeep.ms` | 8 | Phase 8 nested deadlock prevention |



\### Modified files



| File | Phase | Change |

|---|---|---|

| `src/checker/types.ms` | 1 | Add `AwaitableAffine` + `AwaitableScopeBound` flags (REPROMISE T2), `isAffineAwaitable(t)` semantic query — no separate TypeKind |

| `src/checker/checkExprPass.ms` | 1, 6 | Type `spawn` expressions; apply actor safety rules S1–S5 |

| `src/checker/symbol.ms` | 1 | Affine tracking state on `Symbol` |

| \~\~`src/lexer/token.ms`\~\~ | 7 | Removed — no detach keyword |

| `src/parser/expressions/` | 3 | Parse `await … timeout N` (spawn and detach are ordinary calls, no parser changes) |

| `src/transform/index.ms` | 2–8 | Register new passes in pipeline |

| `runtime/promise/pool.c` | 2, 8 | Add AwaitGroup dispatch lane; per-worker deques for help-first |

| `runtime/promise/dispatch.c` | 2, 4 | Wire AwaitGroup into dispatch |

| `runtime/actor/actor.h` | 5, 6 | `msActorStateSuspended`, out-of-band stop flag, ancestor list on spawn tasks |

| `runtime/actor/cycle.h` | 5 | Treat suspended as rooted in CD scan |

| `docs/LANG-ASYNC.md` | 0, 9 | Reference PARALOCK; update status table |

| `docs/LANG.md` | 0, 9 | Actor section: spawn-inside-actor subsection |



\---



\## 12. Test Matrix



Every phase ships with a \*\*regression test suite\*\* that must pass before merging that phase. Tests accumulate — Phase 5 must pass tests from Phases 1–4 plus its own.



| Category | Phase | Test types |

|---|---|---|

| Affine checker | 1 | Positive (E11, E41, E42), negative (E1–E10) |

| Dispatch lowering | 2 | Single spawn, array, tuple, timing comparison vs Promise.all |

| Cancellation | 3 | Timeout, multi-child cancellation, cleanup-during-cancel |

| Async cooperative | 4 | Interleaving with other async tasks, worker utilization |

| Actor cooperative | 5 | Basic suspend/resume, CD interaction, idle timer handling |

| Actor safety | 6 | All of E60–E74 |

| \~\~Detach\~\~ | 7 | Removed — actor SEND replaces detach |

| Help-first scheduling | 8 | Nested spawn, saturation, DAG workloads |

| End-to-end | 9 | All examples run in CI; LSP checks; doc examples verified |



Each phase also runs the \*\*full existing test suite\*\* to catch regressions in Promise/actor semantics.



\---



\## 13. Success Metrics



How we know PARALOCK actually delivered value.



| Metric | Target | Measured how |

|---|---|---|

| Zero-copy parallel fan-out inside actor (E1 scenario from §7.1) | Measured speedup ≥ 2× over 2-way single-threaded; ≥ 3× over 4-way | New benchmark `bench/actorSpawnFanout.ms` |

| No regressions in existing spawn() / Promise.all() workloads | ≤ 5% throughput delta vs. pre-PARALOCK baseline | Existing benchmarks |

| Compile error quality | Every E-case in §9 has a diagnostic that names the rule + suggests a fix | Manual review + snapshot tests |

| Safety bug count post-ship | 0 known soundness holes in the invariant list §8 | Audit checklist |

| Code added to compiler | ≤ 1500 LOC .ms (checker + transforms) | `wc -l` on new files |

| Code added to runtime | ≤ 500 LOC .c/.h (AwaitGroup + actor state extension + help-first) | `wc -l` on new files |



\---



\## 14. Deferred / Out of Scope



Explicitly not part of PARALOCK. Do not let scope creep eat these in.



\- \*\*`.parallel()` iterators\*\* (data parallelism, Rayon-style). Separate initiative. Planned, not PARALOCK.

\- \*\*Cross-actor ownership transfer via spawn handles.\*\* Handles remain strictly scope-local.

\- \*\*Distributed spawn\*\* (across machines). Single-node only.

\- \*\*Auto-move on last use\*\* at actor boundaries. Considered and shelved; may revisit after real-world usage data.

\- \*\*Effect typing\*\* (colored functions). We explicitly avoid async coloring — context detection is internal to the compiler.

\- \*\*Cyclic spawn dependency detection.\*\* If a user writes cyclic waits, it's a bug — we don't detect it. DAG assumption documented.

\- \*\*External `AbortSignal` bridge for spawn.\*\* Can be added later as a thin adapter over `msAwaitGroupCancel`.

\- \*\*Work stealing across the actor scheduler and spawn dispatch.\*\* Already unified via the shared pool — no additional mechanism needed.

\- \*\*Actor reentrancy during suspension.\*\* Swift allows an actor to process other messages while one method is suspended on an async call. We explicitly \*\*do not\*\* — during spawn suspension, the actor is frozen. This preserves the zero-copy borrowing guarantee at the cost of reentrancy.



\---



\## 15. Open Questions (Non-Blocking)



Resolve during or after implementation; none block starting Phase 1.



1\. \*\*Multi-error aggregation on spawn failures.\*\* Should `await` throw the first exception or a `MultiError` containing all? Decision deferred to Phase 3.

2\. \*\*Partial results on timeout.\*\* API shape for "some children completed, others timed out" — record + flag, or discard all? Deferred to Phase 3.

3\. \*\*`spawn` with user-defined executor.\*\* Currently all spawn goes to the default pool. Custom executors (e.g., for I/O-heavy vs CPU-heavy separation) — maybe later, not PARALOCK.

4\. \*\*Stack size for spawn tasks.\*\* Use the default thread stack (large) or a smaller allocated stack? Affects how many concurrent spawn tasks we can host. Phase 2 ships with default; tune in Phase 9.

5\. \*\*Diagnostic phrasing.\*\* Final error messages will be iterated during Phase 9 based on real feedback.



\---



\## 16. Amendment Process



Changes to this document require:



1\. A named amendment section appended at the end (`## Amendment A — <title>`).

2\. Rationale, affected invariants, and an impact assessment on shipped phases.

3\. If the amendment changes an invariant, all downstream phases that relied on it must be re-verified.



Do not edit sections 1–15 after lock. They are the reference.



\---



\## 17. Glossary



\- \*\*AwaitGroup\*\* — runtime struct coordinating N spawn tasks waiting on a single `await`.

\- \*\*Affine type\*\* — a value that must be consumed exactly once. A `Promise<T>` with the `AwaitableAffine` flag set (spawn-origin) is affine.

\- \*\*Context\*\* — the execution environment of a function: `Sync`, `Async`, or `ActorMethod`. Determines `await` lowering.

\- \*\*Cooperative suspension\*\* — releasing a scheduler thread by saving continuation off-thread, as opposed to blocking the thread via futex.

\- \*\*Help-first scheduling\*\* — a worker that is about to park on an AwaitGroup first runs any ready tasks (from its own deque or stolen) inline, then parks only if no work is available.

\- \*\*Affine Promise\*\* — a `Promise<T>` with `AwaitableAffine` + `AwaitableScopeBound` flags set. Produced by `spawn(thunk)` and `@affineAwaitable`-annotated stdlib types. Subject to R1-R6 consumption rules.

\- \*\*Spawn tree\*\* — the runtime ancestry chain of an actor and its nested spawn tasks, used for ancestor CALL check (R2).

\- \*\*Out-of-band stop\*\* — actor stop mechanism that bypasses the mailbox, using a flag on the actor struct. Required for stopping suspended actors.

\- \*\*Ancestor actor\*\* — any actor whose method is currently suspended on a spawn tree that contains the caller.

\- \*\*Cancellation token\*\* — atomic flag on an AwaitGroup that spawn tasks check at safe points to unwind early.

\- \*\*Safe point\*\* — a program location (loop backedge, function call, await point) where a spawn task is permitted to check for cancellation and unwind.



\---



\## Amendment A — Layer 2 Cross-Thread Completion Contract (2026-05-21)



\### Context



Section 6 and §4.1 mention briefly that workers post completion via "completion pipe (POSIX) / IOCP (Windows)" but the implementation contract — \*which API to call on the drain side\* — was implicit in code comments only (`runtime/promise/thread.h:99-103`). This led to a divergence between POSIX and Windows paths in `dispatchFull.c`: POSIX correctly used `msFutureFireCallbacks` (just fire) while Windows incorrectly used `msFutureComplete` / `msFutureFail` (which include a `finished-guard` and skip callback firing when the future is already marked finished by the worker). The result: async steppers awaiting spawn-origin futures hung indefinitely on Windows whenever the cross-thread completion path was exercised.



\### The Contract (now explicit)



Cross-thread completion has \*\*two strict steps\*\*:



\*\*Step 1 — Worker side\*\* (runs on pool worker thread, see `runtime/promise/thread.h:99-132`):

1\. Set the future's value field directly on the future struct.

2\. Set `finished = true` atomically (memory\_order\_release).

3\. Call `msNotifyFutureComplete()` to wake any blocking waiter on the global futures condvar.

4\. Push a completion signal to the cross-thread routing channel:

&#x20;  - \*\*POSIX\*\*: `msCompletionQueuePush(fut, isFail, error)` — pushes to global MPSC + writes 1 byte to global wake pipe.

&#x20;  - \*\*Windows\*\*: `msPostCompletion(fut, NULL, isFail, error)` — `PostQueuedCompletionStatus` to dispatcher's IOCP.



\*\*Step 2 — Main/Dispatcher side\*\* (drains the channel during `msRunOnce`):

1\. Read pending completion signals from the channel.

2\. \*\*Fire callbacks ONLY\*\* via `msFutureFireCallbacks((msFutureBase\*)fut)`.



\### Critical API Rule



The drain side \*\*MUST NOT\*\* call `msFutureComplete` or `msFutureFail`. Both contain a `finished-guard`:



```c

if (atomic\_load\_explicit(\&f->finished, memory\_order\_acquire)) return;

```



Since the worker already set `finished = true` in Step 1, the guard triggers and the function returns \*\*without firing callbacks\*\*. This silently breaks all async steppers awaiting the future.



The drain side \*\*MUST\*\* use `msFutureFireCallbacks` — it has no guard and simply fires the registered callback chain.



\### Per-Platform Implementation



| Platform | Channel | Drain location | Correct API |

|---|---|---|---|

| POSIX (macOS, Linux selector) | global wake pipe + global MPSC queue | `msCompletionQueueDrain` (`dispatchFull.c:258`) | `msFutureFireCallbacks` ✓ |

| Windows IOCP | per-thread `gDispatcher->iocp` | `msRunOnce` Windows branch (`dispatchFull.c:427`) | `msFutureFireCallbacks` (fixed 2026-05-21) |



\### Invariant I15 (new)



I15: Layer 2 cross-thread completion drain MUST call `msFutureFireCallbacks` on completed futures. Calls to `msFutureComplete` / `msFutureFail` from the drain path are a bug.



\### Affected Invariants



\- \*\*I12 (Promise semantics unchanged outside spawn-related code)\*\* — confirmed; this amendment clarifies an existing contract, not changing user-facing behavior.



\### Impact Assessment on Shipped Phases



\- Phases 0-2: no impact (no cross-thread spawn completion in those tests).

\- Phase 4a (async cooperative spawn): bug \*\*was\*\* present on Windows, masked by the rarity of Windows runs in CI. macOS path was correct.

\- Phases 5-8: no impact (actor mailbox is a separate channel, not affected).



\### Rationale for the Amendment



The Layer 2 channel mechanism was specified informally in `LANG-ASYNC.md:49` ("Cross-thread: completion pipe (POSIX) / IOCP (Windows) posts to event loop") but the \*Step 1 / Step 2 split\* and the \*exact drain API\* were left implicit. New backend implementers (or refactors) had no doc-level guard rail and could re-introduce the same bug. This amendment lifts the contract from code comments into the locked design document.



\---



\## Amendment B — Targeted Cross-Thread Scheduler Wake (2026-06-08)



\### Context



§6 models an idle scheduler thread as parking on the pool condvar, where a cross-thread

actor send wakes it via `msPoolWakeWorker` — a targeted condvar signal (the §7.2 resume

path's "targeted wake"). The std/http async serve loop (`driveWithSweep`) realizes the

abstract "event loop" of §6.5 by running an I/O reactor \*\*on\*\* a scheduler thread: that

thread parks in its I/O engine poll (`msIoEnginePoll` — kqueue / epoll / io\_uring / IOCP),

\*\*not\*\* the pool condvar. A condvar signal is invisible to a thread blocked in that poll, so a cross-thread

actor send to such a scheduler was not delivered until the serve loop's periodic

`DRIVER\_POLL\_MS` poll happened to leave the selector and drain the mailbox — a latency tax

(up to `DRIVER\_POLL\_MS` per cross-thread hop) plus idle-CPU cost that the busy-poll exists

solely to mask.



Proven by probe on the real engine path: a `msPoolWakeWorker` (condvar) against a thread in

`msIoEnginePoll` blocks the full timeout (\~800 ms in the probe); an engine wake returns in

\~one scheduling quantum (\~150 ms) — verified on kqueue (macOS) and on io\_uring (Linux 6.8).



\### The Contract (now explicit)



A cross-thread actor send to scheduler K MUST wake K regardless of which primitive K is

parked on:

\- parked on the pool condvar (idle pool worker) → condvar signal (unchanged), \*\*or\*\*

\- blocked in its I/O engine poll (running a serve loop) → a targeted, self-clearing engine wake.



The wake is \*\*targeted\*\* (reaches only scheduler K), preserving the §7.2 "targeted wake"

intent. It is \*\*not\*\* the broadcast Layer-2 completion channel of Amendment A: spawn

completions are any-thread-drainable (broadcast is correct), but an actor send addresses one

specific scheduler — broadcasting it would wake every serve loop (an N² wake storm under

fan-out).



\### Mechanism



A per-scheduler \*\*engine wake\*\* — a method on the I/O engine abstraction (`msIoEngineWake`),

implemented per backend, self-clearing so it needs no fd drain and cannot busy-loop a

level-triggered poll. It lives at the \*\*engine\*\* layer, not the selector, because a serve loop

blocks in `msIoEnginePoll` whose wait primitive is backend-specific — only the readiness

backends have a selector at all; io\_uring and IOCP do not:



| Backend | Wake primitive |

|---|---|

| readiness · kqueue (macOS/BSD) | `EVFILT\_USER` + `NOTE\_TRIGGER` (`EV\_CLEAR` auto-resets) |

| readiness · epoll (`-DMS\_USE\_EPOLL`) | `eventfd` registered in the selector |

| io\_uring (Linux default) | `eventfd` + a re-armed `IORING\_OP\_POLL\_ADD` — a ring-less `write()` breaks `io\_uring\_enter`. (MSG\_RING would require the waker to own a ring; the waker is any sending scheduler, so the eventfd is the robust choice — verified on Linux 6.8.) |

| IOCP (Windows) | `PostQueuedCompletionStatus` |



`msIoEngineWake(e)` triggers it; the engine's poll consumes + re-arms the wake event without

reporting it as a completion (the serve loop then drains actor mailboxes via `msRunOnce`). Each

serve thread registers its \*\*engine\*\* as its scheduler's wake target when it wires up

(`msIoEngineAddWakeFd` → `msSchedWakeRegister(sid, engine)`). `msPoolWakeWorker(sid)` keeps the

condvar signal \*\*and\*\* triggers scheduler `sid`'s engine wake (`msIoEngineWake`). On the

readiness backends the engine wake simply calls `msSelectorWake(e->selector)`.



\### Affected Invariants



\- I1–I14: untouched (no type-system, handle-lifecycle, or `nodeType` change).

\- I15 (Amendment A completion-drain contract): untouched — the Layer-2 completion channel

&#x20; (MPSC + global wake pipe → `msFutureFireCallbacks`) is unchanged; this adds a \*\*separate\*\*,

&#x20; targeted channel for actor sends.

\- New \*\*I16\*\*: a cross-thread actor send to a scheduler MUST wake it whether it is parked on

&#x20; the pool condvar or blocked in its I/O engine poll. A wake that reaches only one of the two

&#x20; primitives is a bug. The engine wake is an engine-abstraction method (`msIoEngineWake`), so it

&#x20; must cover \*\*every\*\* backend (readiness selector, io\_uring, IOCP) — a backend whose arm is a

&#x20; no-op silently regresses to the `DRIVER\_POLL\_MS` latency tax on that platform.



\### Impact Assessment on Shipped Phases



\- Phases 0–4 (spawn / await / async): no impact — those paths park on the futex or the

&#x20; Layer-2 completion channel, not `msPoolWakeWorker`.

\- Phases 5–8 (actor): behavior preserved, latency improved — actor delivery to a serve-loop

&#x20; scheduler becomes immediate instead of `DRIVER\_POLL\_MS`-quantized. No change to mailbox

&#x20; semantics, suspension, or ordering (`scheduled` / `processing` CAS guards unchanged).

\- Unblocks removing the `DRIVER\_POLL\_MS` busy-poll once the targeted wake demonstrably covers

&#x20; every cross-thread actor wake path (verified separately).



\### Road Not Taken



Decoupling the I/O reactor from the actor schedulers entirely — a dedicated reactor thread that

translates I/O readiness into actor messages, leaving scheduler threads to run only actors and

park on the condvar (so the gap could not exist) — was considered and rejected for std/http's

I/O-first, per-core-reactor (`SO\_REUSEPORT`) design: it would add a cross-thread hop to every

I/O event (the hot path) to avoid a rare cross-thread actor wake. Revisit only if std/http

moves to an actor-first model.



\### Rationale



The wake gap was masked, not fixed, by the periodic poll. A targeted engine wake closes it at

the one boundary where the I/O reactor and the actor scheduler share a thread — the place §6

left the wait primitive implicit — without abandoning the per-core-reactor design or touching

any locked semantics.



\---



\## Amendment C — Actor scheduling: wasEmpty gate + markEmpty-last (2026-06-20)



\### Trigger



A rare hang in the actor scheduler (surfaced by `paralock-nested` under work-stealing,

deterministic under ThreadSanitizer). Root cause, proven by instrumentation: an actor reaches

the state `{ scheduled = true, off every run queue, mailbox non-empty, processing = false }` —

\*\*stranded\*\*. Mechanism: the deschedule path re-enqueued the actor (or a sender's push observed

`scheduled = false` mid-deschedule) \*\*while a thread still held `processing`\*\*; a second thread

popped it, failed the processing CAS, and \*\*dropped\*\* it (returned 0, caller discarded) → the

message was never processed → a waiting actor-CALL future never completed. Work-stealing is the

trigger (disabling it removes the hang); GC-independent (reproduces under `--gc=drc`); not a

run-queue ABA.



\### Change (supersedes the "`scheduled` / `processing` CAS guards unchanged" clause of Amendment B's Impact Assessment)



The send-side scheduling gate and the process-side deschedule are brought to the Pony messageq

model, \*\*keeping\*\* the `processing` CAS (which Pony lacks — see below):



1\. \*\*`msActorSend`\*\* schedules iff `msMpscPush` returns `wasEmpty` (the empty→non-empty edge),

&#x20;  not via a `scheduled` CAS. `wasEmpty` is atomic with the consumer's `markEmpty`, so exactly

&#x20;  one party (this sender, or the processing thread's re-enqueue) schedules — no stale-flag

&#x20;  window, no double-enqueue. The `MS\_ACTOR\_SUSPENDED` guard is kept (suspended actors are

&#x20;  re-scheduled only by `msActorResumeFromFut`, never by a sender).

2\. \*\*`msActorProcess`\*\* makes `markEmpty` the \*\*last consumer op, under `processing`\*\* (so it

&#x20;  shares single-consumer exclusion with `msMpscPop` — reading/CASing `q->tail` off-processing

&#x20;  is a two-consumer race). `markEmpty` TRUE → deschedule, \*\*no re-push\*\* (a future sender's

&#x20;  `wasEmpty` edge re-queues). `markEmpty` FALSE → re-enqueue, but \*\*defer the run-queue push to

&#x20;  after the `processing` release\*\*, so a concurrent popper acquires `processing` only once we

&#x20;  have let go (it wins the freed CAS, never drops).

3\. \*\*`msActorProcess` processing-CAS-fail\*\* re-enqueues the actor instead of dropping it: the CAS

&#x20;  only fails inside the narrow markEmpty→release window (where the holder's deschedule branch

&#x20;  does not re-push), so re-enqueuing here is the sole re-push — no double-push.



\### Why the `processing` CAS is kept (the MS/Pony reconciliation)



Pony needs no `processing` flag because pop-equals-run and it reschedules strictly \*\*after\*\*

`ponyint\_actor\_run` returns, so two schedulers never enter one actor. MS keeps `processing`

because (a) our `scheduled` flag intentionally lets an actor sit on the run queue while running,

and any idle worker can \*\*steal-pop\*\* it — without `processing`, a steal-pop mid-drain would put

a second thread into `msMpscPop` on the same mailbox (two consumers); and (b) \*\*spawn-inside-actor

suspension\*\* (no Pony analogue) hands the actor off through `processing` release at the suspend

point. The fix is therefore the Pony \*messageq gate\* layered on top of the retained MS

\*work-stealing/suspension\* exclusion — not a blind Pony port.



\### Affected Invariants



None changed. I1–I16 hold. Specifically: I8/I9 (suspension — the suspend path and the

`MS\_ACTOR\_SUSPENDED` guard are unchanged), I12 (Promise semantics outside spawn), I16 (cross-thread

send still wakes via the amortized wake). Serial execution and work-stealing are preserved. The

amendment makes the implementation correctly enforce the implicit "every message is eventually

processed" liveness; it does not change the model.



\### Impact Assessment on Shipped Phases



\- Phases 0–4 (spawn / await / async): no impact — those paths don't touch the actor mailbox gate.

\- Phases 5–8 (actor): behaviour preserved, the strand hang closed. No change to mailbox MPSC

&#x20; semantics, suspension, backpressure (OVERLOADED/mute), or cycle detection (BLOCKED/RC set under

&#x20; `processing` before `markEmpty`, Pony-parity).



\### Verification



TSan deterministic repro 20/20 (0 hang, 0 race); `-O0` hunt 150/150 (0 hang, was \~1/30);

`test-native` 52 pass / 0 fail (drc+orc); self-host `--gc=orc` 274 modules; spawn-inside-actor

suspension (`actorSpawnBasic`, `testActorSpawn1`) 12/12 drc+orc+TSan; actor cycle/churn stress

(cycle-detector + multi-producer cross-thread sends) 10/10 drc+orc+TSan.



\### Open follow-up (separate, pre-existing — NOT this amendment)



The actor cycle/churn stress surfaced a \*\*pre-existing, GC-independent\*\* actor-destroy leak

(\~300 B per churned actor not freed; `--gc=drc` == `--gc=orc`, so unrelated to the cycle detector

or this scheduling change). Never caught before because no test churned actors. Tracked separately.



\---



\## Amendment D — Arc<T> \& Locker: Shared-Memory Concurrency (2026-06-22)



\### Context



PARALOCK's primary answer to shared mutable state is the \*\*actor\*\* (§7): state is isolated and mutated only by serial message dispatch — no locking. This amendment records the \*\*shared-memory\*\* complement, the escape hatch for code that genuinely wants several threads touching one heap object directly:



\- \*\*`Arc<T>`\*\* — an atomic per-type refcount so an object stays alive race-free while N threads share ownership. \*\*Shipped + validated.\*\*

\- \*\*`Locker`\*\* — the existing bare ticket-lock (`std/core/promise`). The shared-mutable pairing is \*\*`Arc<struct{ lock: Locker; …data }>`\*\*: `Arc` keeps the cell alive, `Locker` serialises the mutation.



Shared memory is deliberately \*secondary\* — actors stay the default. Reach for `Arc` + `Locker` only when message-passing doesn't fit.



\### Arc<T> — shipped



The first \*\*per-type atomic refcount\*\* path in the compiler. A plain `Ref<T>` rc is non-atomic: `msDecRefIsLast` reads the count then decrements as two steps, so two threads dropping the same object race the check-then-decrement (TOCTOU) → premature free / leak. That is exactly why sharing a heap object across `spawn` threads crashed. `Arc<T>` makes the count atomic.



Mechanics (reuse existing machinery — no new `TypeKind`):

\- \*\*Type:\*\* `createArc(inner)` returns `Ref<inner>` with the new `TypeFlag.IsAtomic` (bit 21 — high, clear of the SizedArray size field and Function minArity, like `Substituting`). `Arc<T>` is structurally a `Ref` + flag and reuses Ref's auto-deref (`c.field`), box, and codegen wholesale; `isAtomicRef(t)` is the predicate. Enforced in `compat.ms`: `Arc<T>` ≠ `Ref<T>`/`T` (mixing atomic + non-atomic rc on one object is UB).

\- \*\*Hooks:\*\* `classify.ms` emits `msAtomicIncref`/`msAtomicDecref` for an `Arc`; per-field hooks (`destructorLifting` `refOp`) and the return-incref (`inject.ms`) follow the same flag. `runtime/drc.h`: `msAtomicIncRef` = `fetch\_add(INC, relaxed)`; `msAtomicDecRefIsLast` = `fetch\_sub(INC, release)` + acquire-fence-before-free, freeing when the old count == `MS\_RC\_INCREMENT` (Rust Arc convention). Arc is acyclic — never routed through the ORC cycle collector even under `--gc=orc` (its trace hook is skipped).

\- \*\*Creation:\*\* `new Arc(value)` → checker types it `createArc(pointee)` → `nativeLower` rewrites to `msBoxArc(value)` → codegen boxes the value inline in an `msAllocArc` cell. \*\*The box starts at `rc = MS\_RC\_INCREMENT`, not 0\*\* — the atomic decref frees when `fetch\_sub` sees the old rc == INC, so the `rc=0` sole-owner start of the non-atomic path would underflow and never free. The cell's TypeInfo is a \*\*weak-linkage\*\* Arc cell (`ensureArcCellTypeInfo`) whose `destroyFn` runs the pointee's destructor on the last atomic ref — weak so a box site landing in a lifted-closure module can emit it (the owning-module-gated `ensureTypeInfoDef` would otherwise leave the symbol undefined).



Usage + scope:

\- `const c: Arc<Payload> = new Arc({ ... })`; read fields with auto-deref (`c.n`); share across `spawn`.

\- \*\*Borrow vs owning:\*\* a read-only capture whose tasks all finish before the data dies stays a \*borrow\* (no rc traffic — the Rust `\&T` case; a plain `Ref` borrows too). Arc's atomic incref/decref fire only when ownership genuinely escapes across threads (a task returns or stores the `Arc`) — the case Arc is \*for\*.

\- MVP scope: `Arc<struct>` / `Arc<GenericInstance>` value pointees (they carry a TypeInfo). `Arc<interface>` (already a heap `Ref` → double-rc) and `Arc<primitive>` are deferred.

\- Known rough edge: `Promise.all` over `Arc<T>`-returning spawns is still unsupported, but the failure mode changed with the 2026-08-28 typed-collection repair: it now fails loud at link (`undefined symbol: \_PayloadDestroy` — the result-cell's array-destroy TypeInfo references a pointee destructor the Arc path never emits) instead of silently mistyping the result element (probed 2026-08-28). Workaround unchanged: individual `await` per handle.



Validation: ASAN-clean (no UAF/double-free) `drc`+`orc` under 6-thread × 800-round contention; self-host gen-1→gen-2 code-identical (the binary delta is only the linker UUID + code-signature, confirmed by same-compiler same-input run-to-run variance); suite 3016/0; native regression `arc-shared-box` flat-RSS `drc`+`orc` (`src/test/native/programs/arcSharedBox.ms`); the atomic primitive proven separately by an 8-thread pthread+TSAN probe.



\### Locker is the lock primitive — a typed `Mutex<T>` was evaluated and dropped



The lock is the existing bare \*\*`Locker`\*\* (`std/core/promise`: a `msTicketLock` 2-int spinlock over an inline cell — `createLocker` / `lockAcquire` / `lockRelease` / `withLock`). Shared mutable state across threads is \*\*`Arc<struct{ lock: Locker; …data }>`\*\*: `Arc` (atomic rc) keeps the heap cell alive while N spawn threads hold it, `Locker` serialises the read-modify-write. Two usage shapes:



\- \*\*Bare lock guarding external state\*\* — the lock is a module-global gate over a non-thread-safe object (e.g. a DB client singleton). No `Arc` (global lives forever, never racing-refcounted). `createLocker()` + `lockAcquire`/`lockRelease` (or `withLock`).

\- \*\*`Arc<struct{ lock }>` shared across `spawn`\*\* — lock + data on the heap, shared by owning references across threads. Validated by `arc-locker-shared-counter`.



A Rust-shape \*\*`Mutex<T>`\*\* (a lock that owns its value inline, `withLock` the only access) was built (`std/core/sync`, an `msLocker`-backed typed handle sized by `sizeof T`) and then \*\*dropped\*\*. The reason is a language-design one, not sunk-cost:



> "Lock owns its data" only earns a dedicated primitive when the type system \*enforces\* it. Rust's `Mutex<T>` is proof-carrying: holding a `MutexGuard<T>` is compile-time evidence you hold the lock, and the borrow checker ties the guard's lifetime to the access — the type IS the enforcement. MS has none of that: no field privacy, no borrow checker, no RAII-drop (`TypeKind.Borrow` is syntactic; only `defer` exists). The `Ptr<T>` a typed `withLock` hands out escapes the closure unchecked. So porting the \*shape\* `Mutex<T>` imports the spelling without the substance — an API that \*looks\* like it enforces lock discipline but doesn't, which is worse than absent.



Orthogonality settles it: shared mutable state decomposes into three independent axes — \*\*exclusion\*\* (`Locker`), \*\*cross-thread liveness\*\* (`Arc`), \*\*typed data\*\* (`struct`) — and a plain `struct { lock: Locker; …fields }` already co-locates lock + typed data in one value, read directly (`g.count`) instead of through `Ptr<T>` + `msLockerData`. A lock-owns-data type adds no fourth axis; it is a redundant, non-orthogonal bundle with zero shipped consumers. If MS ever wants real lock-data safety, the work is \*enforcement\* (linear/borrow on the `Ptr<T>`, or field privacy), not the API shell.



\*\*The `sizeof T` fix stays.\*\* `createMutex<T>` was its only consumer, but the fix is a general correctness fix independent of it: `sizeof T` for a generic param folded to `0` — const-folded at template check (before mono), and `SizeofExpr` is a no-child leaf in `forEachChild` so `replaceTypeVars` never substituted its type string. Fixed by deferring the fold when the operand resolves to `GenericParam` + substituting `SizeofExprData.sizeofType` in `instantiate.ms` `substNodeLocal`, so the instance re-check folds the concrete size. Self-host-neutral, kept with its own regression. The first real consumer will be generic byte-size-aware code (typed pool/slab allocator, `Ring<T>`, typed arena, fixed-width serializer) in `std/core/`.



Validation: `arc-locker-shared-counter` native regression (3000 rounds × 4 spawn on one shared `Arc<struct{lock}>`, counter in the lock slot, `total=12000` exact) green on `drc`+`orc`; suite 3025/0.



\### Affected invariants



None of I1–I14 change — `Arc` and `Locker` are memory primitives orthogonal to the spawn/await/actor surface and add no new soundness rule to the affine-Promise / actor model. New standing rule (memory, not promise): \*\*ownership of a heap object shared across threads must go through `Arc<T>` (atomic rc); a plain `Ref<T>` shared by ownership across threads races its non-atomic count.\*\* Read-only borrows (joined-before-free) remain safe without `Arc`.



\### Impact assessment on shipped phases



Zero. `Arc` and `Locker` are opt-in; the compiler itself uses neither, so every new path is inert during self-compile — suite 3025/0 and the `arc-locker-shared-counter` native regression green `drc`+`orc` (`total=12000`); the `refOp` atomic-param and the `classify`/`compat` flag-checks are no-ops for non-atomic `Ref`. The one shared compiler change — `sizeof T` now monomorphizes — is a no-op for non-generic `sizeof` (all existing usage) and folds identically post-mono, so the self-host binary is unchanged.



\---



\## Amendment E — Locker discipline (load-bearing) + adaptive park (Tier 1); awaitable lock (Tier 2) dropped (2026-06-25)



\### Context



Follow-up to Amendment D: "with `Arc<struct{lock: Locker}>`, does MS reach a thread-park-mutex runtime's concurrency power, the MS way?" Re-derived from MS's \*\*own\*\* execution model, not by analogy to other languages — they sit at opposite extremes (stackful-everywhere vs no-shared-mutable) and MS is neither. Two model facts decide it, both source-verified 2026-06-25:



\- \*\*No stackful coroutines.\*\* A task frees its thread only at a compiler-built continuation (`await`); there is no stack to park mid-function.

\- \*\*Three await lowerings already exist\*\* (§4): async stepper (`msAsyncCb`, `dispatchFull.c:592` — unresolved future → `msFutureAddCallback` + \*return\*, thread freed), actor suspension (`msActorSuspend`, `actor.h:292` — resume callback + \*return\*, thread freed), sync-context blocking (`msWaitFor`/`msWaitForReady`, `dispatchFull.c:510/527` — help→spin→condvar-park, thread \*bound\*).



So "wait without burning a thread" is already solved on the async/actor branch (callback resume). The sync branch binds a thread by design.



| Verified fact | Evidence |

|---|---|

| Async `await` frees the worker thread | `dispatchFull.c:636` — register `msAsyncCb` callback then return; eager-loop only when future already resolved |

| Actor suspend frees the worker thread | `actor.h:292-301` — set `MS\_ACTOR\_SUSPENDED`, register `msActorResumeFromFut`, return |

| `Locker` is pure busy-spin (no park) | `locker.h:53-62` — ticket fetch-add + `msCpuRelax` backoff, no syscall |

| Worker pool is finite | `pool.c:250` — `workerCount = msDetectCPUs()`, ≤ 64 (`idleMask` is 64-bit) |

| No address-keyed park exists yet | grep `futex`/`\_\_ulock`/`WaitOnAddress` over `runtime/` = 0 hits |



\### The load-bearing rule — Locker discipline



`Locker` guards a \*\*short, pure shared-memory critical section\*\* (mutate a field/counter). \*\*Never\*\* `await` / `msWaitFor` / do I/O / block while holding a `Locker`.



This is load-bearing, not style. The sync-wait ladder is \*cooperative\*: while waiting it calls `msPoolBusyDec()` + `msPoolHelpOne()` (`dispatchFull.c:514-516`), draining the queue so the lock holder can still get a worker and progress. The `Locker` spin (`msTicketLockAcquire`) is \*not\* — it only `msCpuRelax`es: no help, no yield, no availability signal. A long or blocking critical section therefore makes every contending worker burn a core without helping, while a holder that is itself parked inside the lock (on some future) cannot get a worker to complete it → all-workers-blocked (hazard E80). Anything I/O-bound, long, or queue-shaped goes through an \*\*actor or async\*\* instead, where suspension frees the thread. Split the workload by branch — short shared-memory guard → `Locker`; long/I/O/queue wait → actor/async — and the E80 footgun never arms. This is how MS matches a thread-park runtime's power without a stackful runtime or a tracing GC.



\### Tier 1 — adaptive spin→park — APPLIED (2026-06-25)



`msTicketLockAcquire` spins a bounded budget, then \*\*parks\*\* on `\&nowServing` via an address-keyed wait (`futex` / `\_\_ulock` / `WaitOnAddress`, `runtime/promise/futex.h`); `msTicketLockRelease` wakes parked waiters only when `nextTicket != nowServing`, so the uncontended fast path stays syscall-free. `msTicketLock` stays 2 ints / 8 bytes — `lockerLayout.h` and the `--gc=manual` no-op stubs are untouched; FIFO fairness preserved. Pure runtime efficiency: removes the spin-burn footgun but \*\*does not change the discipline rule\*\* — a parked waiter still does not help, so blocking-under-lock stays forbidden.



\### Tier 2 — awaitable (task-parking) lock — EVALUATED \& DROPPED



A lock whose `acquire` suspends the \*task\* (not the thread) on contention was considered and rejected. It is exactly a thread-park-mutex runtime's mutex — cheap there only because the stack parks for free. MS is not stackful, so it would have to be hand-built into the await-lowering machinery, and even then would only work in async contexts — where an \*\*actor already is the awaitable serializer\*\* (mailbox = FIFO wait queue, `msActorSuspend` = thread-free park). The strongest case (an async resource pool) is a textbook resource-actor: no new primitive, no compiler change, no new soundness rule. Tier 2 would add a lock-based concurrency path that §7 (actor is the default for shared mutable state) is specifically designed to make unnecessary.



\### Affected invariants



None of I1–I14. Tier 1 is a runtime-internal change to one primitive; Tier 2 was not built. The Amendment D memory rule is unchanged; the Locker discipline above is a \*\*usage\*\* rule (when not to hold the lock), not a new soundness invariant.



\---



\## Amendment F — Struct-valued futures: one boxed representation (2026-07-02)



\### Trigger



`await` on an async function that returns a struct \*\*crashed\*\* (SIGSEGV) in sync/top-level context; `waitFor` on the same crashed differently (garbage) on actor/spawn struct returns. Root-caused: a struct-valued future had \*\*two layouts depending on its source\*\*, and neither read path handled both.



\### The two layouts (source-verified)



`isBoxed` was removed (Session 4), so there is \*\*no runtime flag\*\* to distinguish layouts at read time — the layout is fixed by the producer:



| Source | Completion | Storage |

|---|---|---|

| async fn struct return | `msFutureCreateInline` + `msFutureCompleteT` | \*\*INLINE\*\* (typed value in `msFuture\_<T>`) |

| actor CALL struct return | `msSinkBoxStruct` → `msMsgCompletePtr` | \*\*BOXED\*\* (`void\*` heap pointer) |

| spawn struct return | AwaitGroup `results` = `void\*\*` (awaitGroup.h) | \*\*BOXED\*\* |



`await`'s deferred reader (`msWaitFor` + `msUnboxStruct`) assumes BOXED → correct for actor/spawn, \*\*crashed on async (inline)\*\*. `lowerWaitFor` used `msWaitForStruct` (inline) → correct for async, \*\*garbage on boxed\*\*.



\### The decision — standardize on BOXED (not inline)



Struct / tuple / generic-instance async returns now \*\*box\*\* via `msSinkBoxStruct` — exactly the path async \*\*arrays already used\*\* — so `await`'s existing boxed reader (`msWaitFor` + `msUnboxStruct`) handles \*\*every\*\* source uniformly. `String` stays INLINE (`msFutureCreateInline` + the `msFutureReadString` typed reader — a 16-byte value with a working typed path); primitives stay inline (fit the `void\*` slot). `lowerWaitFor` mirrors: only `String` → `msWaitForStruct`, struct/tuple/GI → boxed unbox.



\*\*Why boxed, not inline\*\* (the future.h header aspires to inline-everywhere): the concurrency primitive `AwaitGroup.results` is `void\*\*` — boxed at its core — and actor/spawn are already boxed. Boxed is the \*\*majority + the primitive's own representation\*\*. Making everything inline would require reworking the `void\*\*` AwaitGroup slot model \*\*and\*\* the actor reply completion — both LOCKED cross-thread-completion paths (Amendments A/B/C). Boxing async instead touches \*\*only asyncBridge\*\*, mirrors an existing path (arrays), and is \*\*zero-touch\*\* to the await reader, actor completion, AwaitGroup, and every cross-thread contract.



\*\*Tradeoff:\*\* async struct returns lose their inline zero-alloc (one `malloc`+`free` per return) — accepted; struct-returning async is not a hot path, and the win is one consistent reader + no locked-area risk. Bonus: this also fixed a pre-existing `waitFor`-on-actor-struct garbage read.



\### Changes (4 edits)



\- `asyncBridge.makeRetFutAlloc` — String → `msFutureCreateInline`; everything else → `msFutureCreate`.

\- `asyncBridge.makeFutureCompleteStmts` + stepper return rewrite — struct/tuple/GI (and arrays, as before) → `msSinkBoxStruct` box; String + primitives → inline `msFutureCompleteT`.

\- `promiseLower.lowerWaitFor` — only String → `msWaitForStruct`; struct/tuple/GI → boxed `msWaitFor` + unbox.



\### Affected invariants



None broken. I11 (await picks one unambiguous intrinsic per call site — still true, dispatch is by return-type kind). I12 (Promise semantics unchanged outside spawn-related code — unchanged). \*\*I13\*\* (`nodeType` is result type, never a sizeof-hint — preserved: `msSinkBoxStruct` reads `sizeof(T)` from the argument's `nodeType`, the box call's own nodeType stays `void\*`). §2.1 (`msFutureCreateInline` still allocates the inline path — now for String only).



\### Validation



`test-native` 102 pass / 0 fail (drc+orc) — new `await-struct-returns` (async struct via await, heap-string field, flat RSS) + `await-struct-actorspawn` (actor+spawn regression guard) green; self-host binary builds + smokes drc+orc; the suite +0 regression vs baseline. DRC ownership of the struct's heap fields transfers through the box (`msSinkBoxStruct` memcpy+memset-move → `msUnboxStruct` copy-out+free-shell), proven by the flat-RSS heap-string test — not just POD copy.



\---



\## Amendment G — In-flight ownership of cross-thread completion futures (2026-07-06)



\### Context



Amendment A locked the cross-thread completion \*\*API\*\* (Step 1 worker publish / Step 2 dispatcher drain-via-`msFutureFireCallbacks`, I15). It did \*\*not\*\* specify the lifetime of the \*future object itself\* while a completion is in flight. §9.8 governs the captured env (E140) and the result value (E144) — but the future \*\*handle\*\*, the object the worker writes `finished`/`value` into and the owner eventually frees, was never covered. Two reference-count bugs landed in exactly this undocumented gap:



\- \*\*2026-06-26\*\* — a \*push→drain\* window: the completion message carried a raw `fut` pointer, so the owner could free the future between the worker's push and the dispatcher's drain. Fixed by having the completion queue take a ref on push (`msIncRef` in `msCompletionQueuePush`) and release it on drain (`msFutureDrcDestroy`). This fix was applied to code only — never lifted into this document.

\- \*\*2026-07-06\*\* — a residual \*publish→push\* window the first fix did not close. The worker sets `finished = true` (release) in Step 1 and only takes the queue's ref inside the Step-2 push. An owner observing `finished` (via `await`/scope-exit array destroy) can free the future in the gap \*\*before\*\* the push-time `msIncRef` runs → the worker then increfs freed memory. ASAN-proven on the stored-spawn shape (`Promise<Struct>\[]` hammered \~40 000×): worker `msIncRef` (`drc.h`) via `msCompletionQueuePush` writes to a future freed by the owner's `msRefArrayDestroy`.



\### The Invariant (now explicit) — I16



\*\*I16:\*\* A future that will be completed by another thread MUST be kept alive by a reference that provably outlives the completing worker's last write to it. That reference is acquired \*\*before the future becomes concurrently visible\*\* (acquire-before-visible), and released \*\*exactly once\*\* by the consumer. For a future whose owner is \*external to any suspension\* (stored in an array/variable, decoupled from the `await` that reads it), the queue's in-flight ref is that reference and MUST be taken on the \*\*owner thread at submit time\*\* — not on the worker at push time.



This is the acquire-before-visible discipline standard in production message-passing runtimes: the sender accounts for the in-flight reference before the message (here, the completion) can become concurrently reachable.



\### Mechanism



\- `msSpawn` / `msSpawnInto` / `msAwaitGroupSetDoneFut` take `msIncRef(fut)` \*\*before\*\* `msPoolSubmit` / before the future is handed off — on the owner thread, while it is still the sole accessor.

\- The worker completes via `msCompletionQueuePushOwned` (identical to `msCompletionQueuePush` minus the internal incref).

\- The dispatcher drain releases via `msFutureDrcDestroy` — \*\*unchanged\*\*.

\- \*\*Count-neutral:\*\* still exactly one incref (moved earlier in time) + one decref. No path's total ref accounting changes; only the \*timing\* of the acquire moves earlier, which strictly prevents premature free without enabling any new leak.

\- \*\*Gated\*\* to the full POSIX MPSC dispatcher (`MS\_FUTURE\_SUBMIT\_REF` = `!\_WIN32 \&\& !MSOS\_BARE \&\& !MSOS\_WASM \&\& !MSOS\_EMCC`). Windows IOCP + WASM + Emcc complete inline / take no queue-side ref, so `PushOwned` ≡ `Push` there and the submit-ref is compiled out — those backends are byte-for-byte unchanged.



\### Channel map — why exactly one class needed the fix



Every cross-thread completion channel keeps its future alive by \*some\* reference that outlives the worker. Only two hand ownership to an external owner decoupled from the await:



| Channel | Keeps the future alive across completion | Acquire-before-visible? |

|---|---|---|

| Spawn future \*\*stored\*\* (array/var) | queue's in-flight ref | \*\*was violated\*\* (push-time) → \*\*fixed\*\* (submit-time) |

| AwaitGroup \*\*doneFut\*\* | queue's in-flight ref | was violated → fixed at `msAwaitGroupSetDoneFut` |

| Spawn \*\*fused/slot\*\* (`await spawn()`) | `msAwaitSlot` on the caller stack + help-first | OK — stack outlives worker |

| \*\*Actor reply\*\* future | awaiter's registered `msActorResumeFromFut` + suspension | OK — suspension outlives worker |

| Actor \*\*message payload\*\* | msg owns its deep-copy (isolation, §7) | N/A — nothing shared cross-thread |

| \*\*Arc<T>\*\* shared object | atomic RC (Amendment D) | OK — atomic, symmetric |



The insight: only \*\*spawn-stored + doneFut\*\* give the future to an owner (an array slot) whose lifetime is decoupled from the `await` — the slot can drop the instant `await` returns, inside the publish→push window. Every other channel's keep-alive reference is structural (stack / suspension / isolation / atomic-rc), so none needs the queue's in-flight ref.



\### Residual (known limitation) — concurrent decref



After this fix, one race remains on queue-completed futures: the owner's decref (array destroy) can run concurrently with the dispatcher's drain decref, both non-atomic on the same rc. Worst case is a \*\*rare leak\*\* (both read "not last", neither frees); \*\*UAF/double-free is impossible\*\* — a free requires observing rc==0, and the interleavings that reach the free are mutually exclusive. Production actor runtimes avoid this by serializing all decrefs to the owner (Pony ORCA: cross-actor RC deltas ship as `ACTORMSG\_ACQUIRE`/`ACTORMSG\_RELEASE` messages on the owner's MPSC queue, never touching the rc field from a foreign thread). \*\*Superseded by Amendment H\*\* (2026-07-06): the resolution is deferred decref via batched TLS flush to the dispatcher — not atomic rc. Atomic rc was the initial pragmatic instinct (`msAtomicIncRef`/`msAtomicDecRefIsLast` already exist from Amendment D), but analysis showed it is both more expensive for batched workloads (`lock inc` \~5 cycles/op unbatched vs deferred \~1 cycle/op amortized) and a paradigm mix with non-atomic DRC. See Amendment H for the full rationale, the Pony ORCA batching precedent, and why MS's existing 64-msg actor batch makes deferred decref the cheaper option. The Windows IOCP path carries the \*\*mirror\*\* latent bug (it takes no queue-side ref at all) — out of scope here, also addressed by Amendment H's deferred path on POSIX; Windows falls back to inline decref (gated by `MS\_FUTURE\_SUBMIT\_REF == 0`).



\### Affected Invariants



None broken.



\- \*\*I15\*\* (drain fires via `msFutureFireCallbacks`) — preserved: `PushOwned` routes to the same MPSC → same drain → `msFutureFireCallbacks`.

\- \*\*Amendment A\*\* Step 1/Step 2 — preserved: worker still does value → `finished`(release) → `msNotifyFutureComplete` → push, in that order.

\- \*\*Amendment B\*\* targeted wake — preserved: `PushOwned` keeps the wake-pipe write.

\- \*\*Amendment C / D / E\*\* — untouched (no change to actor scheduling, Arc, or Locker).

\- \*\*Amendment F\*\* boxed struct-future reader — orthogonal (boxing unchanged).

\- \*\*§9.8 E140/E144\*\* (env + result-value DRC) — untouched: I16 governs the future \*\*handle\*\*, a distinct object.



\### Impact Assessment on Shipped Phases



\- Phases 0–2: no cross-thread spawn completion — no impact.

\- Phase 4a (async cooperative spawn): the publish→push UAF window lived here; this closes it.

\- Phases 5–8 (actor): actor reply futures are kept alive by the suspended awaiter's registered resume callback — they \*\*already\*\* satisfied I16, no change.

\- Arc (Amendment D): the atomic-rc path already satisfies I16.



\### Validation



Gate (required before this amendment is marked applied): `src/test/native/hammerAsan.sh` green — it builds the `awaitStructSpawnStored` shape under ASAN + slab-off and hammers it 200× on `--gc=drc` and `--gc=orc` (a single normal-build `test-native` run is near-blind to this race, so the committed ASAN-hammer script is the durable guard, not the once-run manifest entry); plus full warm `test-native` green and self-host binary builds + smokes drc+orc. This amendment is NOT marked applied in the closing changelog until that gate runs green.



\### Rationale



The completion \*\*API\*\* was locked but the completion-\*\*object lifetime\*\* was implicit in code comments plus an out-of-doc note — and two RC bugs (2026-06-26, 2026-07-06) both landed in that gap. This amendment lifts the lifetime rule (I16, acquire-before-visible) into the locked document with the full channel map, so any future refactor of the completion path has a doc-level guard rail, and records the residual concurrent-decref limitation. The resolution (deferred decref, not atomic rc) is locked by Amendment H.



\---



\## Amendment H — Deferred decref: serialize future rc to the dispatcher (2026-07-06)



\### Context



Amendment G (I16) locked the submit-time incref that closes the publish→push UAF. Its Residual section documented a remaining race: the owner's inline decref (array destroy / scope exit) can run concurrently with the dispatcher's drain decref, both non-atomic on the same rc field. The Residual section named "atomic rc on future objects" as the resolution and deferred it.



This amendment supersedes that resolution. Atomic rc is the textbook cross-thread RC fix (C++ `shared\_ptr`, Rust `Arc`), but for MS's DRC model it has two costs the Residual section didn't fully account for:



1\. \*\*Global vs scoped.\*\* Making only futures' rc `\_Atomic` requires the DRC analyzer to emit `msAtomicIncRef`/`msAtomicDecRefIsLast` for `Promise<T>` types at every decref site — a type-directed dispatch that must be correct at every scope exit, array destroy, closure capture, and struct field. Making all rc `\_Atomic` globally avoids the dispatch but touches every DRC object (Nim's ARC team measured measurable slowdown from `lock inc` on every rc op; MS's compiler self-host does millions of rc ops/sec).



2\. \*\*Per-op cost vs amortized cost.\*\* Atomic rc pays \~5 cycles per op (`lock inc` on x86, uncontended). MS already has batching infrastructure (64-msg actor batch at `actor.h:95`, drain-to-empty completion queue at `dispatchFull.c:290`, TLS slab at `drc.h:76`). Deferred decref amortizes the MPSC push (\~15 cycles) over N releases: \~1 cycle per TLS append + 15/N per amortized push. For batched workloads (actor reply futures, spawn arrays), deferred decref is 2–4× cheaper than atomic.



\### The Invariant (now explicit) — I17



\*\*I17:\*\* A `Promise<T>` whose lifetime spans a cross-thread completion (submit incref taken on the owner thread, drain decref on the dispatcher) MUST have its owner-side decref deferred to the dispatcher thread via TLS accumulation + batch flush — not executed inline. The dispatcher processes both the drain decref and the deferred release single-threaded, satisfying the Pony invariant (one field, one thread) without atomic rc.



This supersedes the "atomic rc on future objects" clause of Amendment G's Residual section.



\### Precedent — Pony ORCA



Pony never lets two threads touch the same non-atomic rc field. Cross-actor RC deltas ship as `ACTORMSG\_ACQUIRE`/`ACTORMSG\_RELEASE` messages on the owner actor's MPSC queue. One `actorref\_t` carries an `objectmap\_t` (hashmap of N objects, each with its own rc delta) — one message per foreign actor, N RC operations amortized (`gc.c:793-812`, `actormap.h:12-18`). The owner applies the delta single-threaded when it drains its queue (`actor.c:315-339`, `gc.c:731-755`). `rg "atomic.\*rc|rc.\*atomic" src/libponyrt/gc/ src/libponyrt/actor/` returns zero hits — all rc fields are plain `size\_t`.



MS's analog: one TLS flush carries N future pointers — one MPSC push per batch boundary, N decrefs amortized. The batching infrastructure already exists (actor 64-msg batch, drain-to-empty completion queue, TLS slab). No new pool allocator or shadow-RC table needed — MS's future traffic is \~1000× lower than Pony's per-message-trace traffic, so the lightweight TLS-ring approach suffices.



\### Mechanism



\*\*Owner thread (deferred release):\*\*

1\. DRC analyzer emits `msFutureDeferredRelease(fut)` instead of `msDecRefIsLast(fut)` for `Promise<T>` types at scope exit (array destroy, local variable exit, closure capture drop). The analyzer already has type info — the check is `isFutureType(t) ? msFutureDeferredRelease : msDecRefIsLast`.

2\. `msFutureDeferredRelease(fut)` appends `fut` pointer to a TLS ring buffer (`msFutureReleaseTLS`, 64 entries, alongside `msSlabTLS` in `drc.h`). No rc access. \~1 cycle.

3\. At a batch boundary (see Flush Points below), the TLS buffer is flushed: all pending entries are pushed as a single batch-release message to the completion queue (`msCompletionQueuePushReleaseBatch`). One MPSC push, amortized over N entries.



\*\*Dispatcher thread (drain):\*\*

4\. `msCompletionQueueDrain` pops the batch-release message (new message kind, e.g. `kind == -2`).

5\. For each `fut` in the batch: `msFutureDrcDestroy(fut)` — same decref path as today, now guaranteed single-threaded.



\*\*Lifecycle (per future, unchanged incref/decref count — only the timing of the owner decref moves):\*\*

```

Create:        rc=0   (owner thread, msFutureCreateT)

Submit incref: rc=1   (owner thread, Amendment G — unchanged)

Worker:        PushOwned (no rc change — unchanged)

Drain:         fire callbacks + msFutureDrcDestroy → rc 1→0, return false (dispatcher)

Deferred:      msFutureDrcDestroy → rc=0, return true, FREE (dispatcher)

```

Count: 1 alloc (implicit rc=0) + 1 incref = 2 owners. 2 decrefs (drain + deferred). Last decref frees. Balanced — identical to Amendment G's accounting, only the owner's decref is now deferred instead of inline.



Both decrefs run on the dispatcher thread → serialized → no race. The submit incref is on the owner thread but sequenced before the drain decref by the MPSC queue's release-acquire ordering. No atomic needed on the rc field.



\### Flush Points



Every thread that can own a `Promise<T>` has a batch boundary where the TLS buffer is flushed:



| Thread type | Flush point | Location | When |

|---|---|---|---|

| Main / dispatcher | `msRunOnce` end | `dispatchFull.c` (after drain + poll) | Every event loop tick |

| Scheduler (actor) | `msActorProcess` end | `actor.h:454` (after 64-msg batch) | Every actor batch |

| Pool worker | Post-task | `pool.c:166-176` (between task completion and next dequeue) | Every spawn task |

| Overflow safety | TLS buffer full (cap=64) | Flush immediately inline | Worst-case bound |



The buffer cap bounds the worst-case delay before a deferred release is processed to one batch boundary (microseconds under normal load).



\### Gating



Same gate as Amendment G: `MS\_FUTURE\_SUBMIT\_REF = !\_WIN32 \&\& !MSOS\_BARE \&\& !MSOS\_WASM \&\& !MSOS\_EMCC`. On Windows IOCP / WASM / Emcc, `msFutureDeferredRelease` falls back to inline `msFutureDrcDestroy` — those backends complete inline / take no queue-side ref, so there is no race to defer. The deferred path is compiled out.



\### Cross-producer ordering — exception path verified



Normal case: worker pushes completion at T1. Owner pushes deferred release at T2 > T1 (owner cannot exit scope until `await` completes, which requires the completion). Vyukov MPSC preserves list insertion order → drain pops completion before release.



Exception path (owner exits scope without awaiting — e.g. unwinding from an error between `spawn` and `await`): release may arrive before completion. Both are processed on the dispatcher → serialized. Release decref sees rc=1 (from submit incref), decrements to 0, returns false (not freed). Completion decref sees rc=0, returns true, frees. Safe in either pop order.



\### rc accounting — all channels verified



| Channel | Incref site | Drain decref | Deferred release | Safe? |

|---|---|---|---|---|

| Spawn-stored (array/var) | submit incref (owner) | drain (dispatcher) | deferred (dispatcher via TLS) | ✅ Both decrefs on dispatcher |

| AwaitGroup doneFut | `msAwaitGroupSetDoneFut` incref (owner) | drain (dispatcher) | deferred (dispatcher via TLS) | ✅ Async stepper on dispatcher |

| Actor reply (`msPostCompletion`) | push incref (worker, via `msCompletionQueuePush`) | drain (dispatcher) | deferred (dispatcher via TLS) | ✅ Push incref sequenced by MPSC |

| Async return (`$retFut`) | create (rc=0, no extra incref) | N/A (no completion queue) | deferred (dispatcher via TLS) | ✅ Single-threaded |

| Fused spawn (`msAwaitSlot`) | stack-allocated, no rc | N/A | N/A | ✅ No decref emitted |

| Arc<T> shared object | atomic rc (Amendment D) | N/A | N/A | ✅ Owns its own atomic header |



\### Why not atomic rc (the option this supersedes)



| Criterion | Atomic rc (scoped to future) | Deferred decref (batched) |

|---|---|---|

| Per-op cost (x86) | `lock inc` \~5 cycles, unbatched | \~1 cycle TLS append + 15/N amortized push |

| 50M actors @ 1M msg/s | \~1.7ms/s (0.17%) | \~0.7ms/s (0.07%) — \*\*2.4× cheaper\*\* |

| Implementation | Analyzer type-directed `\_Atomic` dispatch + future header change | \~30 runtime lines + analyzer type-directed deferred-release emission |

| rc field type | Must be `\_Atomic` (UB if mixed with non-atomic DRC access) | Stays plain `uint32\_t` (no UB, no paradigm mix) |

| Pony alignment | "field atomic if needed" (weaker) | "one field, one thread" (stronger — structurally forbids the race class) |

| Robustness against analyzer bugs | Silent UB if analyzer misses a site (mixes atomic/non-atomic on same field) | No UB — worst case is a delayed decref (flush at next batch boundary) |



Atomic rc was the right first instinct. Deferred decref is the right final answer for MS's workload because MS already has the batching infrastructure that makes it cheaper.



\### Affected Invariants



\- \*\*I16\*\* (Amendment G, acquire-before-visible): preserved. Submit incref still taken before visibility. Deferred release is the owner's decref, not the queue's in-flight ref — it does not affect I16.

\- \*\*I15\*\* (drain fires via `msFutureFireCallbacks`): preserved. Drain fires callbacks before decref, same as today. Deferred release messages (kind == -2) skip callback firing.

\- \*\*New I17\*\*: future decref deferred to dispatcher via batched TLS flush — serializes all rc mutations on the future to the dispatcher thread (plus the owner's submit incref, sequenced by MPSC).



\### Impact Assessment on Shipped Phases



\- Phases 0–2: no cross-thread spawn completion — no impact.

\- Phase 3 (cancellation + timeout): spawn tasks still complete via `PushOwned`; deferred release is orthogonal.

\- Phase 4a/4b (async cooperative spawn): doneFut path benefits — both decrefs now guaranteed on dispatcher.

\- Phase 5–8 (actor): actor reply futures benefit — deferred release serializes with drain; no race even under heavy inter-actor CALL traffic.

\- Amendment G: submit incref + `PushOwned` unchanged. This amendment only changes the owner's decref path (inline → deferred). Count-neutral — same number of increfs and decrefs, only the timing of the owner decref moves earlier (into TLS) and later (onto dispatcher).

\- Amendment D (Arc<T>): unaffected — Arc uses its own atomic rc header, separate path.

\- Amendment F (boxed struct-future): unaffected — boxing is about value representation, not rc timing.



\### Validation



Gate (required before this amendment is marked applied):

1\. `awaitStructSpawnStored` under `hammerAsan.sh` 200× on `--gc=drc` and `--gc=orc` + ASAN-slab-off clean (same gate as Amendment G, now exercising the deferred-decref path).

2\. Full warm `test-native` green (drc + orc).

3\. Self-host binary builds + smokes (drc + orc).

4\. TSan clean on `awaitStructSpawnStored` hammered 100× — proves no data race on the rc field (both decrefs on dispatcher, no concurrent access).

5\. Actor-scale RSS stable under sustained load (e.g. `benchActorScale` or equivalent at 1M+ actors for 30s) — proves deferred releases flush promptly and don't accumulate.



\### Applied (2026-07-07)



Gates 1–3 verified on macOS arm64 (clang). Gate 1: `hammerAsan.sh 200×` clean on drc+orc with ASAN+slab-off. Gate 2: `test-native` 112/0 on drc+orc — including the two leak regressions (leak-discarded-future, leak-async-await-loop) that surfaced during integration and were resolved by the \*\*single-thread inline-decref refinement\*\* below. Gate 3: `msc` self-host binary builds + a fresh `./msc build` smoke runs cleanly. Gates 4 (TSan) and 5 (actor-scale RSS) deferred — TSan requires Linux (no native macOS support); RSS-stability is a perf check, not a soundness gate.



\*\*Refinement shipped alongside the amendment:\*\* the spec's blanket "all future decrefs defer to TLS" caused unbounded TLS/MPSC accumulation in tight loops of single-threaded async calls (fire-and-forget `async f()` in a `for` loop, `await` inside `while`). Root cause: futures that never cross threads have no drain decref to race with, so deferring is redundant — but the TLS buffer flushes only at batch boundaries (`msRunOnce` / `msActorProcess` / pool post-task), none of which fire inside a tight user loop.



Fix: a per-instance `crossThreadPublished: 1` flag on `msFutureBase`, set on the owner thread at submit-incref time (`msSpawn` / `msSpawnInto` / `msAwaitGroupSetDoneFut` — the three Amendment-G submit sites). `msFutureDeferredRelease` checks the flag: if false, inline `msFutureDrcDestroy` (no race possible — no drain decref exists for a future that never crossed threads); if true, defer to TLS as originally specified. The flag is touched only by the owner thread (set at submit, read at decref) — no cross-thread access, no atomic needed.



This preserves the spec's serialization guarantee for cross-thread futures (spawn/doneFut) while making single-threaded futures (async returns, fire-and-forget) zero-overhead. Cost: 1 byte per future + 1 branch per decref. The leak-discarded-future and leak-async-await-loop tests are the permanent regression guards for this refinement.



\### Rationale



Amendment G's Residual named atomic rc as the resolution. On deeper analysis — prompted by checking Pony's ORCA design and discovering MS already has the batching infrastructure atomic was supposed to be cheaper than — deferred decref is both more correct (Pony's stronger "one field, one thread" invariant) and cheaper (amortized over existing 64-msg batches). Atomic rc remains the right answer for workloads without batching (C++ `shared\_ptr`, Rust `Arc`); MS is not that workload.



\---




\## Amendment I — The SHARE verb: capability model at the actor boundary (2026-09-03)

\### Status

LOCKED (design) — not yet implemented. The trigger below is measured on HEAD `ace4d55f`; the implementation order and gates are part of this amendment. Supersedes exactly one clause of Amendment D (its shared-mutable pairing, `\`Arc<struct{ lock: Locker; …data }>\``); preserves the rest of D and all of E.

\### Trigger (measured 2026-09-03)

1\. \*\*SEND of a const ref is a deterministic use-after-free.\*\* `msMsgSetPtr(msg, i, ref)` stores the raw pointer with no incref — any refcount class — and the sender's scope-exit decref then frees while the message is in flight. Probe: 2000 fire-and-forget SENDs of a one-field ref into an actor, with an allocator-churning `new Arc<Filler>` between rounds. The actor's accumulated counter read the freed cell's reuser's field: rounds × junk.a for junk.a = 3 / 7 / 42 (expected 2000), deterministic 5/5 runs, `--gc=drc` and `--gc=orc`, identical on the pre-Amendment-I baseline. Identical for a plain interface ref and for `Arc<PayloadS>` — the hole is the SHARE path itself, not one type.

2\. \*\*Arc crosses the actor boundary only through that hole.\*\* `isTypeSendable` is false for `Arc<T>` (it is a `Ref`), so a const-bound Arc argument is accepted solely by the const-ref carve-out in `isSendable`: `const` passes and runs, `let` is rejected as a "mutable reference". SHARE is load-bearing for the only shipped immutable-share path into an actor — deleting it without replacement deletes the capability.

3\. \*\*CALL was sound only by accident.\*\* The same raw `msMsgSetPtr` on an awaited CALL is safe only because the sender parks on the reply — mechanically a BORROW, but nothing encodes that; the emit just happens to work.

4\. \*\*The Locker handle cannot survive its own purpose.\*\* `msLockerCreate` allocates the cell with plain `msAlloc` (non-atomic rc). A worker taking an owning copy — pushing the handle into an array inside a spawn thunk — emits a plain `msIncref` on the worker thread (probe q8, thunk emit). That is the check-then-decrement race class Amendment D built atomic rc to avoid, on the one object whose job is cross-thread sharing.

5\. \*\*Amendment D's pairing ships mixed rc on one object.\*\* Corpus 405 (`Arc<struct{ lock: Locker }>`): every field `.s` op is `msAtomicIncref`/`msAtomicDecref`, while the destroy hook drops the inner lock with plain `msDecref((*self).lock)` (405 emit). Sound today only by 405's borrow-only usage discipline.

6\. \*\*Two Arc codegen gaps.\*\* `Arc<Ref>` (interface pointee) emits invalid C (`msTypeInfo X*ArcTypeInfo;` — redefinition); `Arc<POD struct>` fails to link (`XDestroy` undefined when no pointee field needs destruction — Amendment D's Promise.all rough-edge class, on the plain path).

7\. \*\*The std Locker surface is discipline-only.\*\* Manual `lockAcquire`/`lockRelease`; the payload slot is a hardcoded 8-byte double (`createLocker()` → `msLockerCreate(8)`); corpus 405 stores its counter in that double and casts back with `as int32`.

Enforcement note shipped alongside (no rule change; commits `ace4d55f` / `4f26ed0a` / `8506c8ff`): §5.3's mutable-capture walk now reaches every read position via `forEachChild` — three racing shapes previously compiled clean (a HiddenStdConv-wrapped argument, an `x++` write-back into the parent's env slot, a read inside a C-style `for` body). Guard: `src/test/guard/spawnMutableCaptureShapes.ms`, proven red against the pre-fix compiler.

\### The decision — four verbs, no fifth

A value crossing an actor boundary (or entering a spawn thread) is in exactly one of:

| Verb | Meaning | Mechanism (all existing) |
|---|---|---|
| COPY | sender keeps its own; receiver gets a deep copy | strings (`msMsgSetString`) |
| MOVE | ownership transfers; sender's binding dead | arrays/structs (`msSinkBoxStruct`), `move` |
| BORROW | raw pointer, valid because the lender provably outlives the use | spawn-thunk env borrows (joined before free); awaited CALL with a const ref (sender parked on the reply) |
| SHARE | immutable data, shared ownership, atomic rc — \*\*Arc<T> only\*\* | `IsAtomic` / `msAllocArc` (Amendment D) + boundary incref (this amendment) |

Mutable shared state is \*\*not a message shape\*\*. Its one sanctioned form is `Locked<T>`. The old carve-out — any const ref across, raw pointer — is deleted for SEND-class invocations; on an awaited CALL it stays, classified as the BORROW it mechanically is.

\### Rules

\- \*\*Arc pointee sendability.\*\* `new Arc<T>` requires `isTypeSendable(T)`. A lock, any `Ref`, or any non-sendable field inside the pointee is a checker error. This converts trigger 6's `Arc<Ref>` crash and trigger 5's mixed-rc shape into clean diagnostics, and makes the "immutable" in SHARE checkable rather than aspirational.

\- \*\*SHARE boundary refcount.\*\* An `Arc<T>` stored into an actor message takes `msAtomicIncref` at the msgSetter; the actor side releases after the method runs. Uniform for CALL and SEND — CALL's accidental soundness (trigger 3) becomes sound by construction.

\- \*\*SEND-class refinement.\*\* A non-`move`, ref-shaped actor argument must be `Arc<T>` whenever the sender does not provably park on the reply. Awaited CALLs keep the const-ref BORROW unchanged; void methods and discarded results are SEND-class and reject a plain ref ("use `move`, `Arc`, or await the call") — that shape is trigger 1's UAF.

\- \*\*`Locked<T>`.\*\* One allocation: `msAllocArc` header + inline ticket lock (Amendment E Tier 1 park) + typed `T` payload (sized by Amendment D's sizeof-monomorphization fix). The handle's liveness is its own atomic rc — which is exactly why `Arc<Locked<T>>` is not a type: two cells / two refcounts is trigger 5's shape. Payload access only inside `update(s, (v: T): T)` / `read(s, (v: T): R)` — the callback IS the critical section; no pointer to the payload ever escapes. This is the enforcement mechanism Amendment D demanded before a lock-owns-data primitive could be justified (the dropped `Mutex<T>` failed on exactly this: its `Ptr<T>` escaped unchecked). Egress rule: the value OUT of `read`/`update` must be sendable — what leaves the cell is a copy, never a reference into mutable state. The std double-slot surface (`createLocker` / `lockerGet` / `lockerSet`) is retired; corpus 405 is rewritten to `Locked<T>` with composite state.

Amendment E's discipline rule (never await / block inside the critical section) carries over verbatim — `update` bodies are short and pure by the same argument.

\### New invariants

\- \*\*I21\*\* — a message crossing an actor boundary carries a COPY, a MOVE, a BORROW (lender provably outlives the use), or an atomic-rc SHARE (`Arc<T>` with sendable pointee, boundary incref). A raw refcounted pointer with no liveness proof crossing via a SEND-class invocation is a bug. (Row spliced into §8.)

\- \*\*I22\*\* — shared mutable state exists only as a `Locked<T>` cell: one allocation (header + inline lock + payload), handle atomic-rc, payload touched only inside `update`/`read`, egress sendable. A second refcount wrapper around it, or a cross-thread rc op on a bare Locker handle, is a bug. (Row spliced into §8.)

IDs skip I20: that name is taken by Amendment I20, which patched I9.

\### Supersedes / preserves

\- \*\*Supersedes\*\* Amendment D's pairing clause ("shared mutable state is `Arc<struct{ lock: Locker; …data }>`") — the measured two-cell hazard.

\- \*\*Preserves\*\* Amendment D's Arc mechanics (IsAtomic flag, `msAllocArc`, weak Arc TypeInfo, borrow-vs-owning discipline) — they remain the base of both SHARE and the `Locked` handle — and all of Amendment E (discipline rule, Tier 1 adaptive park, Tier 2 drop).

\- Phases 0–9 surface semantics untouched; zero-copy spawn borrows untouched (I3).

\### Impact assessment

\- Compiler self-host: the compiler uses neither Arc nor Locker — inert during self-compile (same argument as Amendment D).

\- Affected shipped artifacts: corpus 405 (rewritten to `Locked<T>`), the `std/core/promise` Locker surface (replaced), `sendable.ms` (pointee + SEND-class rules), `actorLower` msgSetter (boundary incref/release), and the two Arc codegen fixes (trigger 6 — crashes, so no working behavior depends on them).

\- Awaited-CALL-with-const-ref sites keep compiling (BORROW). The blast radius of the SEND-class restriction is \*\*measured tree-wide before enforcement lands\*\* — a landing gate, not a model question.

\- JS backend: Arc and Locked remain C-only (`@skip-js`); a js erasure is future work outside this amendment.

\### Implementation order and gates

0\. Fix the two Arc codegen gaps (independent bugs, own regressions).

1\. Pointee rule + boundary refcount + SEND-class restriction — one landing; they cohere (the restriction without the pointee rule kills Arc→SEND; the pointee rule without the boundary incref leaves the raw-pointer hole).

2\. `Locked<T>` (runtime cell + std surface) + the 405 rewrite.

3\. Corpus/guard programs pinning the verbs: the SEND-UAF shape proven red, Arc→actor CALL and SEND, a Locked counter under spawn contention.

Each step gates on the full suite + corpus lanes; the SAN lane on a Linux host for anything touching msgSetter or the cell layout.

\### Implementation notes (steps 0–1, 2026-09-03)

Step 0 landed (`e03ad1e0` + regression `414-arcPodPointee`): the Arc cell wires destroyFn only when the pointee carries owned refs (the ref-array cell's predicate — a POD pointee's hook is dropped by reachability, so the reference was an undefined symbol at link), and the cell name mangles pointer-shaped pointees (`X*` → `X_star_`) instead of emitting an invalid identifier.

Step 1 landed with two refinements the rule text anticipated only implicitly:

\- \*\*Pointee predicate is stricter than isTypeSendable.\*\* `isArcPointeeSendable` rejects arrays anywhere inside the pointee: an array is sound as a \*moved\* message argument (ownership travels) but stays mutable through an Arc handle, which would break SHARE-immutability from the inside. Same reasoning bans any Ref (locks included) and, today, distinct/alias wrappers (conservative).

\- \*\*SHARE immutability is enforced at the write site.\*\* The checker rejects any write whose member/index chain passes through an Arc handle (`a.f = 1`, `holder.box.n = 1`, `a.arr[i] = 1`, `++a.f`) — peeling through the HiddenDeref the checker inserts for member access on a Ref. Rebinding a handle SLOT (`holder.box = otherArc`) stays legal: its prefixes stop at `holder`.

Mechanics as specified: `msMsgSetPtrShared` (actor.h) takes the message's atomic incref at pack; every generated \_impl — sync and suspending — releases exactly once via a synthesized try/finally (early returns and async suspension both ride the finally). Measured: the 2000-SEND churn probe that read freed memory deterministically (2000 × junk.a) now reports `seen=2000` 5/5-shaped runs; corpus 405 carries `@xfail` on its three lanes until the step-2 `Locked<T>` rewrite flips them (XPASS is the cue). The SEND-class diagnostic and the discarded-CALL borrow diagnostic (via the checker's statement-position tracking) both cite I21.

Known follow-ups outside this landing: `move`-passed Arc/refs still leak one reference per message (pre-existing move-arg accounting, unchanged by the boundary incref); async actor methods with Arc args release correctly via the finally, but the plain-ref BORROW on an async CALL keeps its park-based soundness rather than a reply-edge proof; the SAN lane for the msgSetter touch still needs a Linux host run.

\### Road not taken

Incref-at-boundary for \*\*every\*\* ref — the shared-heap model. Sound only with atomic rc everywhere or a cross-thread tracing collector; it dissolves MOVE (why transfer when sharing is free), taxes every message with rc traffic, and still races contents — a refcount buys liveness, not exclusion. MS's DRC is deliberately single-owner; this amendment keeps atomicity in exactly one place per role: SHARE's boundary/handle, and `Locked`'s handle.

\### Rationale

Amendment D shipped Arc as a memory primitive and the bare Locker, pairing them by usage convention. Measured: the convention's only exemplar is the mixed-rc two-cell shape; the carve-out that lets const refs cross raw is a deterministic UAF under SEND; and the Locker handle's rc cannot survive the cross-thread sharing it exists for. The verb model closes each hole with machinery that already exists (D's atomic rc, E's ticket lock and park, D's sizeof fix) and gives Arc and Locked non-overlapping, model-mandated roles: SHARE-immutable, and shared-mutable. "When do I use which" stops being judgment and becomes the two-line rule the model states.

\*\*End of PARALOCK.\*\* Lock applied 2026-04-05. Amendment A applied 2026-05-21. Amendment B applied 2026-06-08 (generalized selector→engine wake + io\_uring arm, verified on Linux 6.8, 2026-06-09). Amendment C applied 2026-06-20 (actor wasEmpty schedule gate + markEmpty-last deschedule, verified deterministic-TSan + suspension + churn). Amendment D applied 2026-06-22 (Arc<T> shipped + validated). Typed Mutex<T> evaluated and dropped 2026-06-24 — a redundant, unenforceable composition; the lock primitive is the bare Locker (std/core/promise), shared-mutable state is Arc<struct{lock: Locker}> (validated arc-locker-shared-counter total=12000, drc+orc). The enabling sizeof-T-monomorphizes fix is kept as a general correctness fix. Amendment E applied 2026-06-25 (Locker discipline rule documented; Tier 1 adaptive spin→park shipped — `futex`/`\_\_ulock`/`WaitOnAddress`, verified macOS: arc-locker `total=12000` drc+orc, and 0-CPU park under 1s contention vs spin's \~4 core-seconds; Tier 2 awaitable lock dropped — actor is the awaitable serializer). Amendment F applied 2026-07-02 (struct-valued futures standardized on one BOXED representation — async struct/tuple/GI returns now box via msSinkBoxStruct like arrays; String+primitives stay inline; one boxed reader for await + waitFor, zero-touch to the locked cross-thread completion; verified test-native 102/0 drc+orc + self-host + msc test +0 regression). Amendment G applied 2026-07-06 (in-flight ownership of cross-thread completion futures, I16 acquire-before-visible — the queue's completion ref for spawn/doneFut futures is now taken on the owner thread at submit time via msSpawn/msSpawnInto/msAwaitGroupSetDoneFut before the future is visible-as-finished, and the worker completes via msCompletionQueuePushOwned; closes the publish→push UAF, ASAN-proven on Promise<Struct>\[] hammered 40000×/run; count-neutral, gated MS\_FUTURE\_SUBMIT\_REF to the full POSIX MPSC dispatcher; residual concurrent owner/drain decref — worst-case rare leak, never UAF — resolved by Amendment H (deferred decref); verified src/test/native/hammerAsan.sh 200×/200× drc+orc ASAN-slab-off clean + test-native 112/0 drc+orc + self-host drc+orc build+smoke). Amendment H applied 2026-07-07 (deferred decref: future owner-side decref deferred to dispatcher via batched TLS flush at actor-batch / drain / pool-task boundaries — serializes all rc mutations on the future to the dispatcher thread, eliminating the Amendment G residual race without atomic rc; Pony ORCA precedent — one field, one thread; rides on existing 64-msg actor batch + drain-to-empty completion queue + TLS slab; 2.4× cheaper than atomic rc for batched workloads; supersedes Amendment G Residual's atomic-rc resolution; I17 locked. Refinement during integration: per-instance `crossThreadPublished` flag on msFutureBase, set at Amendment-G submit incref time on the owner thread — single-threaded futures (async returns, fire-and-forget) skip TLS defer and inline-decref, eliminating unbounded TLS/MPSC accumulation in tight user loops (leak-discarded-future / leak-async-await-loop guards); cross-thread futures (spawn/doneFut) still defer per spec; verified src/test/native/hammerAsan.sh 200×/200× drc+orc ASAN-slab-off clean + test-native 112/0 drc+orc + self-host drc+orc build+smoke). Amendment I18 applied 2026-07-22 (actor shell teardown/free owner-scheduler-only; stop() marks + wakes — §7.4, §8 I18). Amendment I19 applied 2026-07-22 (pid = generation-checked 53-bit table handle, hazard-pinned lookup, stale-pid ops no-op; pids on all persistent cross-actor edges — §7.4, §8 I19). Amendment I4/I5 applied 2026-07-22 (Phase 6 static rules S1/E61 + S3/E62 enforced in the checkSpawnCaptures walk — deep write ban per Pony box, method-on-this rejection, HiddenDeref peeling; Phase 9 E40 sequential-await-spawn warning in all five loop checkers, suggested fix names Promise.all; E41 array-await recorded designed-unimplemented, Promise.all canonical join per I14; §7.3 amendment note; verified src/test/c/actor.ms 10/10 + suite baseline + guard suite). Amendment I locked 2026-09-03 (SHARE verb - Arc pointee sendable + atomic incref at the msgSetter, SEND-class const-ref restricted to awaited-CALL borrows, Locked<T> one fused cell superseding D's Arc<struct{lock}> pairing; deterministic SEND use-after-free measured pre-fix; I21/I22).


