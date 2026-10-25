# Module System

## C Header Import

### Layout

```
src/module/cparse/       ← Pure C parser (chibicc port). Tokenize, preprocess, parse.
src/module/cimport/
  emit.ms                ← C→MS type mapping + declaration emission
  index.ms               ← Public API: parseHeader (single sync entry, aggregates diagnostics)
```

### Dependency Rules

- `src/module/cparse/` depends on `std/` only. No compiler imports. No MetaScript knowledge. Pure chibicc port.
- `src/module/cimport/index.ms` depends on cparse (calls tokenize → preprocess → parse).
- `src/module/cimport/emit.ms` depends on cparse types (`Obj`, `CType`) and index.ms (parseHeader). Knows MetaScript type names.
- The loader (`headerModuleSource`) is the one caller of `translateHeaderModule`; checker, Trans-Am and LSP reach a header through it.

### Flow

A C header is a module like any other; its source is translated, not read.

```
import { foo } from "header.h"
  → resolver: header.h resolves beside the importer, then the search paths
  → loader.ms headerModuleSource(path) → cimport/emit.ms translateHeaderModule()
    → cimport/index.ms parseHeader: tokenize → preprocess → parse (cparse, chibicc port)
    ← every declaration with the file that writes it
  ← module source: @include/@compile, then
      import { names } from "<abs path>"; export * from "<abs path>"   for each included header
      export extern …                                                  for what this file writes
→ a header two includers read differently (a macro defined before its #include) is a module error
→ diagnostics are the header module's errors; the source is cached per header (cache.ms Layer 5)
→ the module is parsed and checked like any .ms module
```
