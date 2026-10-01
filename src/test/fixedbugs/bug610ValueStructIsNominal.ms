// Symptom: `const p: P = a` with `a` a declared struct of P's fields (or a type-literal, interface or class value) passed the checker; C failed at clang (`assigning to 'P' from incompatible type 'A'`) while JS ran it.
// Root cause: isObjectAssignable related a declared value struct by field prefix, a relation only a reference type's raw pointer cast backs.
// Fix: a declared value struct accepts its own type, an object literal it adopts and a struct that extends it (converted to the parent part), as the reference's objects relate by identity or inheritance (types.nim sameObjectTypes, sigmatch.nim isObjectSubtype) and not by shape.
import { compileToCWithStd } from "../helpers";

function error610(body: string): string {
	const result = compileToCWithStd(`
struct A610 { code: int32; }
struct Wide610 { code: int32; extra: int32; }
struct P610 { code: int32; }
struct H610 { p: P610; }
type Lit610 = { code: int32; };
interface I610 { code: int32; }
interface J610 { code: int32; }
class C610 { code: int32 = 7; }
class D610 { code: int32 = 0; }
struct Kid610 extends P610 { extra: int32; }
function show610(p: P610): int32 { return p.code; }
${body}
`);
	return result.ok ? "" : result.error;
}

test "bug610: a struct of the same fields is not the struct" {
	const error = error610("const a: A610 = { code: 7 }; const p: P610 = a;");
	assert error.indexOf("Type 'A610' is not assignable to type 'P610'", 0) >= 0, error;
}

test "bug610: a struct whose fields start with the struct's is not the struct" {
	const error = error610("const w: Wide610 = { code: 7, extra: 1 }; const p: P610 = w;");
	assert error.indexOf("Type 'Wide610' is not assignable to type 'P610'", 0) >= 0, error;
}

test "bug610: a type-literal, interface or class value is not a struct" {
	const lit = error610("const l: Lit610 = { code: 7 }; const p: P610 = l;");
	assert lit.indexOf("is not assignable to type 'P610'", 0) >= 0, lit;
	const iface = error610("const i: I610 = { code: 7 }; const p: P610 = i;");
	assert iface.indexOf("Type 'I610' is not assignable to type 'P610'", 0) >= 0, iface;
	const cls = error610("const c = new C610(); const p: P610 = c;");
	assert cls.indexOf("Type 'C610' is not assignable to type 'P610'", 0) >= 0, cls;
}

test "bug610: every slot of the struct type refuses another struct" {
	const arg = error610("const a: A610 = { code: 7 }; show610(a);");
	assert arg.indexOf("Argument type mismatch in 'show610' arg 0: got A610, expected P610", 0) >= 0, arg;
	const ret = error610("function f610(a: A610): P610 { return a; }");
	assert ret.indexOf("Type 'A610' is not assignable to type 'P610'", 0) >= 0, ret;
	const field = error610("const a: A610 = { code: 7 }; const h: H610 = { p: a };");
	assert field.indexOf("Type 'A610' is not assignable to type 'P610'", 0) >= 0, field;
	const elem = error610("const a: A610 = { code: 7 }; const ps: P610[] = [a];");
	assert elem.indexOf("Type 'A610' is not assignable to type 'P610'", 0) >= 0, elem;
	const nullable = error610("const a: A610 = { code: 7 }; const p: P610 | null = a;");
	assert nullable.indexOf("Type 'A610' is not assignable to type 'P610 | null'", 0) >= 0, nullable;
	const reassign = error610("const a: A610 = { code: 7 }; let p: P610 = { code: 1 }; p = a;");
	assert reassign.indexOf("Type 'A610' is not assignable to type 'P610'", 0) >= 0, reassign;
}

test "bug610: a struct reaches its declared parent, never the other way" {
	assert error610("const k: Kid610 = { code: 7, extra: 1 }; const p: P610 = k; show610(k);") == "";
	const down = error610("const p: P610 = { code: 7 }; const k: Kid610 = p;");
	assert down.indexOf("Type 'P610' is not assignable to type 'Kid610'", 0) >= 0, down;
}

test "bug610: the struct itself, its literals and reference types still relate" {
	assert error610("const p: P610 = { code: 7 }; const q: P610 = p; show610(q);") == "";
	assert error610("const lit = { code: 7 }; const p: P610 = lit; show610({ code: 8 });") == "";
	assert error610("const i: I610 = { code: 7 }; const j: J610 = i;") == "";
	assert error610("const c = new C610(); const d: D610 = c;") == "";
}
