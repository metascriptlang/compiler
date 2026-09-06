// bug094 — object spread in object literal kept the raw "..." key to C codegen
//
// Symptom:    `{ ...base, height: 20.0 }` checked clean but C failed:
//             `no member named 'dotdotdot_' in 'struct Style'` — the spread
//             entry was emitted as an assignment to a struct field literally
//             named `...`. Blocked neon style S3 (runtime style merge).
// Root cause: no pass ever lowered object-literal spread. The parser stores
//             the entry as key "..." + SpreadExpr, the checker special-cases
//             the key (skips excess/dup checks by design), and C codegen
//             mangled it into a field name.
// Fix:        transform/desugar/objectSpreadLower.ms — post-check pass that
//             expands spread entries into explicit `f: base.f` member reads
//             (analyzer sees real reads → DRC copies), hoisting
//             non-identifier operands into peer temps (evalOnce). Runs on
//             both backends before objectLiteralComplete so the JS zero-fill
//             cannot clobber spread-provided fields.
//
// Semantics (MS, diverges from TS knowingly): spread copies every field of
// the operand's STATIC type — structs carry no "absent property" state
// (Nim default-init), so an omitted nullable field spreads as null.

interface Bug094Style { width: number | null; height: number | null; }
interface Bug094Pt { x: number; y: number; label: string; }

let bug094Calls = 0;

function bug094Mk(): Bug094Pt {
	bug094Calls = bug094Calls + 1;
	return { x: 1, y: 2, label: "mk" };
}

function bug094Dist(p: Bug094Pt): number {
	return p.x + p.y;
}

test "bug094: spread + explicit override" {
	const base: Bug094Style = { width: 10.0 };
	const merged: Bug094Style = { ...base, height: 20.0 };
	assert merged.width == 10.0;
	assert merged.height == 20.0;
	assert base.height == null;
}

test "bug094: spread alone copies every field" {
	const p: Bug094Pt = { x: 3, y: 4, label: "src" };
	const q: Bug094Pt = { ...p };
	assert q.x == 3;
	assert q.y == 4;
	assert q.label == "src";
}

test "bug094: later spread wins field-wise (static-type semantics)" {
	const a: Bug094Style = { width: 1.0, height: 2.0 };
	const b: Bug094Style = { height: 9.0 };
	const m: Bug094Style = { ...a, ...b };
	assert m.width == null;
	assert m.height == 9.0;
}

test "bug094: explicit key before spread is overridden" {
	const p: Bug094Pt = { x: 5, y: 6, label: "base" };
	const m: Bug094Pt = { label: "pre", ...p };
	assert m.label == "base";
	assert m.x == 5;
}

test "bug094: call operand is hoisted and evaluated once" {
	bug094Calls = 0;
	const m: Bug094Pt = { ...bug094Mk(), y: 7 };
	assert bug094Calls == 1;
	assert m.x == 1;
	assert m.y == 7;
	assert m.label == "mk";
}

test "bug094: spread literal in argument position" {
	const p: Bug094Pt = { x: 3, y: 4, label: "p" };
	assert bug094Dist({ ...p, y: 10 }) == 13;
}

test "bug094: string field survives the copy after source mutation" {
	let p: Bug094Pt = { x: 1, y: 2, label: "first" };
	const q: Bug094Pt = { ...p };
	p.label = "second";
	assert q.label == "first";
	assert p.label == "second";
}
