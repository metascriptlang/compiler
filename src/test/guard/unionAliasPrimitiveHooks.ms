// nim-guard: a NAMED primitive union alias (`type SN = int32 | string`) gets its
//   lifecycle hooks generated, with a tag-guarded string decref in the body.
//
// INVARIANT: classify.ms names RC hooks for a named union by `typeName`
//   (`SNDestroy`/`SNCopy`/...), so destructorLifting MUST generate bodies for
//   exactly that set. Two predicates gated them out: `typeNeedsHooks` probed a
//   union's variants for FIELDS (primitives have none) and `isTaggedUnion`
//   required a variant that peels to a Struct — both false for `int32 | string`,
//   which codegen nevertheless emits as `struct SN { _tag; union { int32 v0;
//   msString v1; } }`. Nothing reached `ensureHooks` for it either: the scan
//   walk had arms for Struct/Ref/GenericInstance/Array/Tuple but not Union.
// NIM-REF: §1 "Named primitive-union hooks" — DIVERGE-INCOMPLETE -> SAME
//   (Nim lifts hooks per case-object branch; a scalar branch is a branch).
//
// WHAT IT CATCHES: RED = link failure `undefined symbol: _SNDestroy` (proven on
//   the pre-fix binary for all three shapes below: local from a call, struct
//   field, call argument). A silently EMPTY hook body would still link — the
//   body shape is pinned by the emitted-C check in the task notes, not here.

type SN = int32 | string;

interface Box { v: SN; }

function pick(p: boolean): SN {
	if (p) return "guard-union-string";
	return 7;
}

function useSN(x: SN): int32 { return 1; }

function main(): void {
	let i = 0;
	let acc = 0;
	while (i < 500) {
		const a = pick(i % 2 == 0);
		const box: Box = { v: pick(true) };
		acc = acc + useSN(a) + useSN(box.v);
		i = i + 1;
	}
	if (acc != 1000) { throw "GUARD RED: union alias values did not round-trip"; }
	console.log("unionAliasPrimitiveHooks ok");
}
main();
