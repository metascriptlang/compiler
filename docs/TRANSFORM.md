# Transform Architecture

Phase 3 of the compilation pipeline: rewrites the typed AST before the analyzer and codegen.
What the phase does, its walks and shared helpers, and the order contracts between passes are in
[`PIPELINE.md`](PIPELINE.md) §Phase 3; the directory map is in
[`PROJECT-STRUCTURE.md`](PROJECT-STRUCTURE.md). This file keeps what neither the code nor those
two say.

The pass list is the code, and no doc copies it: `transformProgram` in `src/transform/index.ms`
(shared, each step gated by `jsBackend` where a backend needs it), `transformForNative` in
`src/transform/native/index.ms` (C only, after the shared list) and `lowerForRaiser` in
`src/transform/raiserLowering.ms` (Raiser). A per-pass table was removed because it listed 43
steps while `transformProgram` holds 87 `result =` steps (counted at `ee94ff981`), so it was wrong
within weeks of each edit.

## Gate a shared lowering on a capability, not a backend name

`TransformContext` (`src/transform/context.ms`) carries `jsBackend`, `raiserBackend` and the
capability flag `keepBuiltinMemberCalls`. Backends that resolve builtins natively (Raiser's
opcodes for `arr.push`, `console.*`) set it, and `extensionMethodLower` then leaves those calls
as member calls; mangled-name backends (C) keep it false and get the direct-call form that member
codegen depends on. A shared lowering must gate on a flag like this: a new backend sets the flag,
and a Raiser-only skip never silently breaks the C pipeline, which is what happened when the
skip was ungated.

## Transforms that do not exist

| Not built | Why |
|-----------|-----|
| a `Record<K, V>` transform | the checker resolves it: `string` or `number` keys give `Map<K, V>`, literal keys an object type (`docs/LANG.md`) |
| a Date transform | one type does not justify a transform |
| an AST validator pass | a defensive post-pass; fix the transform that produced the bad shape instead of validating after it |

## Variant-read traversal verification

The `checkVariantReads` fold (`src/transform/native/unionProjectLower.ms`) shares traversal,
not representation or pipeline position. C runs it from `lowerNativeAccess`
(`src/transform/native/nativeLower.ms`, after the analyzer); JS runs it in `transformProgram`
before Maybe erasure. Moving either stage is a separate change, not part of removing the
duplicate walk.

Measured 2026-10-03 against a source-matched control at `712d8990`: emitted C and JS
were byte-identical for narrowed/shared/nested/post-guard reads and corpus `789`, `685`,
`241`, `788` (10 comparisons). The consumer printed
`n=3 s=9 nest=7 guarded=3 fl=1.5` on both backends.
No broader corpus or performance claim follows from this probe set.
