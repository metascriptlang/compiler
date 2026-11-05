# Raw addresses and native memory

Current address, retention and view contracts are in
[LANG.md](LANG.md#unknown-ptrvoid-handlet--one-construct-per-job) and
[the FFI authoring recipes](LANG-PREFERENCE.md#10-use-c-directly-make-the-boundary-explicit).
The distinction between foreign trust and checkable internal lifetimes is defined once in
[Advanced contracts](CONTRACTS.md).

The former `Pointer<T>` runtime-rewrite proposal is retired, not current syntax or a manual
allocator recipe. In a prelude-only check on installed binary/support `56ad1fdf80f`,
`let address: Pointer<int32>;` was refused with `Unresolved type 'Pointer' - missing import?`.
That observation does not rule out a library defining its own alias.

Native runtime implementation lives under `runtime/`; consult the actual allocation and
representation owners rather than copying a schematic payload header from an old design.
History: `git log -- docs/LANG-RAW.md`.
