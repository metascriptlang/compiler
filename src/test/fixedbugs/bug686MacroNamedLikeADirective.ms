// bug686 — a user macro named like a directive was not expanded
//
// Symptom:    `emit(made)` calling a user `macro emit` reached C codegen unexpanded ("MacroInvocation
//             reached C codegen unlowered"), or in statement position wrote `made` as raw C; JS
//             dropped it. The same for macros named `include`, `compile` and `link`.
// Root cause: every site asked whether the invocation's NAME was a builtin directive before asking
//             which symbol the call resolved to.
// Fix:        a call that resolved to a user macro expands it; only the `@name(...)` form is a
//             directive, and there the builtin wins over a same-named macro in scope.

import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

function program(name: string, use: string): string {
	return `
import { Node } from "std/meta";
macro ${name}(value: Node): Node { return value; }
function main(): void {
	const made: int32 = 4;
	${use}
}
main();
`;
}

test "bug686: a call to a macro named like a directive expands, in expression and statement position" {
	for (const name of ["emit", "include", "compile", "link"]) {
		const src = program(name, `const again = ${name}(made); ${name}(made); console.log(again);`);
		const c = compileToCWithStd(src);
		assert c.ok, name;
		if (c.ok) assert !c.value.contains("MacroInvocation"), name;
		const js = compileProjectToJSWithStd([{ entryPath: "test/main.ms", entrySource: src }], "test/main.ms");
		assert js.indexOf("ERROR", 0) < 0, js;
		assert !js.contains("unsupported"), name;
	}
}

test "bug686: the @emit directive stays the builtin beside a macro named emit" {
	const c = compileToCWithStd(program("emit", `@emit("/* bug686 marker */"); console.log(made);`));
	assert c.ok;
	if (c.ok) assert c.value.contains("/* bug686 marker */");
}
