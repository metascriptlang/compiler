# Contributing

The compiler is written in MetaScript. Working on it means building it with the previous release, running the suites, and syncing the result into `~/.metascript/` so downstream projects pick it up.

## Prerequisites

- A released `msc` on your `PATH`: `curl -fsSL https://metascriptlang.org/install.sh | sh`
- A C compiler: `zig` or `clang`
- Submodules checked out: `git submodule update --init --recursive` (C libraries under `vendor/`, editor plugins under `tools/editor-plugin/`)

## Build

```bash
msc build src/index.ms --gc=drc --danger --output=msc              # optimized self-host binary
msc build src/index.ms --gc=drc --danger --cc=clang --output=msc   # macOS: adds thin LTO
msc run src/index.ms                                               # unoptimized build + run
```

Optimization level and LTO are separate axes. The default build is `-O0 -g`, `--release` is `-O2`, `--danger` is `-O3`; a plain build of the compiler runs about 4.5x slower than `--danger`. `--lto` is resolved after the C compiler is known: `--danger` takes thin LTO where the toolchain can link it and drops it with a notice where it cannot. Measurements and method: [docs/BUILD-PERF.md](docs/BUILD-PERF.md).

## Test

```bash
msc test src/index.ms                 # full compiler suite
msc test src/utils/string.ms          # one file plus the tests of everything it imports

msc run src/test/corpus/run.ms                        # corpus: C/JS parity + RSS lanes, ~19 min
MSCORPUS_SAN=1 msc run src/test/corpus/run.ms         # corpus: ASan + reference-count ledger, ~10 min
MSCORPUS_FILTER=leak msc run src/test/corpus/run.ms   # substring subset
msc run src/test/guard/run.ms --target=raiser          # lifecycle guards
```

`test` is a keyword and a test body asserts with `assert`; see [docs/LANG-TEST.md](docs/LANG-TEST.md). `msc test <file>` runs that file's `test` blocks plus those of its transitive imports; there are no `--filter` or `--jobs` flags. Corpus runners test `./msc` when it exists, otherwise the installed `msc`; `MSC=<path>` overrides.

A lifecycle guard is proven red on a binary that has the bug before it is trusted green. A fixed bug gets a program in `src/test/fixedbugs/`; that suite is append-only. Bugs and gaps you can hit today are listed in [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md), each measured on a named commit.

## Sync into ~/.metascript

```bash
./msc run tools/syncLocalBinary.ms --target=raiser              # binary + std + runtime + vendor
./msc run tools/syncLocalBinary.ms --target=raiser check      # dry run
./msc run tools/syncLocalBinary.ms --target=raiser no-binary  # support trees only
```

Run it from a tree whose `vendor/` submodules are checked out: the sync mirrors `vendor/` with `--delete`.

## Pipeline

```
Source.ms --> [1 Parse] --> [2 Check] --> [3 Transform] --> [4 Analyze] --> [5 Codegen] --> C / JS
```

Parse is recursive descent with Pratt precedence. Check is three passes (collect, resolve, check) with cross-module resolution through an export registry. Transform lowers rich syntax to a minimal shape, with a few C-only passes. Analyze injects reference-count operations (cross-scope last-read, branch-aware). Codegen emits C first and JavaScript second. Architecture: [docs/PIPELINE.md](docs/PIPELINE.md). File map: [docs/PROJECT-STRUCTURE.md](docs/PROJECT-STRUCTURE.md). Transform catalogue: [docs/TRANSFORM.md](docs/TRANSFORM.md).

**Codegen is a thin emitter.** `src/codegen/c/` dumps what earlier phases already decided. Before adding logic there: type resolution belongs in the checker, desugaring and lowering in `src/transform/`, ownership in the analyzer. Only C syntax emission belongs in codegen.

## Entry point: there is no `main()` auto-call

A program is the top-level code of its entry module; `main` is an ordinary function. A program that relies on an implicit call builds, links, prints nothing and exits 0.

| Signature | Call site |
|---|---|
| `main(): void` | `main();` |
| `async main()` | `await main();` |
| `main(): number` as exit status | `process.exit(main());` |

A module that is both a CLI and a test target needs a guard, because a test build still executes top-level code: `src/index.ms` ends with `when (!testBuild) { process.exit(main()); }`. Exit happens when the event loop is empty; an unhandled rejection exits 1. `process.exit()` skips both.

## Writing MetaScript in this tree

- **`match`** over if-else chains for enum, string and number dispatch. `_` is the wildcard, `|` joins alternatives, `when (…)` guards. A bare identifier in a pattern is a binding, never a comparison. Expression arms return implicitly; block arms need `return`. `try`, C-style `for`, and loop `break`/`continue` do not work inside a match arm; use if-else or `while`/`for..of` there.
- **`Result<T, E>` and `try`**: `try expr` unwraps or early-returns the error, `try expr catch fallback` unwraps or substitutes.
- **`interface` is a reference type** (heap, reference-counted, built from object literals); **`struct` is a value type** (stack, copied). No `implements`, no method dispatch.
- **Numeric types**: no bare `number` in this codebase. `number` is `float64`; use `int32` for indexes, lengths, counts and ids, `int64` past 2^31, `float64` only when genuinely fractional. Bare integer literals infer `int32`.
- **Null**: there is no `undefined`. `null as unknown as T` is the idiom for a nullable typed field.
- **Loops**: `for..of` first, C-style `for` when you need the index, `while` only for condition-driven scanners.
- **Strings** have no `indexOf` or `includes`; use `slice`, `length`, `findChar`, `charAt` from `src/utils/string.ms`. Arrays pass by pointer; strings are value types.
- `type` is a reserved word; name fields `tokenType`, `nodeType`.

Full reference: [docs/LANG.md](docs/LANG.md).

## Runtime C

Do not pass structs of 16 bytes or more (for example `msString`) through `...` variadics in `runtime/core/`; some toolchains miscompile it. Take a pointer and a count instead:

```c
msString msStringConcatMany(int64_t count, ...);              // no
msString msStringConcatArr(const msString* arr, int64_t n);   // yes
```

`emitCallExpr` in `src/codegen/c/expressions.ms` rewrites calls to such helpers into a stack-local array fill plus pointer pass; a new array-taking helper needs that intercept extended.

## Editor plugins

```bash
bash tools/editor-plugin/build.sh --install   # after grammar or highlight edits
```

## Releases

`tools/release.sh` reads `VERSION` from `src/compiler/usage.ms`, builds the release archives for macOS, Linux and Windows, and publishes the GitHub release; `msc upgrade` and the install script resolve the latest one.

## Reporting bugs

Open an issue with a minimal `.ms` reproduction, the `msc --version` output, the host OS and the exact command. A reproduction that fits in one file becomes the next `src/test/fixedbugs/` program.
