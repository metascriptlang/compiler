// E2E C: a for-of over Iterator.zip of array iterators is one loop on one counter, with no zip generator and no
// pair array per step; runtime results across grow, shrink, jumps and effects: corpus iteratorZipLockstep.

import { builtModuleC } from "../helpers";

function builtC(name: string, body: string): string {
	const source = `function f(a: int32[], b: int32[]): int32 {\n\tlet s: int32 = 0;\n\t${body}\n\treturn s;\n}\nconsole.log(f([1, 2, 3], [4, 5, 6, 7]));\n`;
	return builtModuleC("zipLockstepEmit", name, source, ["--danger"]);
}

function routineOf(c: string, name: string): string {
	for (const line of c.split("\n")) {
		if (line.includes(` ${name}__`) && line.endsWith(") {")) {
			const at = c.indexOf(line + "\n");
			const end = c.indexOf("\n}\n", at);
			return c.slice(at, end < 0 ? c.length : end);
		}
	}
	return "error: no definition of " + name;
}

test "zip lockstep: a destructured pair reads both arrays in one loop" {
	const c = builtC("destructured", "for (const [x, y] of Iterator.zip([a.values(), b.values()])) s += x * y;");
	assert !c.startsWith("error:"), c.slice(0, 400);
	const f = routineOf(c, "f");
	assert !f.includes("Iterator__"), "an iterator was still built";
	assert f.split("while (1)").length == 2, "expected one loop";
}

test "zip lockstep: a pair read only as pair[0] and pair[1] builds no array per step" {
	const c = builtC("indexed", "for (const pair of Iterator.zip([a.values(), b.values()])) s += pair[0] * pair[1];");
	assert !c.startsWith("error:"), c.slice(0, 400);
	const f = routineOf(c, "f");
	assert !f.includes("Iterator__"), "the zip generator was still called";
	assert !f.includes("msArrayPayloadNew"), "a pair array was built per step";
}

test "zip lockstep: a pair kept past its step is built fresh each step" {
	const c = builtC("kept", "const kept: int32[][] = []; for (const pair of Iterator.zip([a.values(), b.values()])) kept.push(pair); s = kept.length as int32;");
	assert !c.startsWith("error:"), c.slice(0, 400);
	const f = routineOf(c, "f");
	assert !f.includes("Iterator__"), "the zip generator was still called";
	assert f.includes("msArrayPayloadNew"), "the kept pair was not built";
}

test "zip lockstep: a source whose value calls a function keeps the zip generator" {
	const c = builtC("effect", "for (const [x, y] of Iterator.zip([a.values().map((v) => v + 1), b.values()])) s += x * y;");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert routineOf(c, "f").includes("Iterator__"), "a source with a callback was stepped out of order";
}
