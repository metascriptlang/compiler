import { compileToC } from "../helpers";

const decls = "type Align = \"auto\" | \"center\" | \"stretch\";\nfunction pa(k: int32): Align | null { if (k == 1) return \"center\"; return null; }\nfunction pick(k: int32): Align { return k == 1 ? \"stretch\" : \"auto\"; }\n";

test "literalUnionBranchJoin: a literal union and another string join to a string" {
	const r = compileToC(decls + "function f(): string { const a = pa(1); const q = a ?? \"N\"; const c = a != null ? a : \"N\"; return q + c; }\n");
	assert r.ok, r.ok ? "" : r.error;
	assert !r.value.contains("<object>"), r.value;
	assert !r.value.contains("msUnion_"), r.value;
}

test "literalUnionBranchJoin: the same literal union on both branches stays that union" {
	const r = compileToC(decls + "function f(k: int32): Align { const s = k == 1 ? pick(1) : pick(2); const keep: Align = s; return keep; }\n");
	assert r.ok, r.ok ? "" : r.error;
}
