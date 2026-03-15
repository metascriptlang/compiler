# Concurrency — Promise, Spawn, AbortController

MetaScript concurrency uses TypeScript surface syntax with systems-level execution underneath.

```
┌─────────────────────────────────────────────────────────────────┐
│                    MetaScript Concurrency                       │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │  Promise<T>  │  │    spawn     │  │   AbortController     │ │
│  │  async/await │  │  thread pool │  │   AbortSignal         │ │
│  │  ✅ DONE     │  │  ✅ DONE     │  │   ✅ DONE             │ │
│  └──────┬───────┘  └──────┬───────┘  └───────────┬───────────┘ │
│         │                 │                       │             │
│  ┌──────┴─────────────────┴───────────────────────┴──────────┐  │
│  │                   Promise.all / Promise.race               │ │
│  │                        ✅ DONE                             │ │
│  └──────────────────────────┬────────────────────────────────┘  │
│                             │                                   │
│  ┌──────────────────────────┴────────────────────────────────┐  │
│  │                    C Runtime Layer                         │ │
│  │  future.h │ dispatch.h │ thread.h │ pool.h │ combinator.h │ │
│  │  abort.h  │ selector.h │ pool.c   │ combinator.c          │ │
│  │                        ✅ ALL DONE                         │ │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## What's Working (E2E Verified)

### async/await — `examples/testAsync.ms`
```ms
async function helloAsync(): Promise<void> { console.log("hello"); }
async function withAwait(): Promise<void> { await helloAsync(); console.log("awaited"); }
async function chained(): Promise<void> { await helloAsync(); await helloAsync(); }
async function boxed(a: number, b: number): Promise<number> { return a + b; }
```

### spawn + thread pool — `examples/testSpawn.ms`
```ms
extern function msSpawn(fn: () => void): Promise<void> from "msSpawn";
extern function msWaitFor(fut: Promise<void>): void from "msWaitFor";
const fut = msSpawn(workFn);
msWaitFor(fut);
```

### AbortController — `examples/testAbort.ms`
```ms
class AbortController {
    signal: AbortSignal;
    constructor() { this.signal = new AbortSignal(); }
    abort(reason: string): void { ... }
}
const c = new AbortController();
c.abort("cancelled");
c.signal.throwIfAborted();
```

### Promise.all / Promise.race — `examples/testPromiseCombinators.ms`
```ms
extern function msPromiseAll(promises: Promise<void>[]): Promise<void> from "msPromiseAll";
extern function msPromiseRace(promises: Promise<void>[]): Promise<void> from "msPromiseRace";
msWaitFor(msPromiseAll([msSpawn(workA), msSpawn(workB)]));
msWaitFor(msPromiseRace([msSpawn(workA), msSpawn(workB)]));
```

---

## Implementation Map

### Promise (Part 1) — ✅ COMPLETE

| Component | File | Status |
|-----------|------|--------|
| `Promise<T>` type system | types.ms, resolvePass.ms, compat.ms, checkExprPass.ms | ✅ |
| async/await transform | asyncDesugar.ms, asyncBridge.ms | ✅ |
| Value boxing | asyncBridge.ms (msBoxDouble/Bool/Int32) | ✅ |
| Checker return unwrap | checkPass.ms (SymbolFlag.Async) | ✅ |
| C codegen + DRC | codegen/c/types.ms, classify.ms | ✅ |
| Parser async fix | core.ms (peek for comment-safe lookahead) | ✅ |
| Lambda lifting null guards | lambdaLifting.ms | ✅ |
| Promise.all | std/core/promise/combinator.c | ✅ |
| Promise.race | std/core/promise/combinator.c | ✅ |
| msFuture value destructor | future.h (valueDestructor field) | ✅ |

### Spawn (Part 2) — ✅ COMPLETE

| Component | File | Status |
|-----------|------|--------|
| msSpawn + refcount ownership | std/core/promise/thread.h | ✅ |
| Thread pool (Malebolgia-style) | std/core/promise/pool.h/.c | ✅ |
| Backpressure (2nd CV) | pool.c | ✅ |
| Local execution (shouldSend) | pool.c | ✅ |
| busyCount tracking | pool.c | ✅ |
| Thread-safe init (pthread_once) | pool.c | ✅ |
| atexit shutdown | pool.c | ✅ |
| Thread-local msErr | native.c, native.h, future.h | ✅ |
| Exception propagation | thread.h (msFutureFail) | ✅ |

### AbortController (Part 3) — ✅ COMPLETE

| Component | File | Status |
|-----------|------|--------|
| AbortSignal class | std/core/system/index.ms | ✅ |
| AbortController class | std/core/system/index.ms | ✅ |
| Constructors | index.ms (new AbortController() initializes signal) | ✅ |
| Instance methods | abort(), throwIfAborted() | ✅ |
| Static factory | AbortSignal.abort(reason) | ✅ |
| C runtime | abort.h (msAbortThrow) | ✅ |

### Codegen Fixes (Part 4) — ✅ COMPLETE

| Fix | File | Status |
|-----|------|--------|
| Class instance method ExtCall flag | checkExprPass.ms | ✅ |
| Name mangling (safeName mismatch) | declarations.ms | ✅ |
| NewExpr calls constructor | expressions.ms, context.ms | ✅ |

---

## Design Decisions

### Memory Ownership: Borrow by Default
```
Default (bare):                     Explicit move:
  spawn(() => process(data))          spawn(() => consume(move data))
  ↓                                   ↓
  Thread borrows data (readonly)      Thread OWNS data (exclusive)
  Caller must await before exit       Caller can exit immediately
  Zero-copy, NF_CURSOR protection     Zero-copy, wasMoved on source
```

### Spawn Architecture: Malebolgia-Style Pool
```
msSpawn(closure) → msPoolSubmit(ctx)
  ↓
  Queue full + all busy? → execute inline on caller thread
  Queue full + workers free? → wait for space (backpressure)
  Queue has space? → enqueue + signal worker
  ↓
  Worker: dequeue → msSpawnWorkerRun → msFutureComplete
```

### Promise.all/race: Callback State Machines
```
Promise.all:  N callbacks share state {remaining, values[], failed}
              Last callback frees state. First failure wins.
              Result future gets valueDestructor = free.

Promise.race: N callbacks share state {settled, remaining}
              First settlement wins. Last callback frees state.
```

### Promise.allSettled/any: Callback State Machines
```
Promise.allSettled: N callbacks share state {remaining, inputs[]}
                    Never short-circuits. Last callback completes result.
                    Always resolves — never rejects.

Promise.any:        N callbacks share state {resolved, rejected, remaining}
                    First fulfillment wins. Rejects only if ALL reject.
                    Inverse of Promise.race.
```

### new Promise(executor)
```
new Promise<T>((resolve, reject) => { ... })
  → msPromiseNew(executor)
  → Creates msFuture* + resolve/reject closures
  → Calls executor synchronously
  → resolve/reject share env with settled flag (first call wins)
```

### Promise<Result<T,E>> Safety (Compiler-Enforced)
```
V1: throw banned in async fn returning Promise<Result<T,E>>
    → "use Result.err() instead"

V2: bare await on Promise<T> banned in same context
    → must use "try await ... catch ..." to handle rejection
    → await Promise<Result<T,E>> is always OK (already typed errors)

Together: airtight guarantee that Promise<Result<T,E>> NEVER rejects.
```

### AbortController: ECMAScript-Compatible
```
new AbortController() → constructor initializes signal
controller.abort("reason") → sets signal.aborted = true
signal.throwIfAborted() → raises AbortError if aborted
Works with spawn, async, Promise.all — model-agnostic
```

---

## Roadmap

```
✅ DONE:
   Promise<T> type system            TypeKind.Promise, resolver, compat, codegen
   Phase A: Async with await          inline stepper state machine
   Phase B: Value boxing              msBoxDouble/msBoxBool/msBoxInt32
   Phase C: Checker return unwrap     SymbolFlag.Async + Promise<T>→T
   Phase D: Promise.all/race          combinator.h/.c — callback state machines
   C codegen + DRC                    msFuture*, needsRC, isPointerType, lifecycle
   C runtime                          future.h, dispatch.h/.c, thread.h, pool.h/.c
   Spawn V1 + thread pool             Malebolgia-parity (backpressure, local exec)
   AbortController/AbortSignal        class with constructor + instance methods
   Codegen: class instance methods    ExtCall flag + mangling fix + constructor calls
   E2E: all 4 test files pass         testAsync + testSpawn + testAbort + testCombinators

   Promise.resolve / Promise.reject   combinator.h — msPromiseResolve/msPromiseReject
   Await in loops                     NOT A GAP — splitWhile + stepper already handles it
   Promise.then / .catch / .finally   @builtin — msFutureThen/Catch/Finally
   Promise.allSettled                  combinator.c — never rejects, waits for all
   Promise.any                         combinator.c — first fulfillment wins
   new Promise(executor)               msPromiseNew — resolve/reject closures
   Promise<Result<T,E>> safety         V1: throw-ban + V2: unguarded await ban

📋 NEXT:
   Spawn borrow checker               ~100 lines — NF_CURSOR + must-await enforcement
   std/thread prelude                  ~10 lines — import { spawn } from "std/thread"
   move in spawn closures             ~50 lines — MoveExpr + wasMoved per-variable

🔮 LATER:
   Promise.withResolvers              ~30 lines — ES2024 deconstructed resolve/reject
   AbortSignal.timeout(ms)            ~30 lines — timer-based auto-cancel (needs dispatcher)
   Locker<T> + TicketLock             ~120 lines — thread-safe mutable sharing
   parMap/parApply/parReduce          ~100 lines — parallel algorithm sugar
   Slice disjointness proof           ~400 lines — reference-aligned implementation
```
