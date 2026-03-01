# C Interop — Importing `.h` Files from MetaScript

MetaScript provides seamless C interoperability through two complementary mechanisms: **manual extern declarations** (lightweight, no dependencies) and **automatic header import** (extracts symbols from `.h` files). The reference compiler uses libclang; the self-hosted compiler will use **ARO** (Zig-based C parser, MIT, ~5 MiB) via FFI. Both produce the same checked AST — the rest of the pipeline is unaware of the origin.

---

## Overview

```
                       ┌─────────────────────────────────┐
                       │       MetaScript Source          │
                       │                                  │
                       │  import { foo } from "./lib.h";  │
                       │  extern function bar(): void;    │
                       │  @include("./lib.h")             │
                       └──────────┬──────────────────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              ▼                   ▼                   ▼
    ┌─────────────────┐ ┌─────────────────┐ ┌────────────────┐
    │ import from .h  │ │ extern decl     │ │ @include       │
    │ (auto-extract)  │ │ (manual)        │ │ (compile hint) │
    └────────┬────────┘ └────────┬────────┘ └───────┬────────┘
             │                   │                  │
             ▼                   ▼                  ▼
    ┌─────────────────┐ ┌─────────────────┐ ┌────────────────┐
    │ ARO parses .h   │ │ Parser creates  │ │ Stored on      │
    │ → extract decls │ │ ExternDecl node │ │ Program node   │
    │ → register as   │ │                 │ │ as CompileSource│
    │   extern symbols│ │                 │ │                │
    └────────┬────────┘ └────────┬────────┘ └───────┬────────┘
             │                   │                  │
             └───────────────────┼──────────────────┘
                                 ▼
                       ┌─────────────────┐
                       │ Checker (3-pass)│
                       │ Normal symbols  │
                       └────────┬────────┘
                                ▼
                       ┌─────────────────┐
                       │ Codegen emits   │
                       │ #include + call │
                       └─────────────────┘
```

---

## Mechanism 1: `import { ... } from "./file.h"` (Automatic)

The compiler uses **libclang** to parse the C header and extract symbols as MetaScript-typed AST nodes. This is the primary mechanism for consuming C APIs.

### Syntax

```ms
// Named import — only extract specified symbols (faster, DCE-friendly)
import { msBuffer, ms_buffer_alloc, ms_buffer_length } from "./buffer.h";

// Re-export from header
export { msBuffer } from "./buffer.h";
```

### Pipeline

1. **Module Resolver** (`resolver.zig:82-84`): Detects `.h` extension, routes to `resolveCHeader()`.
   - Relative: `./lib.h` → join with importing file's directory
   - Runtime: `ms_net.h` → search `<metascript>/src/runtime/`
   - System: `stdio.h` → search `/usr/include`, Xcode SDK, `/opt/homebrew/include`

2. **Module Loader** (`loader.zig:681-796`): Calls `loadCHeader()`:
   - Phase 1: `CParser.parseHeader()` — libclang parses `.h`, extracts `CBindings` (functions, structs, enums, typedefs, `#define` constants)
   - Phase 2: `CTransformer.transform()` — converts C declarations to MetaScript AST nodes (`extern_function_decl`, `extern_class_decl`, `extern_enum_decl`, `variable_stmt`)
   - Phase 3: Creates `Module` with `is_c_header = true`, collects exports via `collectCExports()`
   - Named imports: only requested symbols are extracted (filter passed to libclang visitor)

3. **Type Checker**: Validates extern declarations normally — creates function types, registers symbols.

4. **Codegen** (`cgen.zig:19440-19460`): For each used extern with a `header` field, emits `#include "header.h"`. DCE-safe — unused headers not included.

### Type Mapping (C → MetaScript)

| C Type | MetaScript Type |
|--------|----------------|
| `int`, `int32_t` | `number` (int32) |
| `double`, `float` | `number` (float64) |
| `char*`, `const char*` | `string` |
| `bool`, `_Bool` | `boolean` |
| `void` | `void` |
| `T*` | `Ptr<T>` |
| `struct Foo` | `Foo` (extern class) |
| `enum E { A, B }` | `enum E { A, B }` |
| `typedef X Y` | `type Y = X` |
| `#define FOO 42` | `const FOO: number = 42` |

### Example: Buffer Module

```ms
// std/buffer/index.cms
@include("./buffer.h")   // tells build system to #include + auto-compile buffer.c

export { msBuffer } from "./buffer.h";

import {
    msBuffer,
    ms_buffer_alloc,
    ms_buffer_from_string,
    ms_buffer_length,
    ms_buffer_get,
    ms_buffer_set,
} from "./buffer.h";

// Now use C functions with full type checking:
const buf = ms_buffer_alloc(1024);
const len = ms_buffer_length(buf);
```

---

## Mechanism 2: `extern` Declarations (Manual)

Manually declare C symbols without needing libclang. The programmer writes type signatures that match the C API.

### Syntax

```ms
// Basic extern function
extern function printf(fmt: string): number;

// With header hint — codegen emits #include, skips forward declaration
extern function ms_socket_create(domain: number, sockType: number, protocol: number): number
    from "ms_net.h";

// With compile hint — also compile the .c source
extern function my_helper(x: number): number
    from "my_helper.h" compile "my_helper.c";

// Extern class (opaque C struct — no fields visible)
extern class FILE;

// Extern enum
extern enum FileMode { Read, Write, Append }

// Extern constant
extern const STDIN: FILE;

// Extern variable
extern var errno: number;
```

### `from "header.h"` Pragma

The `from` clause on extern functions serves two purposes:
1. **Codegen**: Emits `#include "header.h"` in the C output (deduplicated)
2. **Forward decl suppression**: Since the header provides the declaration, codegen skips emitting a prototype

This mirrors Nim's `{.header: "header.h".}` pragma — symbols are declared in MetaScript for type checking but codegen trusts the header to provide the actual C declaration.

### `compile "file.c"` Pragma

Tells the build system to compile a companion C source file alongside the header. This mirrors Nim's `{.compile: "file.c".}` pragma.

### ExternDecl AST

```ms
// Reference compiler AST (node.zig)
ExternFunctionDecl {
    name: string,
    native_name: ?string,      // optional C name override
    params: FunctionParam[],
    return_type: ?Type,
    is_variadic: boolean,
    header: ?string,            // from "header.h"
    compile_source: ?string,    // compile "file.c"
}
```

### Self-Hosted Parser Status

The self-hosted parser (`declaration.ms:959-1020`) parses `extern` declarations but stores them as a simplified `ExternDecl { externKind, externName }` — no parameter types, no `from`/`compile` pragmas. This is sufficient for skipping extern blocks but doesn't extract type information.

---

## Mechanism 3: Module-Level Directives

Module-level pragmas control the C build pipeline. They are **always file-level** (never attached to declarations) and **always included** (not tree-shaken).

### Syntax

```ms
@include("./lib.h")              // #include + auto-compile matching .c if exists
@include("../../vendor/foo.c")   // compile C source directly
@link("./build/libfoo.a")        // link pre-built archive
@passC("-I../../vendor/include") // raw C compiler flag
@passL("-lssl")                  // raw linker flag
```

### AST: CompileSource

```
CompileSource {
    path: string,
    kind: .header | .source | .archive | .cflag | .ldflag
}
```

Stored on `Program.compile_sources[]`. Parser extracts these from decorator position before statement parsing — they look like decorators (`@include(...)`) but are consumed as file-level pragmas.

### Auto-Compile Convention

When `@include("foo.h")` is encountered:
1. Codegen emits `#include "foo.h"`
2. Build system checks if `foo.c` exists in the same directory
3. If found, adds `foo.c` to the compilation unit automatically

This is the standard pattern for C modules: header declares API, source implements it. No explicit `compile` directive needed.

### Build System Integration

```
@include + @link + @passC + @passL
        │
        ▼
  CompileFeatures {
      extern_compile_sources: string[],  // .c files to compile
      extern_link_libs: string[],        // .a archives to link
      extern_cflags: string[],           // -I flags, etc.
      extern_ldflags: string[],          // -l flags, etc.
  }
        │
        ▼
  cc.compileMulti() → clang invocation
```

---

## Mechanism 4: `@cImport` Decorator (Function-Level, DCE-Safe)

Unlike module-level `@include`, function-level `@cImport` is tree-shaken — the header is only included if the decorated function is reachable from `main()`.

```ms
@cImport("<curl/curl.h>")
export function fetchUrl(url: string): string {
    // ... uses curl internally
}
```

If `fetchUrl` is never called, `<curl/curl.h>` is never included. This is critical for library modules that declare many FFI functions but users only use a subset.

---

## DCE Strategy Summary

| Mechanism | Tree-Shaken? | When Included |
|-----------|:---:|---|
| `@include("foo.h")` | No | Always (module-level) |
| `@link("lib.a")` | No | Always (module-level) |
| `@cImport("<header>")` on function | Yes | Only if function is reachable |
| `extern function ... from "header.h"` | Yes | Only if extern is used |
| `import { x } from "./lib.h"` | Yes | Only if `x` is used |

---

## Naming Conventions

### C-to-MetaScript Name Preservation

C function names are preserved as-is. The `CTransformer` does **not** rename `ms_buffer_alloc` to `bufferAlloc`. Codegen emits the original C name.

For cases where the C name differs from the MetaScript name, use `native_name`:

```ms
// Parser supports this in reference compiler:
extern function printf "ms_printf" (fmt: string): number;
// Declares MetaScript symbol "printf", emits C call to "ms_printf"
```

### Mangling

Extern functions are **never mangled** — they use their declared name verbatim in C output. This is controlled by the `header` field: when present, codegen skips forward declaration entirely (the `#include` provides it).

---

## Backend-Specific Files (`.cms`)

MetaScript supports backend-specific module files with the `.cms` extension (C-specific). The module resolver prioritizes these:

1. `std/buffer/index.cms` (C-backend specific) — preferred when targeting C
2. `std/buffer/index.ms` (generic) — fallback

This allows modules to provide different implementations per backend. The buffer module uses `.cms` because its C interop (`@include`, `import from .h`) is meaningless on the JS backend.

---

## Self-Hosted Implementation Status

| Feature | Reference Compiler | Self-Hosted | Notes |
|---------|:---:|:---:|---|
| `extern function` parsing | DONE | PARTIAL | Self-hosted parses kind+name only, no params/return type |
| `extern class/enum` parsing | DONE | PARTIAL | Parsed as ExternDecl, no struct/enum fields |
| `from "header.h"` pragma | DONE | NOT YET | Parser doesn't recognize `from` after extern |
| `compile "file.c"` pragma | DONE | NOT YET | Parser doesn't recognize `compile` after extern |
| `@include`/`@link`/`@passC`/`@passL` | DONE | NOT YET | Parser sees decorator but doesn't extract as CompileSource |
| `import { x } from "./file.h"` | DONE | NOT YET | Module resolver doesn't handle .h |
| C header parsing | DONE (libclang) | NOT YET | **Planned: ARO via FFI** (replaces libclang) |
| CompileSource on Program node | DONE | NOT YET | ProgramData has no compile_sources field |
| Build system integration | DONE | NOT YET | cc.ms doesn't handle extern sources |

---

## Self-Hosted C Parser Strategy: ARO via Zig FFI

### Decision: ARO over libclang

The reference compiler statically links libclang (109 MiB binary, 7 GB vendored LLVM). For the self-hosted compiler, we use **ARO** ([github.com/Vexu/arocc](https://github.com/Vexu/arocc)) — a standalone C89-C23 parser written in Zig, MIT licensed, actively maintained by a Zig core team member.

| | libclang (reference) | ARO (self-hosted) |
|---|---|---|
| Binary size | +109 MiB | +~5 MiB |
| Vendored deps | 7 GB LLVM | ~2 MB Zig module |
| C standard | C89-C17 | C89-C23 + GNU/Clang extensions |
| Preprocessor | Full | Full |
| License | Apache-2.0 | MIT |
| Macro translation | `#define` constants only | Full (object + function macros) |
| Maintenance | External (LLVM project) | External (Vexu/arocc, synced with Zig) |

### Architecture

```
vendor/aro/              ←── git submodule (github.com/Vexu/arocc)
    │
src/cheader/aro_ffi.zig  ←── thin Zig wrapper (~200 lines), exports C ABI functions
    │  zig build → libaro_ffi.a
    ▼
src/cheader/index.ms     ←── MetaScript FFI layer (~200 lines)
    │  extern function aro_parse_header(...): Ptr<void>;
    ▼
checker/collectPass.ms   ←── registers extracted symbols as extern declarations
```

**Zig wrapper** exports ~5 C functions:
```c
AroResult* aro_parse_header(const char* path, const char** include_dirs, int n);
int         aro_result_num_functions(AroResult* r);
const char* aro_result_function_name(AroResult* r, int idx);
const char* aro_result_function_return_type(AroResult* r, int idx);
// ... similar for structs, enums, typedefs, defines
void        aro_result_free(AroResult* r);
```

**ARO API flow** (inside aro_ffi.zig):
```zig
var comp = try aro.Compilation.initDefault(gpa, arena, io, &diag, cwd);
const source = try comp.addSourceFromPath(path);
var pp = try aro.Preprocessor.initDefault(&comp);
try pp.preprocessSources(.{ .main = source, .builtin = builtins });
var tree = try aro.Parser.parse(&pp);
// Walk tree.root_decls → extract functions, structs, enums, typedefs
```

**Build integration**: `@link("aro_ffi")` in MetaScript, built via `zig build` as part of the compiler build process.

### Implementation Phases

**Phase 1** — Manual extern with build hints (no header parsing):
1. Expand `ExternDecl` AST to include params, return type, header, compile_source
2. Parse `from "header.h"` and `compile "file.c"` after extern declarations
3. Add `CompileSource` to `ProgramData`, parse `@include`/`@link`/`@passC`/`@passL`
4. Codegen: emit `#include` for extern headers, collect compile sources
5. Build system: wire CompileFeatures into cc.ms clang invocation

**Phase 2** — Automatic header import via ARO:
1. Set up `vendor/aro` git submodule
2. Write `src/cheader/aro_ffi.zig` — thin C API over ARO's Compilation/Preprocessor/Parser/Tree
3. Write `src/cheader/index.ms` — MetaScript extern declarations + result conversion
4. C header resolver in module/resolver.ms (`.h` path detection)
5. Wire into collectPass (register extracted symbols as extern declarations)

Phase 1 covers 90% of use cases (all `std/runtime/*.ms` patterns). Phase 2 enables `import { x } from "./file.h"` syntax with full C89-C23 support.

---

## Reference Files

| Component | File | Lines |
|-----------|------|-------|
| **Reference Compiler** | | |
| Parser (extern + directives) | `~/projects/metascript/src/parser/parser.zig` | 183-250, 1607-1654 |
| AST (FileImport, CompileSource) | `~/projects/metascript/src/ast/node.zig` | 1619-1652 |
| Module resolver (.h paths) | `~/projects/metascript/src/module/resolver.zig` | 64-333 |
| Module loader (loadCHeader) | `~/projects/metascript/src/module/loader.zig` | 681-880 |
| libclang bindings | `~/projects/metascript/src/interop/c/clang.zig` | 200-520 |
| C→MS AST transformer | `~/projects/metascript/src/interop/c/transform.zig` | 1-100 |
| Codegen (#include emission) | `~/projects/metascript/src/codegen/c/cgen.zig` | 2930-3142, 19440-19460 |
| Build system (CompileFeatures) | `~/projects/metascript/src/build/cc.zig` | 43-506 |
| Self-hosted extern parser | `src/parser/statements/declaration.ms` | 959-1020 |
| **ARO (Zig C Parser)** | | |
| Upstream repo | `github.com/Vexu/arocc` | MIT, 1595 stars |
| Compilation entry | `aro/Compilation.zig` | init, addSource, generateBuiltinMacros |
| Preprocessor | `aro/Preprocessor.zig` | preprocessSources, initDefault |
| Parser | `aro/Parser.zig` | parse(pp) → Tree |
| AST | `aro/Tree.zig` | root_decls, Node types, tokSlice |
| Types | `aro/TypeStore.zig` | QualType, Type specifiers |
| **Zig translate-c (reference usage)** | | |
| ARO integration | `~/projects/zig/lib/compiler/translate-c/main.zig` | Full ARO init + parse flow |
| C→Zig type translator | `~/projects/zig/lib/compiler/translate-c/Translator.zig` | 1061-1180 |
| Macro translator | `~/projects/zig/lib/compiler/translate-c/MacroTranslator.zig` | 51K |
