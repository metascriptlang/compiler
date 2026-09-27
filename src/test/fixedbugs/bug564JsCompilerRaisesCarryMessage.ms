// bug564 — a raise the compiler inserts reached JS without its message
//
// Symptom:    on JS, `catch (e) { e.message }` around a for-of whose array changed length printed
//             `undefined` (C printed the message), and a read of the wrong variant of an enum-discriminated
//             union reported `kind = 0` where C reported `kind = Num`.
// Root cause: the for-of lowering throws a string after the checker has boxed every user throw into an
//             Error, and the JS emitter wrote the string as is; the JS variant check passed the raw
//             discriminant value to msFieldError instead of the member's name.
// Fix:        the JS emitter throws a string as `new Error(...)`, as the C emitter calls msThrow; the JS
//             variant check names the member through the enum's toString.

import { compileToJS } from "../helpers";

test "bug564: the for-of length check throws an Error on JS" {
	const js = compileToJS("const xs: string[] = [\"a\", \"b\"];\nfor (const x of xs) { xs.pop(); }\n");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("throw new Error(\"the length of the array changed while iterating over it\")"), js.value;
}

test "bug564: the string for-of length check throws an Error on JS" {
	const js = compileToJS("let s = \"ab\";\nfor (const c of s) { s = s + \"c\"; }\n");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("throw new Error(\"the length of the string changed while iterating over it\")"), js.value;
}

test "bug564: the JS variant check names the discriminant member" {
	const js = compileToJS("enum K { Num, Str }\ntype D = match (kind: K) {\n\tK.Num => { value: float64 },\n\tK.Str => { text: string },\n};\n"
		+ "class Box { d: D = { kind: K.Str, text: \"hello\" }; }\nfunction setNum(x: Box): void { x.d = { kind: K.Num, value: 1.5 }; }\n"
		+ "function run(b: Box): string { if (b.d.kind == K.Str) { setNum(b); return b.d.text; } return \"\"; }\n");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("using 'kind = \", K_toString"), js.value;
}
