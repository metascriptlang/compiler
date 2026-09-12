# MetaScript

[![CI](https://github.com/metascriptlang/compiler/actions/workflows/ci.yml/badge.svg)](https://github.com/metascriptlang/compiler/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/metascriptlang/compiler)](https://github.com/metascriptlang/compiler/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**TypeScript-shaped syntax. Native binaries. Deterministic memory.**

MetaScript is a statically typed language that compiles to C, and secondarily to JavaScript. It is built for systems work: servers, game logic, tooling, wasm. Memory is reference-counted with a cycle collector, and the retain/release points are decided at compile time by a lifecycle analysis, so there is no garbage collector and no pause.

This repository is the self-hosted compiler. The compiler, its test runner, its formatter, its language server and its package manager are written in MetaScript, and each build of `msc` is produced by the previous release.

```ms
function hexDigit(ch: string): int32 {
    const c = ch.charCodeAt(0);
    return match (ch) {
        "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" => c - "0".code,
        "a" | "b" | "c" | "d" | "e" | "f" => c - "a".code + 10,
        _ => -1,
    };
}

function parseHex(raw: string): Result<int32, string> {
    let value: int32 = 0;
    for (let i = 0; i < raw.length; i += 1) {
        const d = hexDigit(raw.charAt(i));
        if (d < 0) return Result.err("bad hex char");
        value = value * 16 + d;
    }
    return Result.ok(value);
}

actor Accumulator {
    total: int32 = 0;
    add(n: int32): int32 {
        this.total = this.total + n;
        return this.total;
    }
}

function main(): void {
    defer console.log("done.");
    const parsed = try parseHex("cafe");        // Result + try: unwrap or early-return
    console.log("cafe = " + parsed.toString());
    const acc = new Accumulator();
    acc.add(20);                                 // SEND: fire-and-forget
    const total = await acc.add(22);             // CALL: reply through Promise<int32>
    console.log("actor total = " + total.toString());
    const h = spawn(() => parsed * 2);           // structured parallel task
    console.log("spawn 2x = " + (await h).toString());
}
main();
```

Save that as `hello.ms` and `msc run hello.ms` prints:

```
cafe = 51966
actor total = 42
spawn 2x = 103932
done.
```

## Why MetaScript

- **Familiar surface, systems substrate.** If you read TypeScript you can read MetaScript. Underneath: sized integers (`int32`, `uint64`, `float64`), value `struct` versus reference `interface`, `move` for ownership transfer, `defer` for scope-exit cleanup, `distinct` nominal types, `out` parameters.
- **Deterministic memory.** Reference counting with compiler-synthesized `=destroy`, `=sink` and `=wasMoved` hooks per type, plus a cycle collector. Four modes: `--gc=orc` (default), `--gc=drc`, `--gc=none`, `--gc=manual`. `--os=bare` builds freestanding, without libc ([docs/BARE.md](docs/BARE.md)).
- **`match` is the dispatch backbone.** Or-patterns, `when` guards, destructuring, as an expression, lowered to a C `switch` where the discriminant allows it.
- **Errors as values.** `Result<T, E>` with `try` to unwrap-or-return and `try … catch fallback` to unwrap-or-substitute. `Promise<Result<T, E>>` is type-checked for async failures.
- **One concurrency model.** `await`. `spawn` returns an affine handle: it must be awaited exactly once and cannot escape, and the checker enforces it. Actors own a mailbox; a `void` method is a send, a returning method is a call that yields a `Promise`. Actor state is isolated, `nonisolated` fields opt out. Details: [docs/LANG-CONCURRENCE.md](docs/LANG-CONCURRENCE.md).
- **Metaprogramming.** `macro` (AST to AST), `quote`, `@comptime` blocks run on Raiser, an embedded register-based bytecode VM, TypeScript-style decorators applied at compile time, and JSX parsed into a compile-time AST for macros to consume. [docs/LANG-METAPROGRAMMING.md](docs/LANG-METAPROGRAMMING.md), [docs/LANG-JSX.md](docs/LANG-JSX.md).
- **Testing in the language.** `test` is a keyword; a test body asserts with `assert`. `msc test file.ms` runs the file's tests plus those of everything it imports.
- **One source, many targets.** C through `clang` or `zig cc`: macOS, Linux, Windows, Android, iOS, FreeBSD, cross-compiled from any host. wasm32-WASI and Emscripten for the browser. `--app=lib|staticlib` for embedding. A JavaScript backend with source maps.
- **A toolchain.** `msc build | run | test | check | fmt | init | lsp | upgrade`, a content-addressed build cache, and a package manager (`add`, `install`, `publish`) with a registry and lockfiles.

## Quick start

```bash
curl -fsSL https://metascriptlang.org/install.sh | sh   # or a release archive from GitHub

msc run hello.ms                               # build and run natively
msc build hello.ms --release --output=hello    # optimized binary
msc build hello.ms --os=windows --release      # cross-compile from any host
msc build hello.ms --os=linux --release
msc build hello.ms --os=emcc                   # browser wasm
msc test hello.ms                              # run the file's test blocks
```

Installation guide: [metascriptlang.org/installation](https://metascriptlang.org/installation). Editor support for VS Code, Neovim, Zed and JetBrains lives in [tools/editor-plugin/](tools/editor-plugin/). Worked examples: [metascript-tutorial](https://github.com/metascriptlang/metascript-tutorial).

## The language in one minute

```ms
const id: int32 = 42;                              // bare integer literals infer int32
const ratio: float64 = 0.75;

struct Vec2 { x: float64; y: float64; }            // value type: stack, copied
interface User { name: string; age: int32; }       // reference type: heap, reference-counted

function parseAge(raw: string): Result<int32, string> {
    if (raw.length === 0) return Result.err("empty");
    return Result.ok(parseInt(raw) as int32);
}
const age = try parseAge("42") catch 0;            // unwrap, or substitute

function describe(u: User): string {
    defer console.log("seen " + u.name);
    return match (u.age) {
        0 => "newborn",
        _ when (u.age < 18) => "minor",
        _ => "adult",
    };
}

function consume(items: int32[]): int32 { return items.length; }
let buf = [1, 2, 3];
consume(move buf);                                 // ownership handed off; a later use of buf is a compile error

when (js) {                                        // conditional compilation, resolved before type checking
    console.log("javascript backend");
} else {
    console.log("native backend");
}

test "describe classifies ages" {
    assert describe({ name: "ada", age: 30 }) === "adult";
}
```

Reference: [docs/LANG.md](docs/LANG.md). Move semantics: [docs/LANG-MOVE.md](docs/LANG-MOVE.md). Structs and the type system: [docs/LANG-STRUCT.md](docs/LANG-STRUCT.md). Runtime: [docs/LANG-RUNTIME.md](docs/LANG-RUNTIME.md).

## Standard library

Nineteen modules, pre-compiled into the build: `core` (string, array, math, bigint, json, fetch, promise, actor, buffer, date, websocket and more), `crypto` (AES, ChaCha20, BLAKE2b, Ed25519, X25519, Argon2, RSA, TLS on mbedTLS), `http`, `https`, `net`, `io` (epoll, kqueue, IOCP, io_uring engines), `serialize` (JSON, CBOR), `compress`, `archive`, `hash`, `fs`, `os`, `process`, `actor`, `build`, `meta`, `runtime`, `surreal`, `toycodec`. Overview: [docs/LANG-PRELUDE.md](docs/LANG-PRELUDE.md).

## Status

Fully self-hosted. The version lives in `src/compiler/usage.ms`; binaries are on the [releases page](https://github.com/metascriptlang/compiler/releases).

Counted from this tree on 2026-09-13:

| | |
|---|---|
| Compiler source (`src/`) | 1,016 files, 191,506 lines of MetaScript |
| `test` blocks | 5,270 in `src/`, 585 in `std/` |
| Regression programs (`src/test/fixedbugs/`) | 168 |
| Corpus programs (`src/test/corpus/`) | 197: 128 compared byte-for-byte between C and JS, 69 with an RSS ceiling |
| Lifecycle guards (`src/test/guard/`) | 130 probes |
| Self-hosted `msc` | 12.0 MB |

A lifecycle guard is proven red on a binary that has the bug before it is trusted green. The corpus runs C/JS parity, RSS ceilings under both `--gc=drc` and `--gc=orc`, and an AddressSanitizer lane with a reference-count ledger that aborts on a double release. Build timings and how they are measured: [docs/BUILD-PERF.md](docs/BUILD-PERF.md).

**Known gaps** are in [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md), each entry measured on a named commit. In short: `@derive` is planned, not implemented; the JavaScript backend is secondary and has no lifecycle analyzer; an Erlang backend is postponed.

## Development

```bash
msc build src/index.ms --gc=drc --danger --output=msc   # self-host binary
msc test src/index.ms                                   # full compiler suite
msc run src/test/corpus/run.ms                          # corpus: parity + RSS lanes
```

Build, test, sync and release workflow, plus the conventions used in this codebase: [CONTRIBUTING.md](CONTRIBUTING.md).

## Origins

MetaScript comes out of [Metacraft Studio](https://metacraft.studio), where it is used for gameplay logic, networking, asset pipelines and build tooling. The first compiler was internal and accumulated shortcuts through rapid iteration; this repository is the clean, self-hosted rewrite, developed in the open.

## Acknowledgments

MetaScript has its own tradeoffs and is not a clone of anything, but it would not have its current shape without the work these communities did first:

- **TypeScript**: surface syntax, structural typing, and ergonomics familiar to JavaScript developers
- **Nim**: transformation pipeline design, phase ordering, IR-based lowering, and the ORC reference-counting model behind our memory management
- **Zig**: `defer`, `comptime` metaprogramming, explicit allocators, and the "no hidden allocations" philosophy
- **Rust**: ownership semantics, `Result<T, E>` error handling, and unsafe code as opt-in
- **Swift**: ARC patterns and the idioms around deterministic object lifecycles
- **Pony**: the actor model with capability-based concurrency
- **Erlang / OTP**: supervisor trees and the "let it crash" philosophy behind our supervision model
- **Haxe**: one source, many native outputs
- **Salsa**: query-based incremental computation, the model behind Trans-Am, our incremental build and caching engine

## Community

- **Discord**: [join](https://discord.com/invite/gCwkmqS3xB)
- **Website**: [metascriptlang.org](https://metascriptlang.org)
- **Issues**: a bug report with a minimal reproduction becomes a program in `src/test/fixedbugs/`

## License

MIT. See [LICENSE](LICENSE).
