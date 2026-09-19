# Build Performance — Roadmap

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
comparison is open. Cache and load traps: [`TESTING.md`](TESTING.md).

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
