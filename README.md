# MetaScript Compiler

A self-hosted compiler for MetaScript, written in MetaScript itself.

## Overview

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
# Compile and run the self-hosted compiler
msc run src/index.ms

# Expected output:
# === MetaScript Compiler ===
# Step 1: Testing Lexer
# ...
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

🚧 **Early Development** - This is an actively developed project. The compiler currently demonstrates:

- ✅ Lexical analysis (tokenization)
- ✅ Cross-module imports
- ✅ Type inference for imported functions
- 🚧 Parser (in progress)
- 🚧 Type checker (in progress)
- 🚧 Code generator (in progress)

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
# Ensure you have the MetaScript compiler installed
msc --version

# Run the self-hosted compiler
msc run src/index.ms
```

## Roadmap

### Phase 1: Foundation (Current)
- [ ] Project structure
- [ ] Lexer implementation
- [ ] Cross-module imports
- [ ] Parser implementation
- [ ] Basic type checker

### Phase 2: Self-Hosting
- [ ] Compile the compiler with itself
- [ ] Bootstrap process documentation
- [ ] Performance benchmarking

### Phase 3: Production Ready
- [ ] Full type system implementation
- [ ] Optimization passes
- [ ] Error recovery and diagnostics
- [ ] Standard library integration

### Phase 4: Community
- [ ] Plugin system
- [ ] Language server protocol (LSP)
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

## Background: MetaScript at Metacraft Studio

MetaScript was born from real-world game development needs at Metacraft Studio. Our internal compiler has powered multiple shipped games, handling:

- Real-time gameplay logic
- Network synchronization
- Asset pipeline tools
- Build automation

This public compiler represents lessons learned from production use, redesigned for clarity and extensibility.

## Why MetaScript?

**For TypeScript Developers**: Familiar syntax, but compiles to native code for 10-100x performance improvements.

**For Systems Programmers**: Modern language features (type inference, interfaces, generics) without sacrificing control or performance.

**For Game Developers**: Fast iteration with scripting-like ergonomics, production performance with native compilation.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Links

- **Discord Community**: [Join us on Discord](https://discord.com/invite/gCwkmqS3xB)

## Acknowledgments

This compiler is built on lessons learned from production game development and inspired by the design of TypeScript. Special thanks to the Metacraft Studio team for their insights and patience during the internal compiler's evolution.

---

*This is the beginning of MetaScript's journey as a truly community-driven language. Join us in building something great!*
