# MetaScript Compiler

This repository contains the **public, self-hosted implementation** of the MetaScript compiler. MetaScript is a modern, TypeScript-inspired language that compiles to native code via C, designed for high-performance game development and systems programming.

### Why This Repository?

This is a **clean rewrite** of the internal compiler used at [Metacraft Studio](https://metacraft.studio). While internal compiler has served well in ad-hoc production, it accumulated manual hacks and technical debt over rapid iteration cycles. This public repository represents:

- ✨ **Clean Architecture** - Proper separation of concerns, well-documented code
- 🎯 **Self-Hosted** - The compiler is written in MetaScript, demonstrating the language's capabilities
- 🌍 **Open Source** - Community-driven development with transparent design decisions
- 📈 **Future-Proof** - This will gradually become the canonical source-of-truth for MetaScript

## Features

- **Self-Hosting**: The compiler compiles itself, proving MetaScript's maturity
- **Modular Design**: Clean separation between lexer, parser, type checker, and code generator
- **TypeScript-Inspired**: Familiar syntax for TypeScript/JavaScript developers
- **Native Performance**: Compiles to C for maximum performance
- **Modern Type System**: Interfaces, generics, type inference, and more

## Quick Start

### Prerequisites

- [MetaScript compiler](https://metascriptlang.org/installation)
- C compiler (GCC or Clang)

### Running the Compiler

```bash
# Run the self-hosted compiler
msc run src/index.ms

# Run tests
msc test src/index.ms

# Compile an example
msc run examples/testBasics.ms
```

### Project Structure

```
src/
├── index.ms           # Main entry point
├── lexer/
│   ├── lexer.ms      # Tokenization
│   └── token.ms      # Token types and formatting
└── ast/
    └── node.ms       # AST node definitions
```

## Current Status

**Self-Hosted** — All 5 phases are complete and `msc` compiles, tests, and runs itself natively (C runtime and all). The build, test, and release paths are pure MetaScript: each generation of the compiler is built by the previous one, seeded from a released binary on a clean machine.

- Phase 1 (Parse + Module): Complete — 37 NodeKind, 80+ TokenKind, recursive descent + Pratt
- Phase 2 (TypeCheck): Complete — 3-pass (collect, resolve, check), cross-module propagation
- Phase 3 (Transform): Complete — 27 general + 4 C-backend transforms
- Phase 4 (Analyzer/DRC): Complete — deterministic reference counting injection
- Phase 5 (Codegen): Complete — C, JavaScript, and Raiser bytecode backends

## Architecture

The compiler follows a multi-pass architecture aligned with modern compiler design:

1. **Lexical Analysis** - Tokenize source code
2. **Parsing** - Build Abstract Syntax Tree (AST)
3. **Type Checking** - Multi-pass type inference and validation
4. **Code Generation** - Emit C code for native compilation

### Type System Design

The type system is inspired by TypeScript but optimized for systems programming:

- **Structural Typing** - Interfaces define contracts, not implementations
- **Type Inference** - Minimize annotations while maintaining safety
- **Generic Instantiation** - Zero-cost abstractions via monomorphization
- **Lifetime Analysis** - Automatic memory management through ownership tracking

## Development

### Building from Source

```bash
# Build the self-hosted compiler, generate ./out/release/index
msc build --gc=drc --release src/index.ms
```

## Roadmap

### Phase 1: Foundation
- [x] ~~Project structure~~
- [x] ~~Lexer implementation~~
- [x] ~~Cross-module imports~~
- [x] ~~Parser implementation~~
- [x] ~~Basic type checker~~

### Phase 2: Self-Hosting (Current)
- [x] ~~Compile the compiler with itself~~
- [x] ~~Bootstrap process documentation~~
- [ ] Performance benchmarking

### Phase 3: Production Ready
- [x] ~~Full type system implementation~~
- [x] ~~Optimization passes (27 general + 4 C-backend transforms)~~
- [x] ~~Error recovery and diagnostics~~
- [ ] Standard library integration

### Phase 4: Community
- [ ] Plugin system
- [x] ~~Language server protocol (LSP)~~
- [ ] Package manager integration
- [ ] Comprehensive documentation

## Contributing

We welcome contributions! This is the future of MetaScript, and we're building it together.

### How to Contribute

1. **Report Issues** - Found a bug? Open an issue with a minimal reproduction
2. **Propose Features** - Have an idea? Start a discussion in Issues
3. **Submit PRs** - Fix bugs, add features, improve documentation

### Contribution Guidelines

- Follow the existing code style (tabs for indentation)
- Add tests for new features
- Update documentation as needed
- Keep commits focused and well-described

## Why MetaScript?

**For TypeScript Developers**: Familiar syntax, but compiles to native code for 10-100x performance improvements.

**For Systems Programmers**: Modern language features (type inference, interfaces, generics) without sacrificing control or performance.

**For Game Developers**: Fast iteration with scripting-like ergonomics, production performance with native compilation.

## Links

- **Discord Community**: [Join us on Discord](https://discord.com/invite/gCwkmqS3xB)

## Acknowledgments

MetaScript is used internally at Metacraft Studio — powering gameplay logic, network code, asset pipelines, and build tooling across shipped games. This public compiler reflects lessons from that production usage.

Its design draws on ideas from several languages:

- **TypeScript** — surface syntax, structural typing, and developer ergonomics familiar to JavaScript developers
- **Nim** — transformation pipeline design, phase ordering, IR-based lowering, and the **ORC** reference counting model that directly inspired our deterministic memory management
- **Zig** — `defer` for scope-exit cleanup, `comptime` metaprogramming, explicit allocators passed as arguments, and the "no hidden allocations" philosophy behind our memory system
- **Rust** — memory safety discipline, ownership semantics, `Result<T, E>` error handling, and the principle of making unsafe code opt-in rather than the default
- **Swift** — ARC (automatic reference counting) patterns and the idioms around safe, deterministic object lifecycles that informed our DRC implementation
- **Pony** — actor model with capability-based concurrency and garbage collection per actor, the foundation of our own actor runtime
- **Erlang / OTP** — supervisor trees, hierarchical fault recovery, and the "let it crash" philosophy behind our supervision model
- **Haxe** — multi-target compilation philosophy: one source, many native outputs
- **Salsa** — query-based incremental computation, directly inspired **Trans-Am**, our incremental build and caching engine

MetaScript is a new language with its own tradeoffs, not a clone of any of these — but it would not exist in its current shape without the work these communities did first.

## License

MIT License - see [LICENSE](LICENSE) file for details.
