# cparse — C Header Parser (chibicc port in MetaScript)

Standalone C11 header parser, ported from [chibicc](https://github.com/rui314/chibicc)
(Rui Ueyama, MIT). Replaces the regex-based `src/module/cparse.ms` scanner with a
real tokenizer → preprocessor → declaration parser pipeline.

**Status**: scaffold. Not wired into the main compiler. Develops and tests
independently via its own CLI entry (`main.ms`) and test suite (`test.ms`).

---

## Why this exists

The previous scanner (`src/module/cparse.ms`, ~310 LOC) handles 5 syntactic
patterns via string matching. It silently drops or mis-parses:

- Named `struct Foo { ... } Foo;` / forward declarations / unions
- Simple typedefs (`typedef OldName NewName;`)
- Function pointer typedefs
- Bitfields and array fields
- `#if`/`#ifdef` branches (evaluated as text, not conditionally)
- `#define` constants
- `__attribute__` / qualifiers embedded in type strings
- Function parameters that are themselves function pointers
- Enum values that are expressions (`A = 1 << 3`)
- Target-variant primitive sizes (`size_t` hardcoded to `uint64`)

A real parser fixes all of these as a byproduct. Rather than reinvent C
parsing, we port chibicc: ~6.5k LOC of exceptionally clean C designed to be
read and understood.

---

## Scope

**In scope** (what the port covers):

- Full C11 tokenizer: identifiers, keywords, pp-numbers, string/char
  literals (incl. wide/UTF), punctuators, comments, universal character names.
- Preprocessor: `#include`, `#define` (object + function + variadic macros),
  `##` paste, `#` stringify, `#if`/`#elif`/`#else`/`#endif`, `#ifdef`/`#ifndef`,
  `defined()`, `#undef`, `#line`, `#error`, `#pragma once`, `_Pragma`,
  predefined macros (`__FILE__`, `__LINE__`, `__DATE__`, `__TIME__`).
- Type system: primitives, pointers, arrays, functions, structs, unions,
  enums, typedefs, qualifiers, bitfields, flexible array members,
  function pointers.
- Declaration parser: typedefs (all forms), tags (anonymous + named +
  forward-declared), function prototypes (K&R + ANSI), extern variables,
  storage classes.
- Integer constant expression evaluator: literals, unary/binary/ternary,
  `sizeof(primitive)`, `defined()`, macro-identifier lookup.

**Added on top of chibicc** (bindgen concerns chibicc doesn't address):

- **Target-parameterized primitive sizes**: chibicc hardcodes x86-64 Linux
  ILP64. We drive `sizeof`/`alignof`/struct layout from a `TargetInfo` struct
  so FFI bindings are correct across linux/macos/windows/wasm on x86_64 and
  aarch64.
- **Predefined macro tables per target**: `__APPLE__`, `__linux__`,
  `_WIN32`, `__x86_64__`, `__aarch64__`, `__GNUC__`, etc. — set before
  preprocessing so system headers take the correct `#if` branches.
- **`__has_include` / `__has_feature` / `__has_attribute` / `__has_builtin`** —
  required for Apple/Clang headers; not in chibicc.
- **`__attribute__((packed))` / `((aligned(n)))` / `#pragma pack`** as layout
  modifiers on types. Other attributes are parsed and ignored.
- **MS extern emitter**: walks the top-level `Obj` list and `Type` tree,
  emits `extern function`, `extern struct`, `extern enum`, `extern const`,
  `type` aliases. Preserves the `importedNames` filter of the old scanner.

**Out of scope** (parse-and-skip with a diagnostic):

- Function bodies (brace-matched and dropped — this is a header parser).
- Full C expression and statement parsing (except integer constant
  expressions for enum values, array sizes, `#if`).
- C semantic analysis: integer promotion, conversions, VLA semantics,
  `_Atomic` semantics, `_Generic` matching beyond declaration use.
- C17 / C23 extras beyond what chibicc handles (no `_BitInt`, `nullptr`,
  `typeof` as declarator until explicitly needed).
- MSVC ABI bug-for-bug struct layout (Itanium rule only for v1; MSVC
  deferred until Windows SDK binding is attempted).
- Complex numbers, `_Float16`/`_Float128`, `__int128`, vector types —
  parsed-and-skipped; diagnostic names the unsupported construct and the
  decl is dropped, not the whole header.
- Full GCC/Clang `__builtin_*` set — we handle the ones system headers
  actually use (`__builtin_va_list`, `__builtin_offsetof`,
  `__builtin_types_compatible_p`) and parse-skip the rest.

---

## Reference source

Local fork: `~/projects/chibicc` (read-only reference; do not modify).

Chibicc is structured so that each git commit adds exactly one feature.
When porting a specific construct, `git log --oneline` in the chibicc repo
to find the commit that introduced it, then read that commit's diff —
it's often the cleanest explanation.

Files in chibicc and what each maps to in this module:

| chibicc file   | LOC   | Port target           | Notes |
|----------------|-------|-----------------------|-------|
| `tokenize.c`   | 805   | `tokenize.ms`         | C tokens, keywords, literals |
| `preprocess.c` | 1208  | `preprocess.ms`       | Full CPP (the hardest part) |
| `parse.c`      | 3368  | `parse.ms` (subset)   | **Decl parsing only** — we drop ~60% (function bodies, statements, expression codegen) |
| `type.c`       | 307   | `type.ms`             | Type constructors + size/align; we parameterize by target |
| `unicode.c`    | 189   | `unicode.ms`          | UTF-8 encode/decode for wide strings + UCN |
| `hashmap.c`    | 165   | use MS `Map<string,T>`| No port — MS has native maps |
| `strings.c`    | 31    | inline                | Trivial helpers |
| `codegen.c`    | 1595  | **skip**              | We don't emit assembly |
| `main.c`       | 791   | replaced by `main.ms` | Our CLI is a bindgen driver, not a compiler driver |
| `chibicc.h`    | 457   | split across files    | Types live with their owning module |

Total MS port target: ~5–6k LOC (smaller than chibicc because we drop
codegen, function bodies, and most of parse.c's expression/statement
handling).

---

## Module layout

```
src/compiler/cparse/
├── CLAUDE.md         this file
├── index.ms          public API (translateHeader, parseHeader)
├── main.ms           standalone CLI: msc-cparse <header.h> [options]
├── token.ms          TokenKind + Token struct
├── tokenize.ms       C tokenizer (port of tokenize.c)
├── preprocess.ms     preprocessor (port of preprocess.c)
├── type.ms           Type system (port of type.c + target extensions)
├── target.ms         TargetInfo + predefined macro tables (new)
├── parse.ms          declaration parser (subset port of parse.c)
├── obj.ms            Obj (top-level declarations) + Scope
├── eval.ms           integer constant expression evaluator
├── emit.ms           MS extern decl emitter (walker)
├── unicode.ms        UTF-8 + UCN helpers
├── error.ms          diagnostic collection (no exit — longjmp-equivalent)
├── test.ms           unit tests per phase + acceptance tests
└── fixtures/         real C headers for acceptance testing
    ├── minimal.h
    ├── stdio_mini.h
    └── README.md
```

**Rules**:

- **Zero dependencies on the rest of the compiler.** This module imports
  only from `src/utils/` (string helpers, etc.) and standard library.
  It does NOT import from `src/ast/`, `src/checker/`, `src/parser/`, etc.
  The MS extern decl output is a **string** — the main compiler parses
  that string through its normal pipeline.
- **Own test entry**: `bun run run-ms run src/compiler/cparse/main.ms
  <header>` runs the standalone binary. `bun run test-ms
  src/compiler/cparse/test.ms` runs tests.
- **No global state**. All state lives in a `CParseContext` struct
  passed explicitly. (Chibicc uses globals; we pass context.)
- **No `exit()`**. Chibicc calls `error()` → `exit(1)` on any parse
  error. We collect diagnostics into `CParseContext.diagnostics` and
  return a `Result<Output, Diagnostic[]>`. A single bad declaration
  skips that decl and continues parsing the rest of the header.

---

## Pipeline

```
.h file path
    ↓
[1 read file]
    ↓  source text
[2 tokenize]       tokenize.ms    → Token list (preprocessing tokens)
    ↓
[3 preprocess]     preprocess.ms  → Token list (post-macro, #include expanded)
    ↓
[4 parse]          parse.ms       → Obj list (top-level declarations only)
    ↓
[5 emit]           emit.ms        → MS source string (extern decls)
    ↓
MS source string → consumer (main compiler, or stdout for CLI)
```

Phases 1–4 are direct ports of chibicc phases. Phase 5 is net-new.

---

## Divergences from chibicc (intentional)

| Aspect | chibicc | cparse | Reason |
|--------|---------|--------|--------|
| Global state | Heavy | None — explicit `CParseContext` | Re-entrant; MS idiom |
| Memory | Arena (never freed) | Normal MS allocation | DRC handles it; parse is short-lived |
| Errors | `error()` → `exit(1)` | Collect diagnostics, skip bad decl, continue | Bindgen needs best-effort parsing |
| Target | Hardcoded x86-64 Linux | `TargetInfo` parameter | Cross-compilation FFI |
| Output | x86-64 assembly | MS extern decl source | Different use case |
| Function bodies | Fully parsed + codegen | Brace-matched and dropped | Headers only |
| Keywords | All C11 | All C11 (same) | No change |
| Preprocessor | Full chibicc | chibicc + `__has_*` + target macros | Apple/Clang headers |

---

## Testing strategy

**Unit tests** (one per porting phase, live in `test.ms`):

1. **Tokenizer tests**: tokenize a small snippet, assert token kinds + values.
2. **Preprocessor tests**: expand macros, verify `#if` branches take the
   correct path, test `__has_include`.
3. **Type tests**: construct primitives, pointers, arrays, verify size/align
   per target.
4. **Parser tests**: parse typedef/struct/enum/function prototype, assert
   `Obj`/`Type` shape.
5. **Const eval tests**: evaluate constant expressions against known results.
6. **Emitter tests**: parse a small header, emit MS, assert the emitted
   string contains expected extern decls.

**Acceptance tests** (fixtures in `fixtures/`):

Progressive set of real C headers. A header passes acceptance when the
emitted MS extern decls match a golden file (or at least contain a named
set of expected symbols).

1. `minimal.h` — hand-written, every construct we support.
2. `stdint.h` subset.
3. `stdio.h` subset (no FILE internals).
4. `string.h`.
5. `pthread.h` — stress test: opaque handles, function pointers, attributes.
6. `sqlite3.h` — stress test: a real amalgamation, ~200 functions.

A header that parses without diagnostics AND emits symbols the test
declares required AND compiles as MS source counts as passing.

**Running locally**:

```bash
# All cparse tests
rm -rf out && bun run test-ms src/compiler/cparse/test.ms

# Standalone CLI on a real header
bun run run-ms run src/compiler/cparse/main.ms -- /usr/include/stdio.h

# With target override
bun run run-ms run src/compiler/cparse/main.ms -- \
    --target=linux-x86_64 \
    -I/usr/include \
    -D_GNU_SOURCE \
    /usr/include/stdio.h
```

---

## Porting workflow (per phase)

When porting a chibicc file:

1. **Read the chibicc file top to bottom once.** Take notes on data
   structures first, then functions.
2. **Port data structures first** (`Token`, `Type`, `Obj`, `Macro`, etc.).
   Use MS interfaces (reference types) unless profiling shows a struct
   is hot.
3. **Port functions in dependency order** — leaves first. Use `match` over
   chibicc's if/else kind dispatch. Preserve function names (`new_token`,
   `read_ident`, `skip`, etc.) for easy cross-reference.
4. **Port tests commit-by-commit** if feasible: chibicc has a test script
   that exercises features in the order they were added. You can use it
   as a progressive acceptance test.
5. **Write an MS test immediately** after porting each function or small
   group. Don't let unported dependencies stack up.
6. **When you hit something unsupported** (e.g., `_Generic`, `__int128`):
   emit a `Diagnostic` with the source location and the construct name,
   then skip. Do not crash. Do not silently pass.

---

## Intentionally NOT done until later

- **No wiring into the main compiler.** `src/module/cparse.ms` stays as-is
  and remains the default. This module is developed fully standalone.
- **No MSVC ABI layout.** Itanium-only until Windows binding is tried.
- **No C23.** Until we hit a real header that needs it.
- **No C++ anything.** Never.
- **No `#include_next`** until we hit a header that needs it (Apple
  headers use it).
- **No caching.** Parse is fast; cache at a higher layer if/when needed.

---

## Quick reference: chibicc file → MS file mapping for porting

When you're porting and want to find something in chibicc:

| Chibicc function/pattern | Lives in |
|--------------------------|----------|
| `tokenize()`, `read_ident`, `read_int_literal` | `tokenize.c` |
| `preprocess()`, `expand_macros`, `read_if_directive` | `preprocess.c` |
| `declspec()`, `declarator()`, `struct_decl()`, `enum_specifier()` | `parse.c` (lines ~700–1500) |
| `new_type()`, `pointer_to()`, `array_of()`, `func_type()` | `type.c` |
| `add_type()` (type inference) | `type.c` (we mostly don't need this path — headers have explicit types) |
| `eval()` / `const_expr()` | `parse.c` (lines ~3000+) and `preprocess.c` |
| `new_token()`, `copy_token()` | `tokenize.c` |

---

## Concurrency architecture

This module is designed from day one to leverage MetaScript's concurrency
primitives (`spawn()`, `actor {}`). See `docs/LANG-PARALLEL.md`.

**What is and isn't parallelizable in a C parser**:

| Phase                          | Parallelizable? | Why |
|--------------------------------|-----------------|-----|
| Tokenizer within one file      | No              | Stateful scan; boundaries are expensive to reconcile; rarely worth it |
| Preprocessor within one file   | No              | Macro state is inherently sequential (define order matters) |
| Parser within one file         | No              | Tag scopes + typedef disambiguation are sequential |
| **Across files (headers)**     | **Yes**         | Each header is independent once its dependency set is pinned |
| **`#include` resolution**      | **Yes (cached)**| Most includes hit cache; cold misses go to spawn |
| **Diagnostic ordering**        | **Via actor**   | Sink actor merges cross-job diagnostics deterministically |
| Emit phase                     | Possibly        | Cheap enough to run sequentially; revisit if profiling says otherwise |

### Design

Three cooperating components, mapped to the three primitives:

```
                   ┌──────────────────────────┐
   parseJob N ---->│                          │
   parseJob M ---->│  HeaderCache  (actor)    │  memoizes preprocessed tokens
   parseJob K ---->│                          │  keyed by (path, hash, target, defines)
                   └──────────────────────────┘
                          ▲
                          │ lookup / insert
                          │
   spawn(() => parseHeader(h1))   ┐
   spawn(() => parseHeader(h2))   │
   spawn(() => parseHeader(h3))   │  Promise.all — structured concurrency
   ...                            │  each job runs tokenize→preproc→parse→emit
   spawn(() => parseHeader(hN))   ┘  on its own worker thread
           │
           │ diagnostics as they occur
           ▼
   ┌──────────────────────────┐
   │ DiagnosticSink (actor)   │  merge-sorts by (file, line, col)
   │                          │  deduplicates across re-includes
   └──────────────────────────┘
```

### Components

#### 1. `spawn()` — per-header parse jobs

```metascript
// main.ms — binding multiple headers concurrently
export async function bindHeaders(
    paths: string[],
    target: TargetInfo,
    cache: HeaderCache,
    sink: DiagnosticSink
): Promise<string[]> {
    const jobs: Promise<string>[] = [];
    for (const p of paths) {
        jobs.push(spawn(() => parseHeader(p, target, cache, sink)));
    }
    return await Promise.all(jobs);
}
```

- Each header → one `spawn(() => parseHeader(...))`.
- `Promise.all` gives structured concurrency: jobs complete before caller
  returns, so `target` and `cache` can be borrowed (Rule 3 SHARE) without
  copying.
- Worker pool sized to CPU cores automatically.
- Backpressure: queue full → execute inline on caller.

**When this helps**: binding a library with many headers (SDL, Vulkan,
sqlite amalgamation split across files). Hundreds of headers bind in
parallel.

**When this doesn't help**: a single header. `spawn()` has a small constant
overhead; for one header, call `parseHeader` directly.

#### 2. `HeaderCache` actor — deduplicated `#include` expansion

`#pragma once` + header guards mean the same header is included many times
during a single binding job, and across multiple jobs. Without caching,
we'd re-tokenize `stdio.h` once per dependent header. The cache actor
memoizes the fully preprocessed token stream:

```metascript
actor HeaderCache {
    private entries: Map<string, CachedTokens> = new Map();

    // CALL: worker asks for a header's preprocessed tokens
    async get(
        path: string,
        target: TargetInfo,
        defines: readonly Define[]
    ): Promise<CachedTokens> {
        const key = makeKey(path, target, defines);
        let hit = this.entries.get(key);
        if (hit !== null) return hit;

        // cold miss — tokenize + preprocess on this actor's thread,
        // or offload via spawn if large. Result cached for all future callers.
        const tokens = await spawn(() => tokenizeAndPreprocess(path, target, defines));
        this.entries.set(key, tokens);
        return tokens;
    }

    // SEND: explicit invalidation if a header file changes on disk
    invalidate(path: string): void {
        // drop all entries whose key starts with path
    }
}
```

- **Key** = `(canonical path, content hash, target triple, active defines)`.
  Same file under two different `-D` sets = two cache entries.
- **Actor isolation** guarantees no data races on the map — no explicit
  locking needed. Many parse jobs can hit the same cache concurrently
  via `await cache.get(...)`.
- **CachedTokens** is immutable after insertion; returned pointer is
  safe to share (Rule 3 SHARE, zero-copy).
- **Cold miss handling** offloads the actual tokenize+preprocess to
  `spawn()` so the actor's mailbox isn't blocked on I/O/CPU.

**When this helps most**: a large binding job. Hundreds of
`#include <stdio.h>` across dependent headers → one cache entry,
one tokenize, N quick lookups.

#### 3. `DiagnosticSink` actor — ordered diagnostic merging

Parallel parse jobs emit diagnostics in nondeterministic order. The sink
actor accepts diagnostics as fire-and-forget sends, and on final flush
returns them sorted by `(file, line, col)`:

```metascript
actor DiagnosticSink {
    private diags: Diagnostic[] = [];

    // SEND — fire and forget, zero back-pressure on parse workers
    report(diag: Diagnostic): void {
        this.diags.push(diag);
    }

    // CALL — flush at end, deterministic ordering
    async flush(): Promise<Diagnostic[]> {
        const sorted = [...this.diags];
        sorted.sort((a, b) => cmpDiag(a, b));
        this.diags = [];
        return sorted;
    }
}
```

- `report()` returns `void` → SEND, queued and returns immediately.
  Parse workers never block on diagnostic reporting.
- `flush()` returns `Diagnostic[]` → CALL, awaited once at the end.
- Sink is a single actor, so ordering is deterministic even with
  many producers.

### Transfer rules in practice

| What is shared across workers         | Rule    | Why it's safe |
|---------------------------------------|---------|---------------|
| `TargetInfo`                          | SHARE   | All fields const after construction |
| Predefined macro tables               | SHARE   | Static tables, never mutated |
| `CachedTokens` returned from cache    | SHARE   | Immutable after insertion |
| `HeaderCache` itself                  | (actor) | Accessed only through mailbox |
| Source text strings                   | SHARE   | MS strings are immutable value types |
| Parse result `Obj[]` returned to main | MOVE    | Ownership transfers from worker back to caller on resolve |
| Diagnostics                           | COPY    | Small; simpler than MOVE for fire-and-forget |

### What we explicitly do NOT parallelize

- **Tokenizer splitting within one file**. Stateful lookahead,
  string-literal boundaries, comment nesting. Not worth it.
- **Macro expansion within one file**. Order-dependent (`#define FOO 1`
  then `#undef FOO` then `#define FOO 2`).
- **Parser within one file**. Tag scope + typedef disambiguation
  are sequential.
- **Emitter sub-walks**. Cheap enough that spawn overhead outweighs
  speedup. Revisit only if profiling says so.

### `.parallel()` — future use (PLANNED)

When `.parallel()` lands (see `docs/LANG-PARALLEL.md` Phase 7), these
sites become trivial one-liners:

```metascript
// today — spawn + Promise.all
const jobs = paths.map(p => spawn(() => parseHeader(p, ...)));
const results = await Promise.all(jobs);

// future — .parallel()
const results = await paths.parallel().map(p => parseHeader(p, ...)).collect();
```

Migrate when available. The spawn form works today and is not going
away — `.parallel()` just shortens it.

### Concurrency testing

- Unit tests run single-threaded by default.
- **Stress test**: a test that binds 50 fixture headers in parallel via
  `Promise.all(spawn(...))`, then asserts the union of emitted decls
  matches the sequential-binding golden. Verifies no races, no lost
  diagnostics, deterministic output.
- **Cache hit-rate test**: bind the same header 100 times in parallel,
  assert `HeaderCache` performs exactly 1 cold tokenize.

### Performance budget

| Scenario                              | Target       |
|---------------------------------------|--------------|
| Single `stdio.h` cold                 | < 20 ms      |
| Single `stdio.h` warm cache           | < 1 ms       |
| 50-header binding, cold, 8 cores      | < 300 ms     |
| 50-header binding, warm, 8 cores      | < 50 ms      |
| Sequential 50-header baseline         | ~1500 ms     |
| Expected speedup from parallelism     | ~5×          |

Numbers are targets, not guarantees. Measure before optimizing.

---

## Success criteria (v1)

1. Standalone CLI parses `stdio.h`, `stdint.h`, `string.h` on macOS and
   Linux with zero crashes.
2. Emitted MS extern decls compile and the resulting MS FFI bindings link
   against libc.
3. Every feature the current `src/module/cparse.ms` scanner handles is
   also handled here (strict superset).
4. At least one header the current scanner mis-parses (likely `pthread.h`
   or anything with function pointer typedefs) parses correctly here.
5. Full MS test suite passes (`bun run test-ms src/compiler/cparse/test.ms`).

Once v1 passes, open a wiring task to route `importCHeader` through
this module behind a flag, then migrate headers one at a time.
