# Module System

## C Header Import

### Layout

```
src/module/cparse/       ← Pure C parser (chibicc port). Tokenize, preprocess, parse.
src/module/cimport/
  emit.ms                ← C→MS type mapping + declaration emission
  index.ms               ← Orchestration: parseHeader, parseHeaders, cache, sink
  cache.ms               ← HeaderCache actor (dedup #include across parallel jobs)
  sink.ms                ← DiagnosticSink actor (deterministic diagnostic merging)
  cli.ms                 ← Standalone CLI for testing
```

### Dependency Rules

- `src/module/cparse/` depends on `std/` only. No compiler imports. No MetaScript knowledge. Pure chibicc port.
- `src/module/cimport/index.ms` depends on cparse (calls tokenize → preprocess → parse). Orchestrates parallelism via spawn/actors.
- `src/module/cimport/emit.ms` depends on cparse types (`Obj`, `CType`) and import.ms. Knows MetaScript type names.
- All compiler files import `translateCHeader` from `src/module/cimport/emit`.

### Flow

```
import { foo } from "header.h"
  → loader.ms calls translateCHeader()
    → cimport/emit.ms calls parseHeader()
      → cimport/index.ms orchestrates: tokenize → preprocess → parse
        → cparse/*.ms does the actual C parsing (chibicc port)
      ← returns Obj[] + diagnostics
    ← walks Obj[], maps C types → MS types
  ← returns MetaScript extern declaration source string
→ main compiler parses the MS source through normal pipeline
```
