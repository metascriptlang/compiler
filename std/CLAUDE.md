# MetaScript Standard Library

## Directory Layout

```
std/
├── CLAUDE.md                  -- this file
├── core/                      -- prelude modules (auto-loaded, no import needed)
│   ├── system/                -- console, Result<T,E>, toString (index.ms/.jms)
│   ├── string/                -- string surface (immutable — docs/STRING-CONTRACT.md):
│   │   ├── shared.ms          --   portable byte-tier algorithms, ALL backends
│   │   └── index.cms/.jms/.rms--   per-backend kernels (js = native string + WTF-8 byte tier)
│   ├── array/                 -- array extension methods (index.cms/.jms/.rms)
│   ├── struct.ms              -- Map/Set/HashMap/HashSet — C implementations
│   │                             (ordered IndexMap + open addressing; @builtin("IndexableMap"))
│   ├── struct.jms             -- same surface bound to native JS Map/Set
│   ├── buffer/                -- binary data; uint8[] mutation tier + asBytes/asString bridges
│   ├── crypto/                -- cryptographic operations (mbedTLS)
│   ├── json/                  -- JSON prelude
│   └── actor/ date/ fetch/ math.ms performance/ promise/ websocket/
├── serialize/                 -- json (encode/decode/accessors/builder), cbor, contracts
├── fs/                        -- file system (index.cms + native.h, path.ms)
├── io/                        -- standard streams (stdin/stdout/stderr only)
├── process/                   -- argv, exit, cwd, exec, getEnv, clockMs
├── http/ https/ net/          -- networking stack
├── actor/ archive/ build/ compress/ hash/ meta/ os/ runtime/ surreal/ toycodec/
└── testing/                   -- test "name" { assert statement; }
```

## File Types

| Extension | Purpose | Backend |
|-----------|---------|---------|
| `.ms` | Pure MetaScript implementation | All backends |
| `.cms` | C-backend prelude (extern declarations + MS wrappers) | C only |
| `.jms` | JS-backend prelude (native binds via `extern ... from "pattern"`) | JS only |
| `.rms` | Raiser-backend prelude | Raiser only |
| `.h` | C runtime header (included via `@include`) | C only |

**Prefer `.ms` over `.cms`+`.h`** when the logic is pure string/array/number manipulation. Only use `.cms` + `.h` when you need actual C/POSIX calls (file I/O, syscalls, malloc, etc.).

## Conventions

### std NEVER imports src/ (deployability invariant)

`std/` is copied standalone to `~/.metascript/std` at install — `src/` is not.
Any `import ... from "../../src/..."` inside `std/` works in the repo tree but
breaks every installed msc (the prelude chain loads it for ALL programs).
Direction is one-way: shared types live in `std/` (e.g. `std/meta/node.ms`,
`std/meta/token.ms`) and `src/` re-exports from them — never the reverse.
Incident: `std/meta/node.ms` imported `src/lexer/token` (2026-03-31 → 2026-07-03);
undetected for months because all gates run inside the repo where the path resolves.

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

## C Runtime

All C runtime code lives in `runtime/` (project root), NOT under `std/`. The `std/` directory contains only MetaScript files (.ms/.cms).

```
runtime/
├── drc.h / .c         -- DRC allocator (malloc + RC + ORC)
├── manual.h           -- Manual allocator (arena + no-op RC, --gc=manual)
├── types.h            -- msRefHeader, msTypeInfo
├── core/              -- core types: system.h/c, string.h/c, array.h/c, buffer.h/c, test.h, abort.h
├── promise/           -- async: future.h, dispatch.h/c, thread.h, locked.h, selector*.c
├── crypto/            -- hashing + ciphers/ + curves/ + kdf/ + tls/ + rsa/
├── io/                -- I/O engines: streams.h, engine.h, engine*.c
├── net/               -- networking: socket.h, async.h
├── actor/             -- actor model: actor.h, cycle.h, mailbox.h, selector.h
├── fs.h, process.h, os.h, hcr.h
```

Prelude `.cms` files reference runtime via `@include("runtime/...")` and `@compile("runtime/...")`.
