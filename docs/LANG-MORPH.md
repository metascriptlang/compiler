# Generic specialization

Author-visible generic meaning and limits live in [LANG.md](LANG.md#generics);
compositions belong to [LANG-PREFERENCE.md](LANG-PREFERENCE.md#11-reuse-types-extend-behavior-and-specialize-work).
The checker owns inference and instantiation (`src/checker/instantiate.ms`); emission/lowering
handoffs are in [PIPELINE.md](PIPELINE.md).

Why specialize? A native consumer needs concrete types and callable bodies, not a signature
whose generic parameter has merely been parsed. Lookup scope, constraint enforcement and
body checking are independent obligations. An unresolved constraint accepted by the checker
is an [enforcement hole](CONTRACTS.md#bounded-findings-not-new-features), not support for an
arbitrary operation-based concept.

The former parser side-channel, `MonoRegistry`, fixed iteration limit and three-pass
monomorphizer description are retired, not the current algorithm. Source owners and their
real consumers take precedence over that copied implementation inventory.
History: `git log -- docs/LANG-MORPH.md`.
