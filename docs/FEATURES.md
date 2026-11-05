# Builtins, std declarations and compiler operations

## Why the public surface is declared in MetaScript

Normal declarations give the checker real types, ordinary resolution and extension methods
without a separate hard-coded signature table for every familiar public name. A native
binding still needs an honest foreign contract; declaring its signature is not proof of its
implementation. [LANG-PRELUDE.md](LANG-PRELUDE.md) points to the default import owner.

Three concerns must remain distinct:

- Ordinary MetaScript bodies carry portable library behavior.
- Foreign declarations bind a host implementation; the [FFI reference](LANG.md#extern-declarations-ffi)
  and [boundary obligations](CONTRACTS.md) govern what that declaration promises.
- Compiler-recognized operations require checking/lowering the language cannot express as an
  ordinary call. Their identity is `BuiltinKind` in `std/meta/node.ms`; recognition and
  declaration metadata live in `src/checker/decoratorHelpers.ms` and `collectPass.ms`.

A familiar JavaScript name is not automatically a compiler intrinsic or an available API.
Likewise an intrinsic's AST identity is not evidence that every backend implements it.
For author-visible meaning use [LANG.md](LANG.md); for the smallest usable compositions use
[LANG-PREFERENCE.md](LANG-PREFERENCE.md).

## Decorators and directives

Their syntax/contracts and dated observations belong to
[LANG-METAPROGRAMMING.md](LANG-METAPROGRAMMING.md), not a second implementation-status table.
The recognized directive/compiler-decorator list is `passThroughDirectives` in
`src/checker/decoratorHelpers.ms`. The evaluator is the [Raiser](RAISER.md).

The former pending parser/runtime roadmap, Hermes labels and “REF ONLY/DESIGN” table are
retired. History: `git log -- docs/FEATURES.md`. They are not a capability backlog or authority
for bypassing the normal checker/transform/emitter boundaries in [PIPELINE.md](PIPELINE.md).
