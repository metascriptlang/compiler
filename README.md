# MetaScript

**TypeScript-shaped syntax. Native performance. Deterministic memory.**

MetaScript is a statically typed programming language that compiles to C (and to JavaScript), built for systems work — servers, game logic, tooling, wasm. No garbage collector pauses, no runtime lurking under your types: memory is managed by deterministic reference counting (DRC) with a cycle collector (ORC), verified at compile time by lifecycle analysis.

The entire compiler is written in MetaScript — **880 source files, ~175K lines** — and every generation of it is built by the previous one. The language carries its own weight.

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
    acc.add(20);                                 // SEND — fire-and-forget
    const total = await acc.add(22);             // CALL — reply via Promise<int32>
    console.log("actor total = " + total.toString());
    const h = spawn(() => parsed * 2);           // structured parallel task
    console.log("spawn 2x = " + (await h).toString());
}
main();
```

The program above is real: it builds and runs natively via `msc run`, printing `cafe = 51966`, `actor total = 42`, `spawn 2x = 103932`.

## Why MetaScript

- **Familiar surface, systems substrate.** If you know TypeScript, you can read MetaScript. But under it: sized integers (`int32`, `uint64`, `float64`), value `struct`s vs reference `interface`s, `move` ownership transfer, `defer` scope-exit cleanup, and `distinct` nominal types.
- **Deterministic memory — no GC pauses.** DRC reference counting with compiler-synthesized `=destroy` / `=sink` / `=wasMoved` hooks per type, plus an ORC cycle collector. Need more control? `--gc=manual` (arena/pool allocators) and `--os=bare` (freestanding, no libc) are both shipped.
- **Match expressions as the dispatch backbone.** Patterns, or-patterns, `when` guards, destructuring — as expressions, lowered to C `switch` where the discriminant allows it.
- **Errors as values.** `Result<T, E>` + the `try` operator (Rust-style), including compiler-checked `Promise<Result<T, E>>` typing for async failures.
- **A locked-in concurrency model.** One `await` keyword. `spawn` for structured parallelism with affine, scope-checked handles. Actors with BEAM-style pids (generation-checked 53-bit handles, hazard-pointer reclamation), suspension without thread blocking, supervision, and explicit shared state via `Arc<T>` / `Locked<T>`. The full design is locked in
`docs/PARALOCK.md` (kept in sync outside git — see the repo's docs directory).
- **Real metaprogramming.** User `macro`s (AST → AST), `quote`, `@comptime` blocks executed on Raiser — an embedded register-based bytecode VM — and JSX parsed into compile-time AST for macros to consume.
- **One source, many targets.** Native C via clang or `zig cc` (macOS, Linux, Windows, Android — cross-compiling from any host), wasm32-WASI and Emscripten for the web, static/shared library output (`--app=lib|staticlib`) for embedding. A JavaScript backend with source maps for the rest.
- **A toolchain, not just a compiler.** `msc` ships build/run/test/check/fmt/init/lsp commands, a content-addressed build cache, phase timers, a package manager with a registry and lockfiles, and LSP support with an incremental red/green re-check engine.

## Quick Start

Install a release binary (see the [installation guide](https://metascriptlang.org/installation)) — the compiler bootstraps itself from the previous release, so no other toolchain is needed beyond a C compiler (`zig` or `clang` recommended).

```bash
# Run a program natively
msc run hello.ms

# Optimized native build
msc build hello.ms --release --output=hello

# Cross-compile: same command from any host
msc build hello.ms --os=windows --release
msc build hello.ms --os=linux  --release
msc build hello.ms --os=emcc            # browser wasm

# Run the test suite of a project
msc test src/index.ms

# Editor support: VS Code, Neovim, Zed, JetBrains (tools/editor-plugin/)
```

## The Language in One Minute

```ms
// Sized integers; bare literals infer int32
const id: int32 = 42;
const ratio: float64 = 0.75;

// struct = value type (stack, copied) — interface = reference (RC'd)
struct Vec2 { x: float64; y: float64; }

// Errors as values
const cfg = try readConfig("app.json") catch defaultConfig;

// Ownership and cleanup
function process(): string {
    defer releaseLock();
    let buf = readFile("input.bin");
    consume(move buf);            // ownership handed off — use-after-move is an error
    return "done";
}

// Conditional compilation, checked before type checking
when (os == "windows") {
    extern function WaitForSingleObject(h: Ptr<void>): uint32 from "WaitForSingleObject";
}

// Generics with constraints and const parameters
function identity<T>(v: T): T { return v; }
```

Deeper reference: [docs/LANG.md](docs/LANG.md). Concurrency model: `docs/PARALOCK.md`. Memory model internals: [docs/ORC.md](docs/ORC.md).

## Standard Library

Twenty modules, pre-compiled into the build: `core` (19 submodules — string, array, math, bigint, json, fetch with TLS, promise, actor, buffer, date, websocket...), `crypto` (AES, ChaCha20, Ed25519, X25519, Argon2, RSA, TLS — mbedTLS-backed), `http`/`net`/`io` (select / epoll / kqueue / IOCP / io_uring engines), `serialize` (JSON + CBOR), `compress` (deflate/zip), `hash`, `archive`, `fs`, `os`, `process`, and more.

## Project Status

**v0.2.53 — fully self-hosted.** The compiler, its test runner, its LSP, its formatter, and its package manager are all written in MetaScript. A fresh machine bootstraps from a released binary and rebuilds everything from source.

Measured, not claimed (Apple Silicon, 8-core):

| Metric | Value |
|---|---|
| Self-compile, cold | ~53 s (of which ~35 s is the C toolchain) |
| Self-compile, warm cache | ~32 s |
| Test suite execution | 4,794 inline test blocks |
| Regression suite | 128 append-only `bugNNN` programs |
| Parity corpus | 168 programs, C vs JS byte-compared (no golden files) |
| Lifecycle guards | 89 probes run under a DRC ledger that aborts on double-finalize |
| Self-hosted `msc` binary | ~10.3 MB (thin-LTO) |

Every guard probe is proven red before it is trusted; the corpus runs parity, RSS (under both `--gc=drc` and `--gc=orc`), and ASan lanes. [docs/BUILD-PERF.md](docs/BUILD-PERF.md) has the measurement methodology.

**Honest gaps** (documented, not hidden): actor spawn-capture static rules S1/S3 are designed but not yet enforced; `@derive` and `@inline` are documented as reference-only/planned; the Erlang backend is postponed. Details live in the docs linked above.

## Development

```bash
# Build the self-hosted compiler binary (fastest the toolchain can link)
msc build src/index.ms --gc=drc --danger --output=msc

# Full compiler test suite
msc test src/index.ms

# Corpus: parity + RSS lanes; SAN lane adds ASan + DRC ledger
msc run src/test/corpus/run.ms
MSCORPUS_SAN=1 msc run src/test/corpus/run.ms

# Lifecycle guards (proven-red discipline)
src/test/guard/run.sh
```

Full workflow (syncing `~/.metascript/`, release process): `docs/DEVELOPMENT.md` in this tree.

## Why This Repository?

This is the public, self-hosted implementation of MetaScript — a clean rewrite of the internal compiler that has been running in production at [Metacraft Studio](https://metacraft.studio), powering gameplay logic, network code, asset pipelines, and build tooling across shipped games. The internal version served well but accumulated hacks through rapid iteration; this repository is the canonical going-forward implementation, built in the open with transparent design decisions.

## Acknowledgments

MetaScript is a new language with its own tradeoffs, not a clone — but it would not exist in its current shape without the work these communities did first:

- **TypeScript** — surface syntax, structural typing, and developer ergonomics familiar to JavaScript developers
- **Nim** — transformation pipeline design, phase ordering, IR-based lowering, and the **ORC** reference counting model that directly inspired our deterministic memory management
- **Zig** — `defer` for scope-exit cleanup, `comptime` metaprogramming, explicit allocators passed as arguments, and the "no hidden allocations" philosophy behind our memory system
- **Rust** — memory safety discipline, ownership semantics, `Result<T, E>` error handling, and the principle of making unsafe code opt-in rather than the default
- **Swift** — ARC (automatic reference counting) patterns and the idioms around safe, deterministic object lifecycles that informed our DRC implementation
- **Pony** — actor model with capability-based concurrency and garbage collection per actor, the foundation of our own actor runtime
- **Erlang / OTP** — supervisor trees, hierarchical fault recovery, and the "let it crash" philosophy behind our supervision model
- **Haxe** — multi-target compilation philosophy: one source, many native outputs
- **Salsa** — query-based incremental computation, directly inspired **Trans-Am**, our incremental build and caching engine

## Community

- **Discord**: [Join us](https://discord.com/invite/gCwkmqS3xB)
- **Website**: [metascriptlang.org](https://metascriptlang.org)
- **Issues**: bug reports with minimal reproductions are gold — the `src/test/fixedbugs/` suite grows one file per fixed bug

## License

MIT — see [LICENSE](LICENSE).
