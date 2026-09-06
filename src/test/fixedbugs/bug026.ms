// bug026 — Two latent compiler bugs in Raiser path: bool field readback +
//          string MemberExpr/ArrayAccess === comparison
//
// Bug A: src/compiler/meta/bridge.ms readBool only accepted Bool kind, not
//        Int 0/1. Comparison codegen emits raiserInt(0/1) for boolean
//        results, so BooleanLiteral fields stored from comparisons silently
//        defaulted to false. readBool now accepts both — aligns with
//        unboxBool (raiser/marshal.ms) and readInt (this file).
//
// Bug C: src/codegen/raiser/expressions.ms exprIsString didn't recognize
//        MemberExpr / ArrayAccess as potentially string. Codegen fell to
//        BeqI64 (numeric) instead of EqStr → wrong heap-handle comparison.
//        Fix: fallback checking node.nodeType.kind === String/StringLiteral.
//
// Discovered: SERIALIZE V3 phase B-1 (JSON encode Union branch) emit needed
//             string === comparisons between bridge field reads. Both bugs
//             surfaced as "wrong-but-no-error" output (Result encoded as
//             {"ok":true} only, missing payload field).

interface Pair { name: string; role: string; }
type FlagDU = { ok: true, val: int32 } | { ok: false, msg: string };

test "bug026: string MemberExpr === MemberExpr (Bug C)" {
	const u: Pair = { name: "alice", role: "admin" };
	const v: Pair = { name: "bob", role: "admin" };
	// Without Bug C fix, both comparisons would dispatch to numeric BeqI64
	// and return wrong (heap handles compare equal/random) instead of EqStr.
	assert (u.name == v.name) == false;
	assert (u.role == v.role) == true;
	assert (u.name == u.name) == true;
}

test "bug026: Result.ok narrowing through if (regression check)" {
	const r: Result<int32, string> = Result.ok(42 as int32);
	if (r.ok) {
		assert r.value == 42;
	} else {
		assert false;  // unreachable
	}
}

test "bug026: Result.err narrowing through if" {
	const r: Result<int32, string> = Result.err("oops");
	if (r.ok) {
		assert false;  // unreachable
	} else {
		assert r.error == "oops";
	}
}

interface Container { fields: string[]; primary: string; }

test "bug026: string ArrayAccess === MemberExpr" {
	const c: Container = { fields: ["a", "b", "c"], primary: "b" };
	// Both ArrayAccess and MemberExpr returning string — comparison must
	// use EqStr not BeqI64. Without Bug C fix, fields[i] === primary
	// would dispatch to numeric and give wrong result.
	assert (c.fields[0] == c.primary) == false;
	assert (c.fields[1] == c.primary) == true;
	assert (c.fields[2] == c.primary) == false;
}

test "bug026: ArrayAccess === ArrayAccess across two arrays" {
	const a: string[] = ["x", "y", "z"];
	const b: string[] = ["x", "Y", "z"];
	assert (a[0] == b[0]) == true;
	assert (a[1] == b[1]) == false;
	assert (a[2] == b[2]) == true;
}
