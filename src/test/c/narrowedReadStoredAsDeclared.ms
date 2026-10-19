import { compileToC } from "../helpers";

const decls = "type Shape = { kind: \"a\", r: string } | { kind: \"b\", w: string } | { kind: \"c\", z: string };\nfunction id<T>(x: T): T { return x; }\n";

test "narrowedReadStoredAsDeclared: a residual union read bound to a generic parameter is converted from the declared layout" {
	const r = compileToC(decls + "function f(s: Shape): boolean { if (s.kind != \"a\") { const u = id(s); return u.kind == \"b\"; } return false; }\n");
	assert r.ok, "compileToC failed";
	assert r.value.contains("msUnionConv_"), r.value;
}

test "narrowedReadStoredAsDeclared: a residual union read stored in an array literal is converted from the declared layout" {
	const r = compileToC(decls + "function f(s: Shape): int32 { if (s.kind != \"a\") { const list = [s]; return list.length; } return 0; }\n");
	assert r.ok, "compileToC failed";
	assert r.value.contains("msUnionConv_"), r.value;
}

test "narrowedReadStoredAsDeclared: a residual union read stored in an anonymous object field is converted from the declared layout" {
	const r = compileToC(decls + "function f(s: Shape): boolean { if (s.kind != \"a\") { const o = { held: s }; return o.held.kind == \"b\"; } return false; }\n");
	assert r.ok, "compileToC failed";
	assert r.value.contains("msUnionConv_"), r.value;
}
