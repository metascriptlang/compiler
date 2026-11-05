# Advanced contracts: boundaries and evidence

Use this guide before combining memory, native bindings, retained callbacks or parallel work.
It explains which promises are independent and where the compiler stops knowing. It does not
add language rules or certify every accepted program as safe.

## One home per question

- [LANG.md](LANG.md): language meaning, typing, conversions and lifetime rules.
- [LANG-PREFERENCE.md](LANG-PREFERENCE.md): how an application author applies those rules.
- This page: boundary obligations, evidence standards and unresolved concept distinctions.
- [ANALYZER.md](ANALYZER.md), [PIPELINE.md](PIPELINE.md) and [RAISER.md](RAISER.md): compiler/evaluator architecture.
- [TESTING.md](TESTING.md): verification recipes. A test name is a place to check, not a fresh pass.

A design record explains a choice; it is not an additional specification. A historical
“complete” label, accepted declaration or reference-compiler feature is not support evidence.
Internal reference/divergence and cross-thread design records live under machine-local
`paper/`; public explanations must remain intelligible without them.

## Keep these questions separate

| Question | Why another answer does not settle it |
|---|---|
| Storage and layout | Inline storage, a shared cell and a raw address have different representations. A cast is not a conversion. |
| Access | Read-onlyness alone does not settle retention, make all aliases immutable or establish exclusive access. The underlying owning/borrowed contract still matters. |
| Ownership and lifetime | Keeping a target alive does not prevent mutation or concurrent access. A non-owning edge needs an owner/lifetime proof. |
| Effects | Which operands or hidden cells a call can write is separate from whether it reads hidden state or returns an alias. |
| Result aliasing and isolation | “No hidden writes” does not prove a fresh result or permission to move an existing alias across threads. |
| Concurrent callability | A function callable on a worker is not thereby free of hidden state, thread affinity or retained arguments. |
| Failure | A typed error value, a thrown exception, a rejected promise and a fatal runtime failure are different paths. |

These are independent obligations, not a request for one new wrapper per row. Reuse an
existing construct when it proves the required fact; do not merge contracts merely because
their names overlap.

## Two boundaries

### Foreign boundary: the implementation is outside MetaScript

For `extern`, raw `Ptr<T>` addresses and retained foreign callbacks, the compiler can check
what is declared on the MetaScript side, not whether foreign code honors the declaration.
The binding author must establish the missing facts:

- ABI/layout, width, alignment, calling convention and the actual native symbol;
- nullability, valid range, initialization and pointer validity;
- who owns, retains and releases the data, and whether the call stores an address;
- hidden reads/writes and return aliases, independently of operand writes;
- allowed threads, reentrancy, callback lifetime, cancellation and teardown ordering.

An address does not keep its target alive. A `Handle<T>` retention obligation is not an
ABI, race-freedom or thread-affinity proof. A read-only argument declaration does not prove
that foreign code refrains from writing through another address. Review the real foreign
consumer, including unregister/join/release paths, rather than only the binding's signature.
See [the authoring standard's FFI recipes](LANG-PREFERENCE.md#10-use-c-directly-make-the-boundary-explicit).

Current `@pure` is a narrow **foreign write-footprint promise**: it exempts an extern from
`WritesCell`; it is not mathematical purity, a no-hidden-read promise, a fresh-return proof
or optimization permission. Source owners are `intrinsicBuiltins` in
`src/checker/decoratorHelpers.ms`, `applyDecoratedInfo` in
`src/checker/collectPass.ms`, and call-effect classification in `src/checker/effects.ms`.
The return-alias/isolation decision in `src/checker/sendable.ms` is a separate check.
No rename, removal or change of the default foreign trust policy is made here.

### Internal proof boundary: both ends are MetaScript

For `Borrow<T>`, `Cursor<T>` and compiler-inferred views, missing lifetime/access checks are
implementation gaps, not a fundamental inability to inspect foreign code. A type's accepted
spelling does not establish that every escape, returned view, owner mutation or stored edge
has been checked.

In particular, do not treat today's `Cursor<T>` as a checked weak reference or a liveness
counter. Its C representation follows its inner type (`getTypeDesc` in `src/codegen/c/types.ms`);
its non-owning classification is in `src/analyzer/classify.ms`. A primitive value target
and a managed-reference target are therefore not interchangeable evidence for a proposed
managed-header check.

A migration must distinguish mutable local/data views, identity-only collections, stored
back edges, arena links and join-protected worker views. Field versus local alone is not a
lifetime proof. Making a view owning can change retention/cycles; adding counter writes can
change thread safety. Neither is a documentation-only rename.

## Pointer/view tools: which side, which proof

This is a boundary/status guide, not another signature or layout reference. “Checked” below
names a kind of check, not a certificate that every path is implemented correctly.

| Tool | Boundary and current limit |
|---|---|
| `extern` | Foreign. MetaScript declaration/argument checks do not inspect the foreign body, hidden aliases or whether the declared effect/thread contract is honored. |
| `Ptr<T>` | Raw-address boundary. Type/address-shape checks do not prove target lifetime, allocation extent, alignment or foreign retention. An internal raw-address use does not become safe merely because no FFI call occurs. |
| `Handle<T>` | `Handle.retain` explicitly retains; `Handle.borrow` does not. Neither proves that the foreign user has stopped before release/owner death, callback affinity or absence of races. Those need the real registration/teardown consumer. |
| `Borrow<T>` | Internal, checkable access/lifetime proof. Not complete: the tested returned-call root bypasses readonly checks that locals/parameters enforce. Do not promote that acceptance to writable access. |
| `Cursor<T>` | Internal non-owning representation. Current non-ownership does not supply a target-liveness check or checked weak-reference semantics. Stored-field lifetime and migration designs remain unresolved. |
| `Span<T>` / `Readonly<Span<T>>` | Internal source-relative views; readonly additionally restricts writes through that view. Neither owns its source. The view/storage cases named in LANG are scoped pins, not proof for every escape or foreign pointer. |
| `Ref<T>` / parameter `ref` | A managed storage tool and a parameter mode, respectively; not synonyms for raw `Ptr`. Follow LANG's distinct lifetime/write-back contracts. Casting their address across FFI reintroduces the foreign obligations. |
| `Readonly<T>` | Restricts access without replacing T's owning/borrowed contract or freezing every alias. It does not by itself prove hidden foreign effects, no retention, fresh returns or thread safety. |

## What a status means

Every status needs a shape, a backend/host and an evidence level:

| Status | Meaning |
|---|---|
| Supported in the checked scope | A named real consumer produced the expected result. State what neighboring shapes were not exercised. |
| Enforcement hole | A promised restriction is bypassed or an unsafe shape is accepted. Keep the intended contract separate from the observed acceptance. |
| Unsupported shape | A valid, controlled example is explicitly refused or cannot execute as required. Do not generalize one failed spelling into absence of the capability. |
| Unverified correspondence | The reference analogy, implementation trace or consumer evidence is insufficient. Say what observation would settle it. |

Source tracing locates an implementation; `msc check` observes acceptance/refusal; emitted
code observes lowering; execution observes a particular runtime path. None substitutes for
the next level. C/JS output parity does not prove native retention, absence of races or
teardown safety. A sanitizer, counter or scheduler stress check answers only its own question.

Reuse evidence while its covered behavior, input and toolchain are unchanged. Record the
source tree, binary/support provenance, exact input/command, expected and actual output,
backend/host, and exclusions. Installed-compiler evidence is not a source-matched candidate
certificate. Run the smallest check that distinguishes the claim before expanding coverage.

## Bounded findings, not new features

The following checks used installed binary/support `56ad1fdf80f`, not a candidate built from
this worktree. Source inspection used tree `86631abd2642dd573ca4763ca099dfdeddc62b8e`.
They do not certify current `main`, all native layouts or all thread-crossing forms.

| Observation | Classification and limit |
|---|---|
| `734-vecPodStructAssign`: C, JS, Raiser and parity passed; four copy/detach assertions | Supports that POD Vec copy case, not arbitrary nested owner hooks. |
| `failedIndexInTryStops`: exit 1, `before` only; `bufferFieldOutsideThrowsRangeError`: nine caught errors, `untouched 0 0 0 0`; eight C/JS/Raiser/parity cells passed | Fatal indexing and catchable Buffer failures are different contracts, not universal bounds-error catchability. |
| `998-typeArgNamedLikeTheGenericModulesType`, `221-genericExtProtocol`, `686-macroBindsAPrivateHelper`: twelve C/JS/Raiser/parity cells passed | Definition scope, caller extensions and bound private helpers in those consumers; not every open-name/cache interaction. |
| Borrow-returning calls accepted writes/ref uses rejected for Borrow locals/parameters | Enforcement hole in the tested call-root shape; acceptance is not permission to write. See `borrowRoot` in `src/checker/assignable.ms`. |
| An unresolved generic constraint accepted arbitrary arguments | Enforcement hole, not support for operation-based concepts or arbitrary external constraints. |
| A bare no-argument macro identifier passed check but emitted an unexpanded C identifier; explicit `greeting()` emitted the string | Expansion hole in that form; no C link/run was claimed. Use an explicit call in examples. |

Two additional documentation probes ran with `msc run --target=c|js|raiser <probe.ms>` on
remote m1m (macOS arm64), sequentially under an eight-core admission. All **6/6 cells passed**
in 7.402 s using the same installed binary/support `56ad1fdf80f`:

- Result-returning async functions rejected through an awaited rejection and a synchronous
  throwing callee; returning an Err value fulfilled. Output: `rejected operand`,
  `rejected callee`, `error typed`.
- String/bytes: `AB ZB`, `2 65 66`, `3 3` after decoding, mutating the bytes, reading the string
  view and mutating an array alias. The complete byte probe is in LANG's bridge section.

Source SHA256s: `fe330cf54a96334ae7dd6a52b8634fb5bfce98c3b9456c8753c01a36cd9e089b`
(async paths), `cdf50fdab74a3cda398da1e19ce6815a2e184a9e207927f27c84093dcc53c941`
(byte bridge). Native binary SHA256 before/after was
`402c53e84ff11ec29516962e6083a2daad56c2ed6d06d3afebff496ad27e3d81`.
The first async probe omitted discriminant narrowing and failed checking; it was discarded,
not counted as evidence about rejection. These are documentation measurements, not new
registered regression tests, a source-matched compiler build or a sanitizer run.

The six existing runtime consumers above produced **24 pass, 0 fail, 0 xfail, 0 xpass** in
three targeted runs (21 s, 12 s, 16 s). Commands selected only those exact programs and
C/JS/Raiser cells, with `MSC` naming the installed compiler; no danger/SAN/full suite ran.
The selection/provenance record is the machine-local `paper/NIM-MAP.md` §§19–28. Those
research transcripts are not portable regression pins or an exhaustive safety audit.

## Missing, overlapping and removal candidates

| Finding | Author-visible use or loss; disposition |
|---|---|
| `Ptr`, `Handle`, `Borrow`, `Readonly`, `Cursor` look similar | They answer different address, retention, access and lifetime questions. No runtime redundancy is established by the naming overlap. |
| Read-only views versus mutable non-owning data views | Mutable AST/VM views cannot simply become read-only Borrow without losing writes. The safe representation/proof for every existing role is unresolved. |
| Stored non-owning back edges | Compiler graphs and arena/context links need an explicit lifetime/teardown proof. Proposed ownership/Unowned designs are not current guarantees; migration and mechanism approval remain separate. |
| Foreign operand writes versus hidden effects and result aliasing | Bindings need each relevant fact. Replacing them with one “trusted” or “pure” bit loses distinctions used at thread boundaries. No new default is chosen. |
| Structural constraints versus operation-based concepts | Structural shape does not require arbitrary operations to resolve. A missing concept mechanism needs a concrete consumer, not automatic porting from a reference manual. |
| Unsupported static/value generics and ordinary value-position type queries | Authors lose those compile-time forms. Checked refusal of const generics or `typeof local` is not evidence against namespace-import queries or runtime `typeof`. |
| Stale names and competing “complete specifications” | This is established documentation redundancy. Redirect obsolete documents to the owning contract instead of maintaining parallel rules. |

## Relayed array/byte target — not landed

On 2026-11-05, std-ms relayed an approved direction being built in phases. It is **not the
implementation measured above**; no typed-array/Buffer phase was verified by this audit.
Current recipes/measurements remain snapshot-bounded until their owner supplies a landed
implementation and real consumer evidence.

- Std algorithm inputs converge on borrowed `Span<T>`/`Readonly<Span<T>>`; byte inputs use
  `Readonly<Span<uint8>>`, with string where text is accepted. Owned byte outputs become Buffer.
- ArrayBuffer and TS-named typed arrays add owning shared views; `subarray` shares and `slice`
  copies. Target Buffer is a Uint8Array subclass with Node semantics, not a uint8[] brand or
  implicit uint8[] widening. The current brand/slice-copy observations are not that target.
- Vec and shared T[] both stay: copied growable value versus TS-required reference aliasing.
  Borrowed spans remain distinct from owning long-lived views.
- Payload stealing must preserve constructor-copy semantics: last-use of an aliased T[]
  variable alone is insufficient; sole payload ownership or an equivalent proof is required.
  Lazy buffer creation must preserve observable buffer identity/sharing.

These are target/ownership distinctions, not a new support claim, independent approval from
this session or a completed reference-mechanism audit. std-ms owns implementation; its
phase-4 measured probe will drive the later LANG/authoring rewrite.

No runtime construct is approved for removal by this inventory. A removal proposal must name
its real consumers, the replacement proof and what the author loses; a new mechanism needs
the applicable reference trace and the person's decision. Experimental reference features
without a consumer are gaps in correspondence, not a backlog mandate.
