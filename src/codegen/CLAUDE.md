# Phase 5: Code Generation

Three backends. C is primary (DRC, lifecycle hooks). JS is secondary (no analyzer, direct emission). Raiser is the bytecode backend (no DRC, its own VM).

| Backend | Directory | Entry point | Analyzer (Phase 4) | Pipeline |
|---------|-----------|-------------|--------------------|----------|
| **C** | `c/` | `generateCModule` (`c/index.ms`) | yes | `parse → check → transform → analyze → builtinLower → codegen` |
| **JS** | `js/` | `generateJS`, `generateJSModule`, `generateJSBundleModule` (`js/jsgen.ms`) | no | `parse → check → transform → codegen` |
| **Raiser** | `raiser/` | `generateRaiser`, `generateRaiserProject` (`raiser/rgen.ms`) | no | `parse → check → transform → codegen → Raiser VM` |

- C backend rules: [`c/CLAUDE.md`](c/CLAUDE.md).
- Raiser backend rules, what it does not handle, tests: [`raiser/CLAUDE.md`](raiser/CLAUDE.md); the VM itself: [`src/raiser/CLAUDE.md`](../raiser/CLAUDE.md); design and measured status: [`docs/RAISER.md`](../../docs/RAISER.md).
- JS backend files: `js/emit.ms` (string buffer, generator state), `js/expressions.ms`, `js/statements.ms`, `js/declarations.ms`, `js/jsgen.ms` (dispatcher), `js/sourcemap.ms`, `js/valueCopy.ms`.
