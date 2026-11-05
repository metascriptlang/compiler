# Value and reference types

Current meaning is in [LANG.md](LANG.md): [interfaces](LANG.md#interfaces),
[structs](LANG.md#structs), [parameter modes](LANG.md#parameter-modifiers) and
[collection storage](LANG.md#collection-storage-contracts). Preferred data/API choices belong
to [LANG-PREFERENCE.md](LANG-PREFERENCE.md).

The former automatic mutable-parameter ABI, value `Array<T>` and unfinished inheritance/
vtable roadmap are retired, not alternate rules. Their history is in
`git log -- docs/LANG-STRUCT.md`. Representation, access and ownership are separate questions;
see [Advanced contracts](CONTRACTS.md).

## Historical object-representation measurement

Preserved from the earlier document, **not rerun or promoted to current support/performance**:
self-host `msc check src/index.ms`, `--danger --cc=clang` builds of tree `776cc949` against
tree `9028d273`, interleaved A/B, four pairs, macOS arm64. Recorded RSS was 1059 → 921 MB,
instructions 60.6 → 61.1 G, user time within noise. AST payloads became separate cells:
`NodeData` changed from 136 bytes inline to a 16-byte tag plus pointer; `Node` from 248 to
128 bytes (`clang sizeof` on emitted `std/meta/node.ms`). The original record named
`src/test/guard/typeObjectRef.ms` and `unionRefSlot.ms`. It did not provide a fresh certificate
for all interfaces, dispatch forms, hooks or backends, and this documentation repair adds none.
