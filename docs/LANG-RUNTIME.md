# Runtime boundaries

The runtime must carry the language's meaning across targets; a native representation is
not itself a language contract. Current [text/byte semantics](LANG.md#strings-and-characters)
and [collection storage contracts](LANG.md#collection-storage-contracts) live in LANG.md.
A string is not a writable byte array, and a shared array is not a value Vec.

Why keep common operations in MetaScript? One implementation can express the same algorithm
for different consumers instead of maintaining hand-copied behavior per backend. Native
allocation, host integration and representation-specific work still require their actual
host/runtime implementation. This division does not establish target parity without running
the real consumer.

- Memory/lifecycle architecture: [ANALYZER.md](ANALYZER.md).
- Evaluator representation and execution: [RAISER.md](RAISER.md).
- Phase handoffs and emission: [PIPELINE.md](PIPELINE.md).
- Manual/freestanding hosts: [BARE.md](BARE.md).
- Foreign trust, internal proof gaps and evidence scope: [CONTRACTS.md](CONTRACTS.md).

Implementations are under `std/core/` and `runtime/`; trace the operation actually reached
instead of maintaining a copied method inventory or target file tree. The former mutable-
string, deep-copy `T[]`, `runtime/orc.h` and “all done/not started” tables are retired.
`git log -- docs/LANG-RUNTIME.md` retains that design history, not current feature status.
