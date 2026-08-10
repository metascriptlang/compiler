// nim-guard: a synthesized call argument carries the CALLEE's declared type
//
// INVARIANT (Nim): an argument the compiler inserts is fitted to the FORMAL
//   parameter's type — `implicitConv`/`fitNode` build the conversion from
//   `f` (the formal) in `sigmatch.nim:2179`, never from a type the inserting
//   pass invented. Ownership and representation follow from that type, so a
//   planted argument is passed and destroyed exactly like a written one.
// NIM-REF: §1 "Phase at which an implicit stringify call is inserted" — same
//   family: a lowering that synthesizes a call must speak the callee's types.
//
// WHAT IT CATCHES: `console.log(structInstance)` lowers to
//   `stringify(jsonObject(keys, values))` (transform/native/debugLower.ms). The
//   pass used to hand-build both argument types: `values` as a raw-pointer array
//   (so JsonValue's reference semantics were lost and stringify read garbage —
//   `panic: member access within misaligned address … JsonValueData`) and `keys`
//   as a BARE array (so it was passed as `&stackTemp` into a `Ref<Array>` param
//   and then destroyed twice — once by the object's destroy, once by scope
//   cleanup). Nested struct fields hit a third face of it: the synthesized
//   MemberExpr carried no type at all, so codegen emitted `.` for a `Ref` field
//   and clang refused. Types now come from the resolved `jsonObject` signature.
//
// RED MEANS: a debug-dump argument stopped carrying the callee's type. This
//   probe panics at exit, fails to BUILD, or reports an unbalanced type below.
//   Run /trace-nim on debugLower.ms.
//
// GUARD-BALANCE JsonValueData
// GUARD-BALANCE Leaf
// GUARD-BALANCE Branch
// GUARD-BALANCE Plain
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

class Leaf {
	n: number;
	constructor(a: number) { this.n = a; }
}

class Branch {
	id: number;
	tag: string;
	kid: Leaf;
	ok: boolean;
	constructor(a: number, b: string, c: Leaf) { this.id = a; this.tag = b; this.kid = c; this.ok = true; }
}

interface Plain { x: number; y: string; }

function main(): void {
	// Flat class: the shape that used to read garbage out of the values array.
	console.log(new Leaf(1));

	// Nested Ref field + a string field: the `&stackTemp` double-destroy and the
	// `.`-vs-`->` emission both live here.
	console.log(new Branch(2, "t", new Leaf(3)));

	// Interface-typed record and an anonymous object literal.
	const p: Plain = { x: 4, y: "z" };
	console.log(p);
	console.log({ a: 1, b: "anon" });

	// The same builder feeds a struct's string form.
	const s = `${new Leaf(5)}`;
	if (s !== "{\"n\":5}") { throw "GUARD RED: struct string form = " + s; }

	// Repeated dumps in one scope — each temp must be destroyed exactly once.
	let i = 0;
	while (i < 3) {
		console.log(new Leaf(i));
		i = i + 1;
	}

	console.log("debugDumpOwnership ok");
}

main();
