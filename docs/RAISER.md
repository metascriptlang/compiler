# Raiser VM — design & status

Raiser is MetaScript's statically typed bytecode VM. It covers what the C backend (shipping native binaries) and the JS backend (browser, edge) cannot: evaluation inside the compiler, and runs that need no C toolchain. The rules a session editing the code must hold are in [`src/raiser/CLAUDE.md`](../src/raiser/CLAUDE.md) (the VM) and [`src/codegen/raiser/CLAUDE.md`](../src/codegen/raiser/CLAUDE.md) (AST → bytecode); the VM's place in the pipeline and the `CallHost` mechanism are in [`PIPELINE.md`](PIPELINE.md).

## Roles

| # | Role | State |
|---|---|---|
| 1 | Comptime engine: `@comptime` blocks and macros during compilation | in use |
| 2 | IDE eval loop: long-running runtime for inline eval and hot redefinition | not built; `src/raiser/repl.ms` is an execution demo |
| 3 | Embeddable scripting / sandboxed eval | the `context.ms` API exists; nothing outside the compiler uses it |
| 4 | Game-logic scripting on a client that cannot ship native code: the Lua / AngelScript niche, logic above the render loop, not the loop | not built |

`msc run <file> --target=raiser` also runs whole checked programs, multi-module, for tooling. The measured consumer is the Ion project generator: a typed manifest resolves a graph, emits an Xcode project, builds an app and runs its window smoke with no native manifest-evaluation fallback (not re-run here).

Non-goals: a JIT, competing with browser engines, a 60 fps render loop, a large stdlib of its own. The thesis is that a dynamic-language JIT exists mostly to infer types at runtime; MetaScript types are resolved at compile time, so `int32 + int32` is already a typed opcode and an interpreter can close much of the gap without one.

## Memory model

Two regimes, chosen per VM by `gcMode`:

| Roles | `gcMode` | Reclamation |
|---|---|---|
| comptime (1), sandbox (3) | `"arena"`, the default of `createVM` and `createContext` | none per value; the heaps die with the evaluation |
| long-lived (2, 4) and every `msc run --target=raiser` (`cmdRunRaiser` sets it) | `"orc"` | refcount on store and overwrite, plus a trial-deletion cycle collector once the live count passes `gcThreshold` (256) |

- **Why not an arena for the long-lived roles** — nothing bounds their scope; a growing arena leaks and a per-tick reset corrupts state held across ticks.
- **Why not a tracing GC** — the C backend destroys deterministically (`--gc=drc` / `--gc=orc`); a tracing Raiser would run `defer` and destructors at other times, so one source would behave differently per target. RC plus a cycle collector is also what AngelScript, Squirrel and GDScript use, and it has no stop-the-world pause.
- **Why it is simpler than on C** — VM objects describe themselves (`fields: RaiserObjectField[]`), so one generic trace and one generic destroy cover every type; C needs per-type type info and generated trace / destroy procs.
- **What is built** — `rc` and `color` on each heap entry and a free list that reuses slots (`value.ms`), `rcIncref` / `rcDecref`, the collector in `orc.ms`. RC placement is VM-intrinsic (the VM counts at stores), not the Phase 4 analyzer: Raiser runs `transformForRaiser` and skips the analyzer.

**Strands own heaps.** Each strand has its own array and object heap; a future owns the heap its value lives in, the shape of C's future struct holding its value. `copyGraph` moves a value between heaps, preserving sharing and stopping on cycles through a source → destination map. Crossings: at `spawn`, the closure env and a copy of every global slot; at completion, the result into the future; at `await`, the result out to the reader. So a strand's writes to captured or global state are invisible to its parent.

## std access — three tiers, scoped per role

| Tier | What | Admission |
|---|---|---|
| 0 | VM opcode | not expressible in MS: string identity / length / index, array index / length / push / set-length, arithmetic. Chosen for representation, never for speed |
| 1 | Host bridge (`CallHost`, `src/compiler/meta/hostTable.ms`, 105 `registerHostFn` entries) | needs host state or representation: fs, process, env, string ↔ bytes. Needs a written reason |
| 2 | Portable MS (`std/core/string/shared.ms`, `std/core/array/index.rms`) | everything derivable; shared with the C and JS backends |

The bridge table is compiler-side, so Tier 1 exists only where a host compiler does: roles 1 and 2. Roles 3 and 4 get whatever minimal surface the embedder supplies, so their stdlib has to come from Tier 2. Answering "Raiser needs X" with "add a bridge" is a role-1-only answer.

A call to an extern with no bridge compiles with `raiser warning: no host bridge for '<name>'` at the call site and fails at runtime with `Unknown host function: <name>`. It is a warning, not an error, because std bodies the program never calls may contain unbridged externs.

## Execution budget

The VM stops after `loopLimit` backward jumps (default 10M):

```
raiser runtime error: interpretation requires too many iterations (limit 10000000); if you are sure this is not a bug in your code, raise it with --max-vm-iterations=<n>
```

A 20M-iteration loop fails with that message and prints `20000000` with `--max-vm-iterations=30000000`. The unit is back-edges because a per-instruction budget taxes Tier-2 std by the length of its loop bodies. On 2026-09-04 an identical comptime `startsWith` folded at N = 450k through a host bridge and died at N = 35k as pure MS, which made "foldable" depend on which tier supplied a function (not re-run here).

## Status on `--target=raiser`

Measured 2026-09-19 with `msc` v0.2.55 (`~/.metascript/BUILD` `bce99dbf`), each probe also run on `--target=c` as control:

| Probe | Raiser | C |
|---|---|---|
| functions, `for..of`, interface, `match` + enum, `Result` + `try`, class + `new` + field initializer + method, closure capture, generic function | all correct in one program | same |
| struct copy on assignment, array shared by reference, module-level `let` mutated by a function | `1 9 3 3 2` | same |
| `spawn(() => …)` then `await` | `1 5 2 3 42`: the worker runs when the reader parks | same |
| `spawn(namedFunction)` | `spawn expects a closure`, rc 1 | correct |
| try/catch across a call, `return` inside try/finally, `throw "s"` | correct | correct |
| try/finally nested in a try/catch of the same frame | finally runs twice, outer catch lost, rc 0 | correct |
| the same nesting with the inner try in a called function | correct | correct |
| throw in a strand, reader catches and reads `e.message` | `expected an object, got value kind String`, rc 1: the failure crosses as a string | correct |
| throw in a strand, reader catches without reading it | correct | correct |
| discarded `spawn` | rejected by the checker (affine rule), so the orphan-rejection path is reachable only from VM tests | same |
| `process.exit(3)` | prints up to the call, rc 3 | — |
| array index out of bounds | `raiser runtime error: array index out of bounds: 99 (length 3)`, rc 1 | — |
| uncaught `throw` at top level | `unhandled exception: [object]`, rc 1 | — |
| `"42".parseInt()`, `parseFloat`, `fromCodePoint` | `43 1.5 A` | same |
| `substring` | unbridged: warning, then `Unknown host function` | correct |
| `Promise.all`, `sleepAsync` | unbridged | correct |
| `new Set<int32>()` then `add` | `attempt to access a nil address` in `Set_add__int32`, after `msMapFatal` unbridged warnings | correct |
| `msc run src/index.ms --target=raiser` (the whole compiler) | 16 type errors before codegen: `Undefined variable 'fetch'` ×14, `'Buffer'` ×1, `byteLength` arity ×1 | — |

The three wrong results on strands and exceptions have compiler inbox cards dated 2026-09-19. Codegen-side gaps (`new Array<T>(n)`, `extends`, `static`, `out`) are listed in `src/codegen/raiser/CLAUDE.md`.

Test lanes at the same commit: `msc test src/raiser/value.ms` 333/333, `src/raiser/vm.ms` 519/519, `src/codegen/raiser/eval.ms` 2449/2449 (each count includes the file's dependencies).

## Performance

`fib(27)`, minimum of 5 runs, VM time = raiser run of `fib(27)` minus raiser run of `fib(1)` (so parse, check and bytecode generation drop out). Measured 2026-09-19 at load 16–20 on 14 cores:

| | time | VM ÷ this |
|---|---|---|
| native `--danger`, whole process | 4.0 ms | 110× |
| native default (`-O0`), whole process | 6.5 ms | 68× |
| Raiser, VM part | 440.9 ms | — |
| Raiser, fixed cost (`fib(1)` run) | 652.9 ms | — |

So Raiser suits small inputs. The per-slot boxed `RaiserValue` register file and per-op value allocation are the known costs. The `spike/` prototypes (untagged `number[]` registers, instructions packed into one `number`) measured about 5× over the boxed loop earlier; they no longer type-check (18 implicit `number → int32` narrowing errors), so that number is not re-measured.

## Bytecode

`RaiserInstruction` is a record `{ op, a, b, c, cachedIdx, line }`, not a packed word. ABx and Ax are views over it: `Bx = b·256 + c`, `Ax` = signed 24 bits over `a`, `b`, `c`. `cachedIdx` is a per-instruction inline cache for `LoadField` / `StoreField`, which otherwise look fields up by name.

74 opcodes, 74 dispatch arms:

| Family | Opcodes |
|---|---|
| memory | LoadConst, Move, LoadNil |
| i64 | AddI64, SubI64, MulI64, DivI64, ModI64, NegI64; BeqI64 … BgeI64 (compare-and-skip) |
| f64 | AddF64, SubF64, MulF64, DivF64, NegF64; BeqF64 … BgeF64 |
| bitwise | BitAnd, BitOr, BitXor, BitNot, ShiftLeft, ShiftRight, ShiftRightU |
| control | Jump, Call, CallIndirect, Ret, Halt, Print |
| array | NewArray, LoadIndex, StoreIndex, ArrayLen, ArrayPush, ArraySetLen (truncate or nil-extend: the heap's only shrink) |
| object | NewObject, LoadField, StoreField |
| string | ConcatStr, EqStr, NeStr, LtStr, LeStr, StrLen, StrByteLen, StrCharAt, StrSlice |
| host, nil | CallHost, IsNil |
| strands | Yield, Spawn, Await |
| exceptions | Try, Catch, Finally, FinallyEnd, Throw |
| diagnostics, conversion | Trap, NarrowU, SignExtend, Conv |
| tooling runtime | CopyValue, LoadGlobal, StoreGlobal |

Exceptions follow a safepoint model. `Try` pushes a safepoint. `Catch` is never executed: the unwinder reads its operands (the register to bind, the end of the guarded block). `Finally` pops the safepoint on the normal path. `FinallyEnd` resumes whatever the finally interrupted: the `Throw` still unwinding or the `Ret` still returning. Codegen emits a `Finally` for every `try`, with or without a finally clause, and the catch body jumps past it because the unwinder already popped that safepoint. The surface has one untyped catch clause, so there is no chain of typed handlers.

## Not built

Each checked by grep over `src/raiser`, `src/codegen/raiser`, `src/compiler/meta`: offset-based field access (`LoadFieldOffset`), typed I32 / U32 / U64 / F32 opcodes, arity-specialized `Call0`–`Call4`, a `CallExtern` that calls linked natives through function pointers, any C mirror of the dispatch loop (computed goto or threaded), the IDE eval protocol (`evalForm`, watch opcode), a binary bytecode file format.

## Out of scope

| Feature | Why |
|---|---|
| JIT | static types close most of the gap without one |
| tracing GC | breaks destruction parity with C; long-lived roles use ORC |
| threads, sockets, regex | use the C or JS backend |
| file I/O for roles 2–4 | role 1 has fs through Tier 1; the other roles get what the embedder supplies |
| 60 fps render loop | needs a JIT; role 4 is the logic layer above it |

## Probing Raiser

- `msc` loads std and runtime from beside its own binary: editing `std/` in a checkout changes nothing for the installed `msc` (warnings name `~/.metascript/std/…`). Probe a std edit with a binary whose root holds the edited std.
- `cmdRunRaiser` prints the program's output only after the VM stops, so a hang shows nothing at all. Run under `timeout`.
- Run the same probe on `--target=c` before blaming Raiser: the prelude is target-agnostic, so a hole in a `.rms` surface breaks unrelated programs with errors that point into `std/`.

## Not verified here

- The Ion generator consumer and the 2026-09-04 `startsWith` budget measurement were not re-run.
- ORC was not exercised by a cycle-collecting probe here; only the code paths were read (`orc.ms`, the `gcMode` gates in `vm.ms`).
- `bytecode.ms` comments still say "32-bit instructions" and justify appending opcodes at the end of the enum by a `vm_dispatch.c` that hardcodes their numbers; neither holds (see Bytecode, Not built). Opcodes are still appended at the end by convention.
