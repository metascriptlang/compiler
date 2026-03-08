# MetaScript Standard Library

## Directory Layout

```
std/
├── CLAUDE.md                  -- this file
├── core/                      -- prelude modules (auto-loaded, no import needed)
│   ├── system.ms              -- console, Result<T,E>, toString
│   ├── string/index.cms       -- string extension methods
│   ├── array/index.cms        -- array extension methods
│   ├── map/index.cms          -- Map<K,V> methods
│   └── json/                  -- JSON types + parser + stringify
│       ├── index.cms          -- prelude (JsonKind, JsonValue, JSON class)
│       ├── index.ms           -- re-exports for explicit import
│       ├── types.ms           -- JsonKind enum, JsonValue class
│       ├── builder.ms         -- constructors + accessors
│       ├── parser.ms          -- recursive descent JSON parser
│       └── stringify.ms       -- JSON serializer
├── fs/                        -- file system
│   ├── index.cms              -- 7 C externs + pure MS logic (stat decode, utils)
│   ├── native.h               -- minimal C runtime (7 POSIX wrappers)
│   └── path.ms                -- pure MetaScript path utilities (21 tests)
├── io/                        -- standard streams (stdin/stdout/stderr only)
│   ├── index.cms              -- readLine, readBytes, writeStdout, writeStderr
│   └── native.h               -- C runtime (stdio wrappers)
├── process/                   -- process control
│   ├── index.cms              -- argv, exit, cwd, exec, getEnv, clockMs
│   └── native.h               -- C runtime (POSIX process ops)
└── testing/                   -- test framework
    └── index.ms               -- test, check, require, testGroup (intrinsics)
```

## File Types

| Extension | Purpose | Backend |
|-----------|---------|---------|
| `.ms` | Pure MetaScript implementation | All backends |
| `.cms` | C-backend prelude (extern declarations + MS wrappers) | C only |
| `.h` | C runtime header (included via `@include`) | C only |

**Prefer `.ms` over `.cms`+`.h`** when the logic is pure string/array/number manipulation. Only use `.cms` + `.h` when you need actual C/POSIX calls (file I/O, syscalls, malloc, etc.).

## Conventions

### Module Structure

- Each module directory has an `index.cms` or `index.ms` as its entry point
- `import { readFile } from "std/fs"` resolves to `std/fs/index.cms`
- Sub-modules can be imported directly: `import { dirname } from "std/fs/path"`

### Prelude (.cms) Pattern

Prelude files are auto-loaded by the compiler (no import needed). They follow this pattern:

```ms
@include("path/to/native.h");          // C header dependency

extern function msDoThing(x: string): string;  // private C binding

export function doThing(x: string): string {    // public MS API
    return msDoThing(x);
}
```

### Extern Naming

- C function names: `ms` prefix + PascalCase module + CamelCase method
  - `msFsReadFile`, `msStringIndexOf`, `msProcessCwd`
- Mutable/in-place C functions: `&` prefix in `from` string
  - `from "&msNumberArrayPush"` — modifies receiver in place
- Extension methods: `this` parameter
  - `extern function push(this arr: number[], value: number): void from "&msNumberArrayPush"`

### Return Conventions (C layer)

| MS Return Type | C Return | Pattern |
|---------------|----------|---------|
| `string` | `msString` | `MS_EMPTY_STRING` on failure |
| `boolean` | `double` | `1.0` = true, `0.0` = false |
| `number` | `double` | `-1.0` for "not found" |
| `void` | `void` | — |

The `.cms` wrapper converts C doubles to proper booleans:
```ms
export function exists(path: string): boolean {
    return msFsExists(path) === 1;
}
```

### Pure MetaScript (.ms) Pattern

When no C calls are needed, write pure `.ms` with inline tests:

```ms
export function dirname(p: string): string {
    // ... pure string scanning ...
}

import { test, check, testGroup } from "std/testing";

testGroup("dirname", () => {
    test("basic", () => {
        check(dirname("/a/b/c") === "/a/b");
    });
});
```

### Testing

- Every `.ms` file includes inline tests at the bottom
- `.cms` files cannot have inline tests (no test runner in prelude mode)
- Use `testGroup` + `test` + `check` from `std/testing`
- `check()` = non-fatal, `require()` = fatal

## Module Boundaries

| Module | Scope | Should NOT contain |
|--------|-------|--------------------|
| `std/io` | stdin/stdout/stderr only | File I/O, JSON parsing |
| `std/fs` | File operations + path utils | Process control, networking |
| `std/process` | argv, env, cwd, exec, clock | File I/O (use std/fs) |
| `std/core/json` | JSON types, parse, stringify | I/O, file reading |
| `std/core/string` | String extension methods | I/O, file operations |
| `std/core/array` | Array extension methods | I/O, file operations |
| `std/testing` | Test intrinsics | Everything else |

## C Runtime Headers

Runtime `.h` files live alongside their `.cms`:
- `std/fs/native.h` — POSIX file ops
- `std/io/native.h` — stdio streams
- `std/process/native.h` — process/env/clock

Shared low-level types (`msString`, `msAllocTyped`, etc.) live in `runtime/system.h`. Module-specific runtime code (json, map, array, string) lives in `runtime/core/`.
