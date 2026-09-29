// bug583 — a generic overload winner took its type parameters from the call's destination
//
// Symptom:    with `pick<T>(a: T, b: T)` overloaded by `pick(a: string)`, `pick(power, 1) as int64`
//             called an undeclared `pick…_u0` (clang error, JS ReferenceError) and
//             `console.log(pick(power, power))` was refused with "expected ...unknown[]".
// Root cause: the overload path bound the winner's parameters from the destination before its
//             arguments, then handed the already-concrete signature to instantiation, which found
//             nothing left to bind and left the call on the generic declaration.
// Fix:        the winner binds from explicit type arguments, then its arguments, then the
//             destination for what is still unbound, as a non-overloaded call does; instantiation
//             starts from the signature with only the explicit type arguments applied.

import { compileToC, compileToJS } from "../helpers";

const header = `
function pick<T>(a: T, b: T): T { return a; }
function pick(a: string): string { return a; }
const power: int32 = 7;
`;

function compiles(body: string): boolean {
	return compileToC(header + body).ok && compileToJS(header + body).ok;
}

test "bug583: a generic overload winner inside console.log binds from its arguments" {
	assert compiles("console.log(pick(power, power), pick(\"s\"));\n");
	assert compiles("console.log(pick(power, 1), pick(\"s\"));\n");
}

function everyPickCallIsDefined(js: string): boolean {
	let at = js.indexOf("pick", 0);
	while (at >= 0) {
		const end = js.indexOf("(", at);
		const name = js.slice(at, end);
		const isDefinition = at >= 9 && js.slice(at - 9, at) == "function ";
		if (!isDefinition && !js.contains("function " + name + "(")) return false;
		at = js.indexOf("pick", end);
	}
	return true;
}

test "bug583: a generic overload winner is instantiated under a destination" {
	assert compileToC(header + "const d: int64 = pick(power, 1);\nconsole.log(d);\n").ok;
	const js = compileToJS(header + "const d = pick(power, 1) as int64;\nconst e: int64 = pick(power, 1);\nconsole.log(d, e);\n");
	assert js.ok;
	assert everyPickCallIsDefined(js.value);
}
