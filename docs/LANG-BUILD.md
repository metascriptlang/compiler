# build.ms — Project Configuration

MetaScript projects use `build.ms` as the project manifest. The compiler executes it through the Raiser bytecode VM and extracts a config object.

## Minimal Example

```ms
{
    root: "src/main.ms",
    build: {
        target: "native",    // "native" (alias for "c"), "js", "raiser"
        outDir: "out",
        outFile: "myapp",
        optimize: "debug",   // "debug" | "release" | "danger"
    },
}
```

The file is a MetaScript expression that evaluates to a config object. No `export` needed — the Raiser VM captures the last expression result.

## Full Schema

```ms
{
    // Entry point (required)
    root: "src/main.ms",

    // Build options
    build: {
        target: "native",         // "native"/"c", "js", "raiser", "erlang", "wasm"
        outDir: "out",
        outFile: "myapp",         // binary name (default: root basename)
        optimize: "debug",        // "debug" | "release" | "danger"
    },

    // Module resolution
    resolve: {
        searchPaths: [            // extra root directories for bare imports
            "./lib",
            "./vendor",
            "~/.msc/packages",
        ],
        alias: {                  // webpack-style path aliases
            "@app": "./src",
            "@utils": "./src/utils",
        },
        extensions: [".ms", ".ts", ".js"],  // fallback extensions (after backend-specific)
    },

    // Global imports — auto-injected into every source file
    // Similar to C#'s global using directives
    globalImports: [
        { from: "lib/operators", names: ["|>", "<>", "pipe"] },
        { from: "std/prelude", namespace: "prelude" },
        { from: "./utils/globals", side_effect: true },
    ],

    // Compile-time constants (injected as const declarations)
    define: {
        VERSION: "1.0.0",
        DEBUG: "true",
    },

    // Editor/LSP target — what the language server should assume this
    // project compiles for. Does NOT affect `msc build`. See "LSP Target".
    lsp: {
        os: "bare",               // bare, solana, wasm, emcc, linux, macos,
                                  // windows, darwin, freebsd, ios, android
        gc: "manual",             // none, manual, drc, orc — optional, inferred from os
    },

    // Workspace packages (monorepo support)
    workspace: ["packages/*"],

    // Test options
    test: {
        include: ["src/**/*.test.ms"],
        exclude: ["src/vendor/**"],
    },
}
```

## How It Works

1. Compiler looks for `build.ms` in the current directory
2. Reads and evaluates it through the Raiser bytecode VM (`evalSourceFull`)
3. Extracts fields from the result object via `heapObjectGetString` / `heapObjectGetObjectHandle`
4. Fields feed into CLI options, module resolver, and checker prelude

## Module Resolution Integration

The `resolve` section configures how `import` specifiers map to files:

### Search Paths

Bare imports (not starting with `./`, `../`, or `std/`) are resolved by searching `resolve.searchPaths` in order:

```ms
// build.ms
{ resolve: { searchPaths: ["./lib"] } }

// In source code:
import { Grid } from "ui/grid";
// Resolves to: ./lib/ui/grid.ms (or .cms/.jms per backend)
```

### Path Aliases

Aliases rewrite the specifier prefix before resolution:

```ms
// build.ms
{ resolve: { alias: { "@app": "./src" } } }

// In source code:
import { db } from "@app/database";
// Rewrites to: ./src/database → resolves normally
```

### Extension Priority (React Native Pattern)

For each candidate path, the resolver tries extensions in backend-aware priority order:

| Priority | C backend | JS backend | Raiser | Erlang | Wasm |
|----------|-----------|------------|--------|--------|------|
| 1 | `.cms` | `.jms` | `.rms` | `.ems` | `.wms` |
| 2 | `.ms` | `.ms` | `.ms` | `.ms` | `.ms` |
| 3 | `.ts` | `.ts` | `.ts` | `.ts` | `.ts` |
| 4 | `.js` | `.js` | `.js` | `.js` | `.js` |

Each extension is tried as both direct file and `/index.*`:

```
import "./parser" with C backend tries:
  ./parser.cms → ./parser.ms → ./parser.ts → ./parser.js
  ./parser/index.cms → ./parser/index.ms → ./parser/index.ts → ./parser/index.js
```

The `.ts`/`.js` fallback enables importing existing npm/TypeScript libraries directly — if the API surface is compatible, it just works.

### `std/build` — Default Extensions

The `std/build` module exports `defaultExtensions` which contains the backend-aware extension list. Users can extend or fully override:

```ms
import { defaultExtensions } from "std/build";

{
    resolve: {
        // Default: includes backend-specific + .ms + .ts + .js
        extensions: [...defaultExtensions],

        // Override: only resolve .ms, .ts, .js (no backend-specific .cms/.jms etc.)
        extensions: [".ms", ".ts", ".js"],

        // Extend: add custom extension
        extensions: [...defaultExtensions, ".mts"],
    },
}
```

`defaultExtensions` is computed from the active backend target:
```ms
// std/build (conceptual)
// When target is "c":   [".cms", ".ms", ".ts", ".js"]
// When target is "js":  [".jms", ".ms", ".ts", ".js"]
// When target is "raiser": [".rms", ".ms", ".ts", ".js"]
export const defaultExtensions = getExtensionsForBackend(currentTarget);
```

When `resolve.extensions` is omitted from `build.ms`, the compiler uses `defaultExtensions` automatically. This means most projects never need to specify extensions — they get backend-aware resolution for free.

### Standard Library Resolution

`std/` prefixed imports resolve against the std library path:

1. `MSC_STD_PATH` environment variable (if set)
2. Relative to compiler binary: `../../std/` (dev build) or `../std/` (installed)
3. Fallback: `./std/` (current directory)

Same extension priority applies within std resolution.

## Global Imports

Global imports are virtually prepended to every source file during type checking. The compiler
carries a default list (see `src/checker/prelude.ms`); `build.ms` entries are **concatenated
after** it — they add, they never replace.

Each entry is an **extension-less module path**, and everything the module exports lands in
scope of every file:

```ms
const config = {
    globalImports: [
        "./src/converters",   // project path — resolved against the build.ms directory
        "std/hash",           // std path — passes through untouched
    ],
};
export default config;
```

Resolution: `std/`-prefixed passes through, absolute is normalized, anything else is joined to
the project root. The path carries no extension — the loader probes the backend extension first
(`.cms`/`.jms`), then `.ms`.

Precedence: an explicit `import` in a module always wins over a `build.ms` injection, and a local
declaration wins over both (`local < import < build.ms inject`). A duplicate converter pair at the
same level is an error; a lower level silently shadows a higher one.

`{ from, names }` / `{ from, namespace }` / `{ from, side_effect }` object entries are accepted by
the parser for `from` only — the other keys are ignored. They are a JSON-config idiom that does
not belong in a MetaScript file; the intended selective form is a real import plus a symbol
reference, which stays refactorable and greppable:

```ms
import { pipe } from "lib/operators";
const config = { globalImports: [pipe] };     // NOT IMPLEMENTED — see below
```

That form needs per-name filtering in `injectPrelude` (which today copies every exported symbol),
so it is deferred until a real use case appears. Until then, list the module and take all of it.

## LSP Target — `lsp = { os, gc }`

The language server has no `--os` / `--gc` flags to read: an editor opens a file, not a build
command. Without a declaration it assumes the host, so a project that only ever compiles
freestanding (`--os=bare`, `--os=solana`) gets host-shaped diagnostics in the editor and finds
out about target-only errors at build time. The `lsp` section is that missing declaration.

```ms
const config = {
    root: "./src/main.ms",
    lsp: { os: "bare" },        // gc inferred → "manual"
};
export default config;
```

Resolution (`getLspTarget`, `src/compiler/lsp/handlers/diagnostics.ms`):

- `lsp.os` defaults to the **host platform** when absent.
- `lsp.gc` is inferred from the os — `bare` / `solana` ⇒ `manual`, anything else ⇒ `orc`.
- An explicit `lsp.gc` always wins over the inference.
- The result is cached per project root (the directory holding `build.ms`) and invalidated in
  `handleDidSave` when `build.ms` / `msc.json` is saved, beside the formatter's reset.

Effect today: exactly one diagnostic class. When the effective gc is `manual` and the open file
is not under `std/`, the server publishes FREESTANDING E01 as a **Warning** (severity 2) at every
async site — the same rule the build path reports as an error. Measured 2026-09-06 (mscF6, real
stdio LSP, `didOpen` on a 3-async-site file; the build path on that same file with `--gc=manual`
errors at 1:16, 4:15, 9:15):

| `build.ms` | E01 warnings published |
|---|---:|
| no `build.ms` above the file | 0 |
| `build.ms` without an `lsp` section | 0 |
| `lsp = { os: "bare" }` | 3 |
| `lsp = { os: "bare", gc: "drc" }` | 0 |
| `lsp = { os: "solana" }` | 3 |
| `lsp = { gc: "manual" }` | 3 |

So a project that declares nothing keeps exactly the diagnostics it had — host os ⇒ never
`manual` ⇒ zero new warnings.

**The section is editor-only.** It is read by the LSP and by nothing else: `msc build` ignores it
entirely (verified — a project whose `build.ms` carries `lsp: { os: "bear", gc: "gcx" }` builds
clean, exit 0, no message). Declaring a target here does not compile for that target; it tells the
editor which target to judge the code against.

Unknown values are reported when the editor opens `build.ms` itself (`validateBuildConfig`, also
LSP-only — the CLI never calls it). The two warnings above are published as, verbatim:

```
lsp.os: unknown target 'bear' — valid: bare, solana, wasm, emcc, linux, macos, windows, darwin, freebsd, ios, android
lsp.gc: unknown mode 'gcx' — valid: none, manual, drc, orc
```

## Current Implementation Status

### Working
- `root` field extraction
- `build.target` (with `"native"` → `"c"` alias)
- `build.outDir`, `build.outFile`, `build.optimize`
- Raiser VM evaluation of arbitrary MetaScript expressions
- CLI reads `build.ms` for `msc build` command
- `globalImports` — module-path entries, concatenated onto the compiler's default prelude list
  before command dispatch, so every command that type-checks sees them (not just `build`)
- `lsp.os` / `lsp.gc` — editor-only target declaration (see "LSP Target" above); drives
  FREESTANDING E01 warnings in the language server, ignored by `msc build`

### Not Yet Extracted
- `resolve.searchPaths` — resolver skips bare imports
- `resolve.alias` — not wired to resolver
- `globalImports.names` / `.namespace` / `.side_effect` — only `from` is read; an entry always
  injects the module's full export surface
- `define` — compile-time constants not injected
- `workspace` — monorepo support deferred

## File Locations

- Config loader: `src/compiler/buildConfig.ms`
- Raiser evaluator: `src/codegen/raiser/eval.ms`
- Prelude (globalImports consumer): `src/checker/prelude.ms`
- Module resolver: `src/module/resolver.ms`
- LSP target resolution (`lsp` section consumer): `src/compiler/lsp/handlers/diagnostics.ms`
  (`getLspTarget` / `resetLspTargetCache`), reset hook in `src/compiler/lsp/handlers/lifecycle.ms`
