# MetaScript Standard Library

## Layout

- `core/` — the prelude, loaded for every program with no import; the list and its order live in `src/checker/prelude.ms`. `core/string/shared.ms` holds the portable byte-tier algorithms for all backends, the `index.*` files beside it the per-backend kernels (contract: `docs/STRING-CONTRACT.md`); `core/struct.ms` is Map/Set/HashMap/HashSet in C, `core/struct.jms` the same surface bound to native JS.
- Everything else is imported by path: `fs/`, `io/`, `process/`, `os/`, `net/`, `http/`, `https/`, `crypto/`, `serialize/` (json, cbor, contracts), `compress/`, `archive/`, `hash/`, `actor/`, `meta/`, `build/`, `runtime/`, `surreal/`, `toycodec/`.
- All C lives in `runtime/` at the repo root, none under `std/`; a `.cms` reaches it with `@include("runtime/...")` and `@compile("runtime/...")`.

## File types

| Extension | Purpose | Backend |
|-----------|---------|---------|
| `.ms` | Pure MetaScript implementation | All |
| `.cms` | C-backend module (native bindings + MS wrappers) | C only |
| `.jms` | JS-backend module (native binds via `extern ... from "pattern"`) | JS only |
| `.rms` | Raiser-backend module | Raiser only |

## Rules

- **`std/` never imports `src/`** — `std/` is copied standalone to `~/.metascript/std` at install and `src/` is not, so an `import ... from "../../src/..."` resolves in the repo tree and breaks every installed `msc` (the prelude chain loads for all programs). Shared types live in `std/` (`std/meta/node.ms`, `std/meta/token.ms`) and `src/` re-exports them. Incident: `std/meta/node.ms` imported `src/lexer/token` from 2026-03-31 to 2026-07-03, unseen because every gate runs inside the repo.
- **Prefer `.ms` over `.cms`** — a `.cms` is for real C/POSIX calls (file I/O, syscalls, malloc); pure string, array and number logic is `.ms` with inline tests.
- **A module directory's entry is its `index.*`** — `import { readFile } from "std/fs"` resolves to `std/fs/index.cms` on C; a sub-module imports directly (`import { dirname } from "std/fs/path"`).
- **The C binding is private, the MS function is the API** — `@include` the header, declare `extern function msDoThing(...)`, export a wrapper `doThing(...)` that calls it. `std/fs` binds the other way, importing its `msFs*` names from `"runtime/fs/header.h"`.
- **C names are `ms` + PascalCase module + method** — `msFsReadFile`, `msStringIndexOf`, `msProcessCwd`.
- **`&` in the `from` string marks a C function that mutates its receiver** — `extern function push(this arr: number[], sink value: number): void from "&msNumberArrayPush"`; `this` on the first parameter makes it an extension method.
- **The `.cms` wrapper converts the C return into the MS type** — `export function exists(path: string): boolean { return msFsExists(path) == 1; }`.

| MS return | C return | On failure |
|-----------|----------|------------|
| `string` | `msString` | `MS_EMPTY_STRING` |
| `boolean` | `double` | `1.0` true, `0.0` false |
| `number` | `double` | `-1.0` for "not found" |
| `void` | `void` | — |

## Module boundaries

| Module | Scope | Does not hold |
|--------|-------|---------------|
| `std/io` | stdin/stdout/stderr only | File I/O, JSON parsing |
| `std/fs` | File operations + path utils | Process control, networking |
| `std/process` | argv, env, cwd, exec, exit | File I/O (use `std/fs`) |
| `std/core/json` | JSON types, parse, stringify | I/O, file reading |
| `std/core/string` | String extension methods | I/O, file operations |
| `std/core/array` | Array extension methods | I/O, file operations |
