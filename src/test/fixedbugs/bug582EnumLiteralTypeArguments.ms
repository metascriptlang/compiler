// bug582 — an enum member literal type lost its member through generics
//
// Symptom:    `const x: K.A = id(K.A)` was refused (`Type 'K' is not assignable to type 'K.A'`);
//             `Pair<K.A>` went into `Pair<K>` and broke the C build while JS ran it; `Box<K.A>`
//             and `Box<K.B>` shared one instance.
// Root cause: an enum member argument bound `T` before the destination could, a literal type
//             argument compared with its base as the same element, and the instance key of an
//             enum member type left the member out.
// Fix:        an enum member is a literal the destination shapes, as a number literal is; a
//             literal type argument must be the same type (the reference relates instance
//             arguments without covariance); the instance key carries the member.

import { compileToC, compileToJS } from "../helpers";

const header = `
enum K { A, B }
enum L { X, Y, Z }
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
struct Pair<T> { a: T; b: T; }
type Cell<T> = { v: T };
function id<T>(x: T): T { return x; }
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	const js = compileToJS(header + body);
	if (c.ok || js.ok) return "";
	return c.error;
}

function compiles(body: string): boolean {
	return compileToC(header + body).ok && compileToJS(header + body).ok;
}

function boxInstances(c: string): string[] {
	const names: string[] = [];
	let at = c.indexOf("struct Box_", 0);
	while (at >= 0) {
		const end = c.indexOf(" ", at + 7);
		const name = c.slice(at + 7, end);
		if (c.slice(end, end + 2) == " {" && names.indexOf(name) < 0) names.push(name);
		at = c.indexOf("struct Box_", at + 1);
	}
	return names;
}

test "bug582: an enum member argument takes a member destination" {
	assert compiles("const x: K.A = id(K.A);\nconst z: L.Z = id(L.Z);\nconst k = id(K.B);\nconsole.log(x == K.A, z == L.Z, k == K.B);\n");
}

test "bug582: an enum member argument still refuses another member's destination" {
	assert errorOf("const y: K.A = id(K.B);\n").contains("not assignable");
}

test "bug582: a literal type argument does not widen to its base" {
	assert errorOf("const p: Pair<K.A> = { a: K.A, b: K.A };\nconst q: Pair<K> = p;\n").contains("not assignable");
	assert errorOf("const b = new Box<K.A>(K.A);\nconst c: Box<K> = b;\n").contains("not assignable");
	assert errorOf("const c: Cell<\"x\"> = { v: \"x\" };\nconst d: Cell<string> = c;\n").contains("not assignable");
}

test "bug582: two members of one enum give two instances" {
	const c = compileToC(header + "const a = new Box<K.A>(K.A);\nconst b = new Box<K.B>(K.B);\nconsole.log(a.v == K.A, b.v == K.B);\n");
	assert c.ok;
	assert boxInstances(c.value).length == 2;
}
