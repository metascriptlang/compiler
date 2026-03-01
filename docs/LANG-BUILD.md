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

Global imports are virtually prepended to every source file during type checking. The default is `["std/core.ms"]` (console, string/array methods, Result type).

`build.ms` can add project-wide imports:

```ms
{
    globalImports: [
        // Named imports
        { from: "lib/operators", names: ["|>", "pipe"] },
        // Namespace import
        { from: "std/math", namespace: "math" },
        // Side-effect only (no names imported)
        { from: "./setup", side_effect: true },
    ],
}
```

## Current Implementation Status

### Working
- `root` field extraction
- `build.target` (with `"native"` → `"c"` alias)
- `build.outDir`, `build.outFile`, `build.optimize`
- Raiser VM evaluation of arbitrary MetaScript expressions
- CLI reads `build.ms` for `msc build` command

### Not Yet Extracted
- `resolve.searchPaths` — resolver skips bare imports
- `resolve.alias` — not wired to resolver
- `globalImports` — prelude.ms hardcodes `["std/core.ms"]`
- `define` — compile-time constants not injected
- `workspace` — monorepo support deferred

## File Locations

- Config loader: `src/compiler/buildConfig.ms`
- Raiser evaluator: `src/codegen/raiser/eval.ms`
- Prelude (globalImports consumer): `src/checker/prelude.ms`
- Module resolver: `src/module/resolver.ms`
- Reference implementation: `/Users/le/projects/metascript/src/build/config.zig`
