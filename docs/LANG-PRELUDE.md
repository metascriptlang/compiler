# Prelude and builtin names

The default imports and their order are `defaultGlobalImports` in `src/checker/prelude.ms`;
project additions belong to the build configuration described in [PACKAGE.md](PACKAGE.md).
Do not copy that module list here: installed support trees and the compiler must agree on it.

Language meaning belongs to [LANG.md](LANG.md); application import/extension choices belong
to [LANG-PREFERENCE.md](LANG-PREFERENCE.md). The implementation split between language
intrinsics, compiler-recognized operations and ordinary std declarations is explained in
[FEATURES.md](FEATURES.md).

Why ordinary declarations where possible? Normal name resolution, imports and extension
methods let the library carry behavior without hard-coding each public name in the compiler.
That does not turn every familiar JavaScript name into a prelude API. Check the actual
export and its consumer, and keep backend-specific foreign bindings separate.

The former `std/core.ms` module list, `@runtime` declaration recipe and `Math.pi` examples
are retired, not alternative authoring forms. `git log -- docs/LANG-PRELUDE.md` retains their
history; it is not a support table.
