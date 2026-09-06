// bug082 — a DU variant literal CAST to its variant type skipped the widening
//
// Symptom:    `createNodeAt(NodeKind.Identifier, { name: "x" } as IdentifierData, loc)`
//             corrupted memory (panic: misaligned `msStrPayload` / null
//             `msRefArray`), while the SAME literal without the cast was
//             correct. In assignment position it emitted C that does not
//             compile (`assigning to 'NodeData' from 'NodeData_v6'`).
// Root cause: codegen picks the temp's type from the expression's STATIC type
//             and only emits the tagged-union wrap (`_clit._tag = N;
//             _clit.vN = ...`) when that type is the Union. A TypeAssertion
//             pins the type to the VARIANT, and nothing inserted the
//             variant→union conversion, so a `NodeData_v6*` reached a formal
//             expecting `NodeData*` (clang only warns).
// Fix:        checker inserts HiddenStdConv(convType = union) when a variant
//             value meets a union formal — the conversion codegen already
//             knew how to emit (expressions.ms "Variant struct → discriminated
//             union"). Reference: sigmatch.nim implicitConv/nkHiddenSubConv.

import { NodeKind, IdentifierData, createNodeAt, makeLoc } from "std/meta";

test "bug082: variant cast widens at a call argument" {
	const loc = makeLoc(1, 1);
	const n = createNodeAt(NodeKind.Identifier, { name: "x" } as IdentifierData, loc);
	assert n.kind == NodeKind.Identifier;
	const d = n.data as IdentifierData;
	assert d.name == "x";
}

// Deliberately NOT covered here — two neighbouring gaps that would keep this
// file red for reasons that are not this bug (both probed 2026-08-05):
//   - a LOCAL declared with a cross-module DU union type (`const nd: NodeData
//     = ...`) emits `field has incomplete type 'NodeData'`, cast or not;
//   - `local as Variant` (bare as-cast narrowing off a union-typed local) is
//     unsupported — `.data as Variant`, used below, is the supported path.

test "bug082: the uncast literal still works" {
	const loc = makeLoc(2, 1);
	const n = createNodeAt(NodeKind.Identifier, { name: "z" }, loc);
	const d = n.data as IdentifierData;
	assert d.name == "z";
}
