import { compileToC } from "../helpers";

const decls = "struct Click { x: int32 }\nstruct Key { code: int32 }\ntype Ev = Click | Key;\n";

test "declaredUnionIntoAnonymousCarrier: a declared union local passed to an anonymous union parameter converts into the parameter's carrier" {
	const r = compileToC(decls + "function f(v: Click | Key): int32 { return 1; }\nfunction g(e: Ev): int32 { return f(e); }\n");
	assert r.ok, "compileToC failed";
	assert r.value.contains("msUnionConv"), r.value;
}

test "declaredUnionIntoAnonymousCarrier: a declared union argument converts into a type parameter an anonymous union bound first" {
	const r = compileToC(decls + "function put<T>(arr: T[], v: T): void { arr.push(v); }\nfunction g(e: Ev, arr: (Click | Key)[]): void { put(arr, e); }\n");
	assert r.ok, "compileToC failed";
	assert r.value.contains("msUnionConv"), r.value;
}

test "declaredUnionIntoAnonymousCarrier: a declared union read into the same declared union converts nothing" {
	const r = compileToC(decls + "function f(v: Ev): int32 { return 1; }\nfunction g(e: Ev): int32 { return f(e); }\n");
	assert r.ok, "compileToC failed";
	assert !r.value.contains("msUnionConv"), r.value;
}
