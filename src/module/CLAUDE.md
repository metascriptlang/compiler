# Module System

## C Header Import

### Layout

```
src/module/cparse/       ← Pure C parser (chibicc port). Tokenize, preprocess, parse.
src/module/cimport/
  emit.ms                ← C→MS type mapping + declaration emission
  index.ms               ← Public API: parseHeader (single sync entry, aggregates diagnostics)
  cli.ms                 ← Standalone CLI for testing
```

### Dependency Rules

- `src/module/cparse/` depends on `std/` only. No compiler imports. No MetaScript knowledge. Pure chibicc port.
- `src/module/cimport/index.ms` depends on cparse (calls tokenize → preprocess → parse).
- `src/module/cimport/emit.ms` depends on cparse types (`Obj`, `CType`) and index.ms (parseHeader). Knows MetaScript type names.
- All compiler files import `translateCHeader` from `src/module/cimport/emit`.

### Flow

```
import { foo } from "header.h"
  → loader.ms inlineHeaderImports calls translateCHeader()
    → cimport/emit.ms calls parseHeader()
      → cimport/index.ms: tokenize → preprocess → parse (cparse/*.ms, chibicc port)
      ← returns Obj[] + diagnostics (all three phases aggregated)
    ← walks Obj[], maps C types → MS types; skips names already emitted by an
      earlier import site of the same module (shared-typedef dedup)
  ← returns MetaScript extern declaration source string + diagnostics
→ loader surfaces diagnostics as module errors anchored at the .ms import line
  (DiagSeverity.Error fails the build via exitOnModuleErrors; lesser severities
  render as warnings)
→ main compiler parses the MS source through normal pipeline
```
