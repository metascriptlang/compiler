# MetaScript Self-Hosted Compiler

Self-hosted compiler for the MetaScript language, written in MetaScript (.ms files). Targets C and JavaScript backends (Erlang postponed).

## Git Rules

**NEVER** use `git stash`, `git reset`, `git checkout .`, `git restore`, or any command that discards, overrides, or resets the current working tree state. The working tree contains in-progress work that must not be lost.

## Shared Worktree

A long-lived git worktree is kept at `/tmp/verify-parent` for HEAD-clean verification (binary search a regression, build at a specific commit without touching the main tree, etc.). **Do NOT remove it.** Reuse across sessions.

To re-check it out at a different commit:
```bash
cd /tmp/verify-parent && git checkout <commit-ish>
# Then re-sync untracked-but-required content from the main tree:
cp -R /Users/le/metascript/recompiler/vendor /tmp/verify-parent/
cp -R /Users/le/metascript/recompiler/examples /tmp/verify-parent/
```

**Untracked required content** (mostly not in git — must be copied in):
- `vendor/` innards — git tracks almost nothing under it; without it `@compile` fails (e.g. mbedtls `psa_util.c`). NEVER run `sync-local-binary.sh` from a worktree missing `vendor/` — its `rsync --delete` wipes `~/.metascript/vendor/`.
- `examples/` — LSP lifecycle tests read the phase5/phase6 fixtures; missing → 9 reds (`src.length > 0`).

Note: at an arbitrary historical commit, runtime/std/net/etc. uncommitted changes from the main tree may also be needed for the build to succeed end-to-end.

## Build Commands

```bash
# Run tests — msc compiles a C test binary and runs it. Output is vitest-style
# (per-file counts + totals). `msc test <file>` runs that file + its transitive
# dep tests. NOTE: no --filter/--jobs flags.
msc test src/index.ms                 # full compiler suite, native
msc test src/utils/string.ms          # one file (+ its deps)

# Corpus tier — real binaries per program, two SEPARATE lane runs (both must
# be green to ship). The runners test ./msc (the freshly built binary) when it
# exists, else the installed msc; MSC=<path> overrides. Which command when:
# src/test/CLAUDE.md §5.0.
msc run src/test/corpus/run.ms                 # parity (C↔JS) + RSS (drc/orc), ~19 min
MSCORPUS_SAN=1 msc run src/test/corpus/run.ms  # ASan + DRC ledger, ~10 min
MSCORPUS_FILTER=leak msc run src/test/corpus/run.ms   # substring subset
src/test/guard/run.sh                          # lifecycle guards (proven-red)

# Run without tests (build + run natively)
msc run src/index.ms

# Run a single example
msc run examples/actorSpawnBasic.ms

# Compile to C only (no run)
msc build examples/actorSpawnBasic.ms --target=c

# Build the optimized self-host compiler binary → ./msc.
# One command on every platform: --danger means "fastest the resolved
# toolchain can link" — thin LTO where that links (Linux zig, macOS clang),
# no LTO + a notice where it cannot (macOS/Windows zig — see
# "Build Optimization" below). Add --cc=clang on macOS to actually get LTO.
msc build src/index.ms --gc=drc --danger --output=msc

# Sync the freshly built msc + support trees to ~/.metascript/
# so downstream projects (Neon, apps, etc.) pick it up via $PATH
./tools/sync-local-binary.sh          # full sync
./tools/sync-local-binary.sh --check  # dry-run, show diffs
./tools/sync-local-binary.sh --no-binary  # support trees only

# Rebuild editor plugins (after grammar.js or highlights.scm changes)
bash tools/editor-plugin/build.sh --install
```

**See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)** for the full build → test → sync → verify workflow and how `~/.metascript/` is kept in sync with the local source tree (the public `install.sh` only fetches GitHub releases; dev workflow needs the script above).

## Build Optimization — default `build` is UNOPTIMIZED (`-O0`)

Opt level and LTO are **separate axes**. `modeFlags` (`src/compiler/cc.ms`):
default=`-O0 -g`, `--release`=`-O2`, `--danger`=`-O3`. `--lto=off|thin|full` is
**capability-resolved after the compiler is known** (`resolveLto` in
`src/compiler/cc.ms`, called right after `resolveCC`): `--danger` takes thin
LTO where the resolved compiler can link it and drops it (with a stderr notice)
where it cannot; an explicit `--lto=` against a proven-broken pair fails loud.
GNU gcc never gets LTO by default (a whole-program `-flto` link of this tree
ran 40+ minutes unfinished) and uses the `-flto=auto` spelling, not
`-flto=thin` (gcc rejects "thin" outright). A compiler built with the plain
`build` command runs ~4.5x slower than a `--danger` build.

Fast self-host build on macOS — add `--cc=clang` to get LTO (~13%); without it
zig still builds, just LTO-less (with a notice):
```bash
msc build src/index.ms --gc=drc --danger --cc=clang --output=msc
```
Cross-compiling Linux: `--danger` alone works (zig cc uses LLD there).

**Why macOS/zig can't LTO (verified 2026-07-30 with raw `zig cc` 0.16.0, don't
re-litigate):** `zig cc -O3 -flto` on a native-macOS target fails with
`LTO requires using LLD`, while the SAME zig cross-compiling to
`x86_64-linux-gnu` links `-flto` fine — so it is a Mach-O-target limitation,
not a zig-quality or a config problem. Zig deliberately replaced LLD with its
own Mach-O linker (ziglang/zig#8727) and its LTO path still requires LLD; ELF
keeps LLD, hence Linux is unaffected. **There is no escape hatch through
`zig cc`**: `-flld` is an unknown option and `-fuse-ld=` is silently ignored
(ziglang/zig#18357). The capability table lives in `src/compiler/cc.ms`
(`ltoBroken`), target-scoped.

**Why Windows/zig can't LTO (verified 2026-08-31, zig 0.16.0):** the LTO link
pulls in `zigc.lib`, whose MinGW math-shim exports (`__INF`, `__QNAN`,
`__SNANL`, `nanl`, …) are weak+hidden in bitcode (`lib/std/c.zig` `symbol()`)
and get dropped during LTO internalization — `undefined symbol: __QNANL` at
every opt level; a 3-line `printf` hello.c reproduces. No flag fixes it from
our side (`-lmingwex` etc. all fail). Also target-scoped: cross-compiling to
windows-gnu from any host hits the same shim.

**What it buys (5-round interleaved measurement, phase A on `src/index.ms`):**
the gain is **LTO, not clang** — clang+thinLTO vs clang-noLTO is **~13%**, while
clang-noLTO vs zig-noLTO is **~1%**, i.e. the two drivers are equivalent code
generators (unsurprising: `zig cc` IS clang+LLVM). clang is simply the only
vehicle that reaches LTO on Mach-O. Measure this way or not at all: interleave
the configs per round, give every run a unique `--output` (else the build
self-skips with "Up to date" and reports nothing), and discard rounds where
`uptime` spikes — single cold builds on this tree swing ~10x and have produced
wrong answers here twice.

## Pipeline

```
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 Analyzer] --> [5 Codegen] --> output
```

- Phase 1 (Parse): COMPLETE -- 37 NodeKind, 80+ TokenKind, recursive descent + Pratt precedence
- Phase 2 (TypeCheck): COMPLETE -- 3-pass (collect, resolve, check). Cross-module resolution via ExportRegistry.
- Phase 3 (Transform): COMPLETE -- 20 general + 4 C-backend transforms, standard implementation parity
  - Generator/Iterator pipeline: `generatorLower` runs BEFORE `lambdaLifting` (reversed from the standard reference's `closureiters` order). This is intentional — generator creates `$state` local + FunctionExpr, then lambda lifting captures `$state` into env + lifts the FunctionExpr. Output is identical to the reference (state in env, step function takes envP). The reversed order keeps the two transforms decoupled (neither knows about the other).
- Phase 4 (Analyzer): COMPLETE -- DRC injection (6 files, ~2500 lines, 14 gap items, cross-scope last-read, branch-aware optimizer)
- Phase 5 (Codegen): COMPLETE -- C backend (primary), JS backend (secondary)

## Entry Point: there is no `main()` auto-call

**Nothing calls `main` for you.** A program is the top-level code of its entry module; `main`
is an ordinary function with no special status in codegen. Removed 2026-08-16 (`15df69d`) on
both backends — `genProjectDispatcher` (`src/codegen/c/index.ms`) and `emitAutoCallMain`
(`src/codegen/js/jsgen.ms`) no longer know the name.

Call it explicitly, in the shape its signature requires:

| Signature | Call site |
|---|---|
| `main(): void` | `main();` |
| `async main()` | `await main();` — preferred; a bare call also runs to completion (the exit drain pumps pending continuations) but style-wise reads like a bug |
| `main(): number` where the code is the exit status | `process.exit(main());` |

`process.exit(code = 0)` is the exit-code surface: C routes to `msExit`
(`std/core/system/index.ms` → `runtime/core/system.c`), JS declares it as **two overloads**
(`exit()` and `exit(code)`) because a default arg on an extern member parses but is not
applied at a zero-arg call — writing only `exit(code: int32 = 0)` there fails with
*No matching overload*. Both paths run `msTestErrorFlag()` first, so a pending exception is
still reported when the program exits explicitly.

**Exit = event loop empty, orphan rejections = exit 1 (Node semantics, 2026-08-18).**
After the entry module's top-level code returns, the generated `main` wrapper runs
`msDrainUntilIdle()` (`runtime/promise/drain.c`): pending timers, ready continuations and
busy pool workers all complete before the process exits — a dropped `work();` with an
`await sleepAsync(...)` inside runs its continuation, like Node. Then
`msReportOrphanFailures()` prints `Error: unhandled rejection: <msg>` per future that
completed FAILED with no observer (no callback, never read) and forces exit code 1.
`process.exit()` skips both — abrupt termination, Node parity. Poll-style readers
(`waitFor`) set an `errorObserved` bit on the future at read time, so a failure that WILL
be observed later is not misreported; the registry is in `drain.c` (pinned future, released
on observe/report — keeps the DRC ledger balanced; see guard `spawnThrowUnwind`).

**Migrating a program that relied on the auto-call.** Symptom: it builds and links clean,
prints nothing, exits 0. Fix is one line at the bottom of the entry module, per the table
above. For test-suite programs scored by exit code (`src/test/guard/run.sh`), a bare `main();`
swallows the status and turns a red guard green — forward it:
`const rc = main(); if (rc !== 0) process.exit(rc);`

**A module that is both a CLI and a test target needs a guard.** A test build still executes
top-level code, so `src/index.ms` ends with `when (!testBuild) { process.exit(main()); }` and
the test command sets that define (`src/index.ms:108`). Without it, `msc test src/index.ms`
runs the CLI instead of the tests. `test` is a keyword and cannot be the flag name. There is
no entry-module predicate and none is wanted: nothing imports an entry module, and under
`msc test` the entry module is still the entry — the discriminator is the build kind, not
the module's position.

**Why the auto-call went.** The trigger was `(mainSym.symFlags & SymbolFlag.Used) === 0`, so
merely mentioning the name anywhere (`const g = main;`) silently disabled the program's entry
point. The skeleton `main → MsMain → MsPreMainInner/MsMainInner → msProgramResult` is a
name-for-name port of the standard reference and stays; the auto-call was our own addition,
present in neither the reference nor TS. See `docs/NIM-REF.md` §1.

## CRITICAL: Codegen Must Be Thin/Dumb

**`src/codegen/c/` is a dumb emitter.** It only dumps what earlier phases already processed. If you find yourself adding logic to C codegen, STOP and check if it belongs in Transform or Checker instead.

**The rule**: Before adding ANY codegen logic, check the standard reference implementation (transform and codegen passes). If the standard reference implementation handles it before codegen, we must too.

**Evidence (7 issues traced 2026-03-04)**: 6 of 7 C backend failures were bugs in Transform/Checker that surfaced in codegen. Only 1 (exception runtime types) actually belonged in codegen.

| Symptom in Codegen | Actual Root Cause |
|---|---|
| Boolean `cond` emits `cond.length > 0` | **Transform** — `stringTruthiness` doesn't check types |
| String param `msString*` vs `msString` value | **Checker/Decl** — spurious pointer on string params |
| Function type alias → `void*` | **Type resolution** — alias not resolved to `msClosure` |
| `Result.ok()` emitted literally | **Transform** — `resultDesugar` doesn't hoist try exprs |
| JS `push(arr,x)` not `arr.push(x)` | **Transform** — `builtinLower` not target-aware |
| Async env typed as `double` | **Transform** — synthetic nodes lack type info (Reference implementation transforms pre-check) |
| `ms_throw` undefined | **Runtime** — missing C types/functions (correctly in codegen) |

**Checklist**: (1) Does the reference implementation do it in its transform phase or earlier? → put in Transform. (2) Is it type resolution? → put in Checker. (3) Is it desugaring/lowering? → put in `src/transform/`. (4) Is it pure C syntax emission? → only then codegen.

## Project Structure

```
src/
  index.ms                          -- entry point + smoke tests
  ast/     node.ms                  -- NodeKind(37), NodeData, Node, 50+ type aliases
           printer.ms               -- debug printer (exhaustive match)
  lexer/   token.ms                 -- TokenKind(80+), identToKeyword
           scanner.ms               -- core lexer (char scanning)
           lexer.ms                 -- lex() main function
           state.ms / chars.ms      -- lexer state machine, char classification
  parser/  context.ms               -- ParserState, peek, advance
           typeAnnotation.ms        -- type annotation parser
           expressions/core.ms      -- parseExpression (Pratt precedence)
           expressions/call.ms      -- call, member access, array access
           expressions/arrow.ms     -- arrow functions
           expressions/object.ms    -- object/array literals
           expressions/match.ms     -- match expressions
           statements/core.ms       -- parseProgram, parseBlock, parseStatement
           statements/declaration.ms -- functions, classes, interfaces, enums, imports
           statements/control.ms    -- loops, break, continue, switch
           statements/errorHandling.ms -- try/catch/finally, throw
           statements/callbacks.ms  -- callback injection (breaks circular imports)
  checker/ types.ms                 -- TypeKind(27), flat Type interface, constructors
           symbol.ms                -- SymbolTable, Scope chain, Symbol
           context.ms               -- CheckerContext, error collection
           collectPass.ms           -- Pass 1: collect declarations
           resolvePass.ms           -- Pass 2: resolve type annotations
           checkPass.ms             -- Pass 3: type inference + validation
           compat.ms                -- type compatibility (isAssignable)
  utils/   string.ms                -- string utilities (no indexOf/includes)
  diagnostics/ diagnostics.ms       -- error formatting
```

## Architecture Patterns

### Self-hosted execution
The compiler is a native binary (`msc`) built by the previous generation of itself. It reads target `.ms`/`.cms` files as **raw strings** and parses them with its own MetaScript parser. When debugging parse errors on target files (e.g., prelude `.cms` files), the issue is always in our parser (`src/parser/`).

### Hub re-exports
Each module directory has `index.ms` that re-exports the public API. Import directly or from hub.

### Callback injection (circular import breaker)
`callbacks.ms` holds function pointers. `core.ms` registers real implementations at module load.
Sub-parsers import from `callbacks.ms` only -- no cycles.

### Flat Type interface (not discriminated union)
Avoids codegen bugs with self-referencing anonymous structs. All fields present; unused fields empty/null.
Fields: `kind`, `typeName`, `typeNames`, `typeChildren`, `typeReturn`, `typeExtra`, `typeFlags`.

### Named-field AST (not sons[] array)
The standard reference uses a generic `sons: seq[PNode]` array with index constants (`namePos = 0`, `paramsPos = 3`, `bodyPos = 6`). We use **named fields in a discriminated union** (`NodeData`) with typed aliases (`FunctionDeclData.fnReturnType`, `VariableDeclData.declType`). This is an intentional design choice:

- **Self-documenting**: `d.fnReturnType` is clearer than `n.sons[3].sons[0]`
- **Type-safe**: Each variant has exactly the fields it needs — no off-by-one index bugs
- **No capability loss**: Everything the standard reference compiler can do, we can do with named fields

The tradeoff is that adding new fields to NodeData requires updating all construction sites, while `sons[]` allows appending freely. We accept this cost for the safety and clarity benefits.

**Type annotations as strings**: Type annotations (`declType`, `fnReturnType`, etc.) are stored as strings for simplicity. Positioned type AST is stored separately via `Node.typeExpr` for LSP symbol recording — the string path handles type resolution, the Node path handles position tracking. This avoids modifying all 18 NodeData type-annotation fields.

## Writing Idiomatic MetaScript

MetaScript looks like TypeScript but has key semantic differences. Full reference: `docs/LANG.md`.

### Match Expressions (use instead of switch, and often instead of if-else)

MetaScript's most distinctive feature. Prefer match over if-else chains for dispatching on enum, string, or number values.

```ms
// Expression form — returns a value, semicolon after closing brace
return match (kind) {
    TokenKind.Plus | TokenKind.Minus => "additive",
    TokenKind.Star => "multiplicative",
    _ => "unknown",
};

// Block arms — explicit return required inside { }
return match (ch) {
    "n" => "\n",
    "t" => "\t",
    _ => { let s = "\\"; return s + ch; },
};

// Statement form with side effects
match (node.kind) {
    NodeKind.BlockStmt => { walkBlock(node); },
    NodeKind.IfStmt => { walkIf(node); },
    _ => {},
};
```

Key rules:
- `_` is the wildcard (NOT `default`)
- `|` for alternatives: `TokenKind.A | TokenKind.B => ...`
- `when` for guards: `x when (x > 10) => handleLarge(x)`
- Bare identifiers are always BINDINGS, never value comparisons -- `x =>` captures, does not compare
- Expression arms (`=> value`) return implicitly; block arms (`=> { ... }`) require explicit `return` (applies to both `return match` and `const x = match`)
- **try in match arms FAILS** -- use if-else when you need `try`
- **break/continue in match arms** target the generated switch, not enclosing loops
- **C-style `for` in match arms FAILS** -- `for (let i = 0; ...)` isn't normalized inside match-lowered blocks. Use `while` loops instead. `for..of` works fine.

When to use if-else instead: complex nested conditions, mutation-heavy loops with state, or any arm needing `try`.

### Result<T, E> + try Operator (Rust-style error handling)

```ms
type ExprResult = Result<Expression, string>;

function parse(state: ParserState): ExprResult {
    const left = try parsePrimary(state);    // unwraps or early-returns error
    return Result.ok(left);
}

// try with catch — unwrap or use fallback
const value = try divide(10, 0) catch 0;

// Manual Result checking (when you need both branches)
const result = parseSource(input);
if (!result.ok) return Result.err(result.error);
const program = result.value;
```

Key fields: `result.ok` (boolean), `result.value` (T — only after `if (r.ok)`), `result.error` (E — only in else branch).

`Result<T, E>` is internally a boolean-discriminated match-type Union:
`match (ok: boolean) { true => { value: T }, false => { error: E } }`.
The C layout is a tagged union, so `r.value` is unreachable when !`r.ok` — narrowing
via `if (r.ok)` exposes the active variant's fields. See `docs/LANG.md`
"Discriminated Union Types" for the full DU model (match-type with enum/boolean
disc, plus TS-style structural DUs).

### interface = Reference Type (heap-allocated, like class)

In MetaScript, `interface` declares a reference type with fields. It is constructed as object literals and heap-allocated in the C backend (Ref<Struct>). Use `struct` for value types.

```ms
interface Token {
    kind: TokenKind;
    value: string;
    line: number;
    column: number;
}

// Constructed as object literals (heap-allocated, reference-counted)
function createToken(kind: TokenKind, val: string, line: number): Token {
    return { kind, value: val, line, column: 0 };
}
```

### struct = Value Type (stack-allocated, copied)

Use `struct` for performance-critical value types that should be stack-allocated and copied.

```ms
struct Vec2 { x: float64; y: float64; }

// Stack-allocated, passed by value (or by pointer if large)
function scale(v: Vec2, factor: float64): Vec2 {
    return { x: v.x * factor, y: v.y * factor };
}
```

### "a".code — Compile-Time Character Codes

```ms
// Zero runtime cost — folded to number at compile time
function isDigit(ch: number): boolean {
    return ch >= "0".code && ch <= "9".code;
}

// Works in match patterns too
return match (escChar) {
    "n" => "\n",
    "t" => "\t",
    _ => escChar,
};
```

### Type Aliases and Function Types

```ms
type ExprResult = Result<Expression, string>;
type BlockParserFn = (state: ParserState) => ExprResult;
type Visitor = (node: Node) => Node;
```

### Numeric Types — no bare `number` in this compiler

**Project convention (recompiler only, not a language rule):** use fine-grained
numeric types — `int32` / `int64` / `float64` — and do **not** use bare `number`
in new code. MetaScript-the-language still allows `number`; we opt out here because
this is a systems compiler.

Why: `number` **is** `float64` (an 8-byte double). ~98% of numeric values in this
codebase are integers (indices, lengths, depths, counts) — typing them as float64
wastes memory and is a soundness footgun. Concretely: `int32[]` was silently
accepted where `number[]` was expected and reinterpreted by a raw pointer cast
(4-byte vs 8-byte elements) → out-of-bounds read (root-caused at `compat.ms:719`;
the checker now rejects mismatched numeric-array element reprs at `compat.ms:48`).

Guidance:
- index / length / count / depth / offset / id → `int32` (or `int64` if it can
  exceed 2^31)
- genuinely fractional (ratios, scores) → `float64`
- `number` ≡ `float64` (same C `double`, interchangeable) — annotate `float64`
  when you truly mean a double

Bare int literals infer `int32` (`const a = [1, 2]` is `int32[]`); write `[1.0,
2.0]` or annotate for doubles. Migration of existing `number` usages is tracked in
`NUMBER-MIGRATE.md` (done per-module, tests green between steps).

### Null Representation

MetaScript has no `undefined`. Use `null` with type assertion for nullable fields:

```ms
const scope: Scope = { symbols: [], parent: null as unknown as Scope };
```

The `null as unknown as T` idiom is the standard way to express nullable typed fields.

### enum (C-style integer enums)

```ms
export enum NodeKind {
    NumberLiteral, StringLiteral, BooleanLiteral,
    // ...
}
// Access: NodeKind.NumberLiteral
// Compare: node.kind === NodeKind.NumberLiteral
```

### Discriminated Unions via type alias

```ms
export type NodeData =
    | { value: number }                                  // NumberLiteral
    | { operator: string, left: Node, right: Node }      // BinaryExpr
    | { statements: Node[] }                             // BlockStmt
    ;

// Narrow with `as`:
const d = node.data as BinaryExprData;
const left = d.left;
```

### Other MetaScript-Specific Syntax

- **move** -- ownership transfer: `return move data;`
- **defer** -- scope-exit cleanup: `defer cleanup();` (LIFO order, always runs)
- **unreachable** -- impossible path marker: `unreachable;`
- **out parameters** -- `function parse(input: string, out result: AST): boolean`
- **distinct type** -- nominal typing: `distinct type UserId = number;`
- **extern** -- C FFI: `extern function printf(fmt: string): void;`
- **Decorators** -- `@derive(Eq, Hash)`, `@comptime`, `@emit("...")` (backend-conditional code is `when (c) { … }`)
- **Sized integers** -- `int8`, `int16`, `int32`, `int64`, `uint8`-`uint64`, `float32`, `float64`

### Loop Constraints

**PREFERENCE (strong)**: always reach for `for..of` first, then C-style `for (let i = 0; ...)` when you need the index. Use `while` ONLY when neither fits — typically: condition-driven loops with no clear iterable (scanner advancing on char predicates, polling until a state changes, multi-variable termination). Never write `let i = 0; while (i < arr.length) { ...; i++; }` — that is always `for..of` (or `for` if you need `i`).

| Context | `for..of` | `for (let i…)` | `while` |
|---------|-----------|-----------------|---------|
| Top-level / function body | **preferred** | OK | last resort |
| Match arms | **preferred** | **FAILS** (not normalized) | OK |
| Closures / callbacks | **preferred** (read-only) | OK | last resort |

Rule of thumb: inside match arms, use `while` or `for..of` — never C-style `for`. Outside match arms, prefer `for..of` over everything else.

### Common Pitfalls for TypeScript Developers

1. `interface` is a data struct, not a behavioral contract -- no `implements`, no method dispatch
2. `type` is a reserved keyword -- use `tokenType`, `nodeType` for variable names
3. No `indexOf`/`includes` on strings -- use `slice`, `length`, `findChar`, `charAt` from `utils/string.ms`
4. Arrays are passed by pointer (no wrapper needed). Strings are still value types.
5. Match `_` is the wildcard, not `default`; bare identifiers are bindings, not comparisons
6. `null as unknown as T` is the null pattern, not `undefined`
7. `for (const x of arr)` is the default loop -- prefer it over `while` whenever the loop is "walk every element of an iterable". Only fall back to `while` when there is no clear iterable (condition-driven scanners, polling). `for..in` is rarely used.

## Standard Reference Implementation

**Every fix MUST track the standard reference implementation at `~/projects/nim`** (checker,
transform, analyzer, codegen passes) and respect **[docs/NIM-REF.md](docs/NIM-REF.md)**. Before
changing compiler code: locate the analogous reference pass (e.g. `~/projects/nim/compiler/`
semstmts / lookups / lambdalifting / injectdestructors / transf), read it, and confirm the fix
either matches its behaviour or is a documented intentional divergence in NIM-REF.md. Do **not** invent behaviour
the reference doesn't have, and do **not** reason from first principles when the reference can
be read — verified reference-reading beats reasoning.

If the fix touches **async / actor / spawn / await / parallel**, read
**[docs/PARALOCK.md](docs/PARALOCK.md)** (the concurrency model) carefully first.

## Intentional Divergences from Standard Reference

The canonical MS↔Nim divergence reference is **[docs/NIM-REF.md](docs/NIM-REF.md)** —
single source of truth, with the per-subsystem mapping (same / intentional-diverge /
incomplete-gap), the concrete reason for each, and the DRC-cleanup deep-dive. Do not
duplicate divergence rationale here; add it there. Pipeline architecture lives in
[docs/PIPELINE.md](docs/PIPELINE.md); the concurrency model in [docs/PARALOCK.md](docs/PARALOCK.md).

## Runtime C — avoid variadic struct args

When adding helpers in `runtime/core/`, **do not pass 16-byte structs (e.g. `msString`) through `...` variadics**. LLVM/Zig miscompile this on `aarch64-windows-gnu`: the first few args land in registers correctly, but args 4+ read from misaligned stack slots (LLVM applies AAPCS64 instead of the Microsoft ARM64 variadic ABI for struct-by-value). Verified with Zig 0.16.0 — symptom is a silent crash at module init because `__attribute__((constructor))` code paths hit it first.

Use an array-taking form instead:

```c
// BAD — breaks on aarch64-windows-gnu
msString msStringConcatMany(int64_t count, ...);

// GOOD — works on every target
msString msStringConcatArr(const msString* arr, int64_t count);
```

This applies to any struct ≥16 bytes or containing pointers. Scalar types (int, float, pointer) are fine in variadics — see `msNumberArrayFrom` for a working example.

**How the call site is emitted**: codegen in `src/codegen/c/expressions.ms` (`emitCallExpr`) name-matches `msStringConcatArr` / `msStringArrayFromArr` and rewrites the call to a stack-local array fill + pointer pass. If you add another array-taking runtime helper that needs the same treatment, extend that intercept (joins the family of name-matched intrinsics: `msBoxStruct`, `msSpawnInto`, `msWaitForStruct`, etc.).

## Backends

- **C**: Primary. Deterministic memory management, lifecycle hooks, compile via clang. Phase 4 (Analyzer) required.
- **JavaScript**: Secondary. No analyzer needed, direct JS emission. Simpler codegen path.
- **Erlang**: POSTPONED.

## Next Phase: Transforms (Phase 3)

Priority order: `result_desugar`, `match_lower`, `defer_lower`, `for_of_lower`, `optional_chain`, `nullish_coalesce`, `type_coercion`, `lambda_lifting`, `liftdestructors`.
Simple fixed-order runner first, pluggable pipeline later.

## Debug Technique: Nim ↔ MetaScript C-emit comparison (classic study case)

> Discovered the DRC array-overwrite leak (2026-05-16) that OOM'd Lightcube
> `/health` at 10K rps in ~3 minutes. Hours of analyzer source reading were
> outperformed in 5 minutes by this twin-probe technique. **Always reach for
> this before reading `src/analyzer/inject.ms` for a DRC question.**

When you suspect a MetaScript codegen or DRC analyzer bug, **do not read more
analyzer source first** — write twin minimal programs in MS and Nim with the
exact same pattern, emit C from both, and diff the hot loop side-by-side.
This is the single most leveraged debug move available for codegen-level bugs.

### Why Nim specifically

- Nim is the closest production-tier reference for MS's DRC model. Both
  inject `=destroy` / `=copy` / `=sink` / `wasMoved` hooks at a post-check
  AST pass via `moveOrCopy`-style dispatch.
- Nim ships ARC (`--gc:arc`) and ORC (`--gc:orc`) modes that map almost
  1:1 to our `--gc=drc` semantics.
- Nim's `~/projects/nim/compiler/injectdestructors.nim` is the closest
  analog to our `src/analyzer/inject.ms` — the same algorithm in a
  battle-tested form. When MS deviates from Nim, the deviation is
  usually the bug.
- Differences in emitted C are **load-bearing, not stylistic**. If Nim
  emits a per-type `=sink` helper and MS emits an inline
  `save → assign → incref → destroy` pattern, that's a real divergence
  to investigate — not a coincidence.

### The recipe

```bash
mkdir -p /tmp/drc-probe && cd /tmp/drc-probe

# 1. Twin probes — same shape, same pattern, ~20 LOC each.

cat > probe.ms <<'EOF'
interface Heavy { buf: string; }
function makeHeavy(): Heavy {
    let s = "x"; let i = 0;
    while (i < 12) { s = s + s; i = i + 1; }
    return { buf: s };
}
function main(): void {
    const arr: Heavy[] = new Array(10);
    let n = 0;
    while (n < 10) { arr[n] = makeHeavy(); n = n + 1; }
    let m = 0;
    while (m < 100000) { arr[m % 10] = makeHeavy(); m = m + 1; }
}
main();
EOF

cat > probe.nim <<'EOF'
import strutils
type Heavy = ref object
  buf: string
proc makeHeavy(): Heavy = Heavy(buf: "x".repeat(4096))
proc main() =
  var arr: array[10, Heavy]
  for i in 0..<10: arr[i] = makeHeavy()
  for m in 0..<100000: arr[m mod 10] = makeHeavy()
main()
EOF

# 2. Emit C from both.
msc build probe.ms --passC="-O0" --output=probe-ms
nim c --gc:arc -d:release --nimcache:./nim-cache -o:probe-nim probe.nim

# 3. Run both, measure RSS — first signal of divergence.
./probe-ms & P=$!; sleep 0.5; ps -p $P -o rss=
./probe-nim & P=$!; sleep 0.5; ps -p $P -o rss=

# 4. Diff the hot loop body in each emitted C.
sed -n '/^void main_/,/^}/p' out/debug/probe.c
sed -n '/main__probe/,/^}/p' nim-cache/@mprobe.nim.c
```

### What to read in the output

| Symbol in emitted C | Means |
|---|---|
| Nim `eqsink___...(&dest, src)` | Per-type sink op — atomic destroy-then-store |
| Nim `nimDecRefIsLast` then `nimRawDispose` | Decref + conditional free in one op |
| Nim's `passthrough` body has `eqcopy___(&result, h_p0); return result;` | Nim convention: callee-side incref on ref returns |
| MS inlined `save = dest; dest = src; msIncref(dest); msDecref(save);` | The analyzer's pattern — this is where the 2026-05 leak hid |
| MS's `passthrough` body has bare `return h;` | MS convention: callee returns rc=0, caller takes ownership |
| Difference in calling convention → caller-side incref logic must differ | Trace RC by hand if uncertain |

### Calibrated assumptions worth memorising

- **MS DRC convention**: `msAlloc` returns objects at `rc=0` meaning
  "sole owner". `msDecRefIsLast` returns `true` when `rc==0` (before
  decrement) — caller frees. `incref` bumps `rc` so `rc=N` means
  "N+1 owners".
- **Nim DRC convention**: objects allocated at `rc=1` meaning "sole owner".
  `nimDecRefIsLast` returns `true` when `rc==1` (before decrement).
  `nimIncRef` bumps so `rc=N` means "N owners". Convention is **offset
  by 1 from MS** — both are correct, do not confuse when porting patterns.
- **Nim emits per-type `=sink` ops via destructorLifting**; MS inlines
  the pattern at every assignment site. Both are valid, but a per-type
  op makes "decref-and-maybe-free old + raw store new" atomic, which
  matches `=sink` semantics. An inline pattern with a defensive
  `msIncref(dest)` after the store accidentally implements `=copy`
  semantics on what should be `=sink` — exactly the 2026-05 bug.

### Anti-patterns that consume the most time

- **Reading `src/analyzer/inject.ms` trying to predict what it emits.**
  Thousands of lines of intricate logic. Emit and read; do not predict.
- **Building probes with `--release`.** LLVM DCE's tiny probes that don't
  escape, hiding leaks. Use `--passC="-O0"` for honest measurements.
  (2026-05-16: lost 20 min to this — probe with `let x: Heavy = ...; while
  ... x = makeHeavy(); ...` and `--release` showed RSS=32 KB, suggesting
  no leak. Rebuilt with `-O0` and got 153 MB peak. Same bug, just masked
  by LLVM escape analysis.)
- **Empty `{}` literals.** Won't surface string-payload leaks. Use
  realistic types (string-bearing interface) so allocations are large
  enough to dominate RSS noise.
- **`--gc:orc` for the Nim side.** ORC adds cycle-collection scaffolding
  that obscures the core RC pattern. Use `--gc:arc` for the cleanest
  comparison — only switch to ORC when probing cycle semantics.
- **Nim module names cannot contain `-`.** Use underscores (`probe_aliased.nim`).
- **Stopping after the first probe.** The 2026-05 case needed three:
  - Array (`arr[i] = call()`) — first leak signal
  - Identifier (`x = call()`) — would have leaked too but `--release` DCE
    hid it; `-O0` revealed it
  - MemberExpr (`obj.field = call()`) — confirmed the bug is universal
    across LHS kinds
  Build all three LHS shapes when you suspect `moveOrCopy` is wrong —
  different branches of the dispatch may emit differently.
- **Aliased case `x = passthrough(x)`.** A separate probe — RHS returns
  the same ref it received. Tests whether the analyzer's defensive
  incref is hiding a UAF (it does — without the incref, this case UAFs;
  with the incref, the common fresh-call case leaks). The Nim probe
  for the same pattern reveals the convention difference: Nim
  callee-increfs ref returns, MS doesn't.

### When to use this playbook

Whenever a user (or you) suspects "X leaks / UAFs / crashes and I can't
tell if it's my code or MS" **and** the issue smells like RC accounting,
ownership transfer, or anything involving `=destroy` / `=copy` /
`=sink` / `wasMoved` — **before reading analyzer source**, run this
recipe. The 5 minutes it costs beats every other debugging path for
codegen-level bugs.

When the symptom is platform-specific (e.g. only Linux leaks), the
recipe is even more critical: the divergence is almost always a
code-path *trigger*, not platform-specific codegen. The probe tells
you which.


IMPORTANT: never mention specific reference projects in all documents or comment inside our source code
