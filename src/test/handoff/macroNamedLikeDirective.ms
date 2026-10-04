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

test "macroNamedLikeDirective: a call to a macro named like a directive expands, in expression and statement position" {
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

test "macroNamedLikeDirective: the @emit directive stays the builtin beside a macro named emit" {
	const c = compileToCWithStd(program("emit", `@emit("/* bug686 marker */"); console.log(made);`));
	assert c.ok;
	if (c.ok) assert c.value.contains("/* bug686 marker */");
}
