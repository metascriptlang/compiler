// bug027 — Raiser comparison codegen mis-tagged result as Int instead of Bool
//
// Symptom: comparison expressions in macro VM (===, !==, <, >, <=, >=, !)
//          produced RaiserValue with kind=Int (not Bool). MS-level semantics
//          say `a === b` returns boolean, so the kind tag was wrong.
//
// Practical impact: most consumers (BneI64 dispatch, lenient readBool/readInt)
//          tolerated either kind, so the bug was latent. Macros returning a
//          comparison result via valueToNode would emit NumberLiteral(0/1)
//          instead of BooleanLiteral(false/true), giving wrong AST type.
//
// Root cause: src/codegen/raiser/expressions.ms emitted raiserInt(0/1) at 4
//          sites — string EqStr/NeStr (lines 303,305,312,314), numeric
//          comparison (331,337), unary `!` (376,378). Fix: emit raiserBool.
//
// Verification: literal-only comparisons get constant-folded to BoolLit by
//          src/transform/coercion/constantFolding.ms — so probes must use
//          variables to bypass folding and exercise the codegen path.

import { evalSourceFull } from "../../codegen/raiser/eval";
import { RaiserValueKind } from "../../raiser/value";

test "bug027: numeric === produces Bool kind" {
	const r = evalSourceFull("const a = 1; const b = 1; return a === b;");
	assert r.lastResult.kind == RaiserValueKind.Bool;
	assert r.lastResult.intVal == 1;
}

test "bug027: numeric !== produces Bool kind" {
	const r = evalSourceFull("const a = 1; const b = 2; return a !== b;");
	assert r.lastResult.kind == RaiserValueKind.Bool;
	assert r.lastResult.intVal == 1;
}

test "bug027: relational > produces Bool kind" {
	const r = evalSourceFull("const a = 3; const b = 2; return a > b;");
	assert r.lastResult.kind == RaiserValueKind.Bool;
	assert r.lastResult.intVal == 1;
}

test "bug027: string === produces Bool kind" {
	const r = evalSourceFull("const s = \"a\"; const t = \"a\"; return s === t;");
	assert r.lastResult.kind == RaiserValueKind.Bool;
	assert r.lastResult.intVal == 1;
}

test "bug027: string !== produces Bool kind" {
	const r = evalSourceFull("const s = \"a\"; const t = \"b\"; return s !== t;");
	assert r.lastResult.kind == RaiserValueKind.Bool;
	assert r.lastResult.intVal == 1;
}

test "bug027: unary ! produces Bool kind" {
	const r = evalSourceFull("const a = 1; return !(a === 1);");
	assert r.lastResult.kind == RaiserValueKind.Bool;
	assert r.lastResult.intVal == 0;
}
