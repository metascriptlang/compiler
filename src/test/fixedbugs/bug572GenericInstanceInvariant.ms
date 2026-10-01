// bug572 — any instance of a generic was assignable to any other instance
//
// Symptom:    `const b: Box<string> = boxOfInt32` compiled and crashed reading the string;
//             `Box<number>` read the int32 as a double (3.5e-323); `Box<int32>` even went into
//             `Other<string>` at a declaration or an assignment.
// Root cause: isAssignable's Ref arm accepted two instances by their shared base name before
//             comparing type arguments, and compared them covariantly; fitNode rejected no
//             same-kind pair that isAssignable refused.
// Fix:        instance arguments compare invariantly through sameElement (reference typeRel,
//             trNoCovariance), and fitNode refuses a same-kind pair isAssignable refuses.

import { compileToC } from "../helpers";

const header = `
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Other<T> { v: T; constructor(v: T) { this.v = v; } }
interface Cell<T> { v: T; }
struct Pair<T> { a: T; b: T; }
const a = new Box<int32>(7);
const c: Cell<int32> = { v: 1 };
const p: Pair<int32> = { a: 1, b: 2 };
`;

function errorOf(body: string): string {
	const r = compileToC(header + body);
	return r.ok ? "" : r.error;
}

test "bug572: a declaration refuses another type argument" {
	assert errorOf("const b: Box<string> = a;").contains("'Box<int32>' is not assignable to type 'Box<string>'");
}

test "bug572: a declaration refuses a wider numeric type argument" {
	assert errorOf("const b: Box<number> = a;").contains("is not assignable");
}

test "bug572: a declaration refuses another generic" {
	assert errorOf("const o: Other<string> = a;").contains("is not assignable");
	assert errorOf("struct Twin<T> { a: T; b: T; }\nconst w: Twin<int32> = p;").contains("is not assignable");
}

test "bug572: another generic class of the same shape fits, as two classes do" {
	assert errorOf("const o: Other<int32> = a;") == "";
}

test "bug572: an assignment refuses another type argument" {
	assert errorOf("let b = new Box<string>(\"s\"); b = a;").contains("is not assignable");
}

test "bug572: an argument refuses another type argument" {
	assert errorOf("function t(x: Box<string>): void {} t(a);").contains("got Box<int32>, expected Box<string>");
}

test "bug572: a return refuses another type argument, once" {
	const e = errorOf("function f(): Box<string> { return a; }");
	assert e.contains("is not assignable");
	assert !e.contains("Return type mismatch");
}

test "bug572: an interface instance refuses another type argument" {
	assert errorOf("const e: Cell<string> = c;").contains("is not assignable");
}

test "bug572: a struct instance refuses another type argument" {
	assert errorOf("function t(x: Pair<string>): void {} t(p);").contains("got Pair<int32>, expected Pair<string>");
}

test "bug572: a nested instance refuses another inner type argument" {
	assert errorOf("const bb = new Box<Box<int32>>(a); const cc: Box<Box<string>> = bb;").contains("is not assignable");
}

test "bug572: the same instance stays assignable" {
	assert errorOf("const b: Box<int32> = a; const d: Cell<int32> = c; function t(x: Pair<int32>): void {} t(p);") == "";
}
