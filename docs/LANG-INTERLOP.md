# C interop

Language contracts live in [LANG.md](LANG.md#extern-declarations-ffi). Working binding,
header-import and retained-callback compositions belong to
[LANG-PREFERENCE.md](LANG-PREFERENCE.md#10-use-c-directly-make-the-boundary-explicit).
[Advanced contracts](CONTRACTS.md#foreign-boundary-the-implementation-is-outside-metascript)
defines what the foreign declaration must promise and what the compiler cannot inspect.

## Why a binding needs more than an imported signature

A header describes a C-facing type and symbol; it does not establish ownership, retention,
return aliases, valid extents, callback teardown, thread affinity or hidden effects. An
explicit MetaScript declaration has the same boundary. Review the real foreign consumer,
not only a successful import or a type-checking call.

`from` names the native symbol, not a header. Header inclusion and companion compilation are
separate concerns; use the current reference/authoring recipes rather than the former
`from "header.h"` examples. The parser owner is `parseExternDecl` in
`src/parser/statements/declaration.ms`. Header loading starts at `headerModuleSource` in
`src/module/loader.ms`; the native parser/importer lives under `src/module/cparse/` and
`src/module/cimport/`. The old Zig/ARO implementation plan is retired, not current architecture.

Do not duplicate the importer's type-mapping table here: parameter, return and field positions
need not use the same mapping. Likewise a C function pointer and a closure with an environment
are not interchangeable merely because both look callable. Trace the actual position and
exercise its C consumer before advertising ABI support. Full native-layout and callback parity
was not established by the concept-map audit.

## Preserved historical boundary measurements

These observations were in the earlier document; **none was rerun for this redirect**:

- 2026-09-26, recompiler `fc5e0b23` and `1718d72c`, C: wrong-typed arguments exposed imported
  parameter types. This was not a return/field-layout certificate.
- 2026-09-29, C tree `80d320e9`: a header/companion pair retained an address; raw-address refusal,
  explicit round-trip casts and `Handle.retain`/`Handle.at` were exercised. This did not establish
  arbitrary foreign-thread callbacks or all teardown paths.
- 2026-10-27, candidate and gcc 15.2 on macOS arm64: `cImportPointeeIdentity` built with
  `--cc=gcc-15`; GNU-host and Windows behavior were not measured.
- 2026-10-28, C: `importedConstPointerFieldIndexes` covered uint8/int32 pointer fields into Vec,
  fixed-array and struct storage; other field types were not re-measured.
- 2026-10-29, candidate on Linux oci-u: `cFunctionPointerSinkArgumentStaysPlain` printed
  `6 10 2|15|10` on C, danger, Raiser and ASan. Deeper nesting than one array/generic argument
  was not measured. The original record supplied no candidate tree for these last three rows.

`git log -- docs/LANG-INTERLOP.md` retains the old examples and plans; they are not additional
binding rules or freshly verified recipes.
