# cparse — C header parser

C11 header parser: tokenize → preprocess → parse → `Obj[]` + `CType` trees + diagnostics. Ported from [chibicc](https://github.com/rui314/chibicc) (Rui Ueyama, MIT). Consumer, layout and the import flow: [`src/module/CLAUDE.md`](../CLAUDE.md).

## Rules

- **Imports come from `std/` only** — nothing from `src/ast/`, `src/checker/`, `src/parser/`, `src/compiler/`; the one exception is `test.ms`, which drives the pipeline through `../cimport/index`.
- **Pure C library** — input is C source text, output is `Obj[]` and `CType`; the C→MS type mapping lives in the consumer, `src/module/cimport/emit.ms`.
- **No module-level state** — every phase threads its own context value; a parse is re-entrant.
- **No `exit()`** — errors become `Diagnostic` values; one bad declaration is skipped and the rest of the header still parses.
- **An unsupported construct drops its declaration, never the header** — name it in a `Diagnostic` with its source location; do not crash, do not pass silently.
- **Sizes, alignment and struct layout come from `TargetInfo`** — never a hardcoded ABI; `target.ms` also supplies the predefined macros per target, set before preprocessing so headers take the right `#if` branch.
- **Function bodies are brace-matched and dropped** — expressions are parsed only as integer constant expressions (enum values, array sizes, `#if`).
- **Memory is ordinary allocation** — no arena that is never freed; a parse is short-lived.
- **Stays out until a real header needs it** — C23, MSVC struct layout (Itanium rule only), a cache inside this module. C++ never.

## Not in the code

Counted by `grep` over `cparse/*.ms` and `cimport/*.ms`, not by running headers through it:

- `__has_include`, `__has_feature`, `__has_attribute`, `__has_builtin`, `#include_next` — no occurrence.
- `__attribute__((packed))` / `((aligned(n)))` — `parse.ms` skips every attribute; `type.ms` lays out `isPacked` structs, nothing sets it from source. `#pragma pack` is skipped with every `#pragma` other than `once`.
- `parse.ms` reports two diagnostics; its recovery paths skip to the next `;` without one.

## Tests

```bash
msc test src/module/cparse/test.ms
```
