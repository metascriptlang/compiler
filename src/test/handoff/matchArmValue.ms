import { compileToC, compileToJS, refusedOnEveryBackend } from "../helpers";

const REFUSED_RETURN = "would leave the function, not give this match arm its value";
const NO_VALUE = "ends without a value";
const NO_ELSE = "has an 'if' without 'else'";

test "matchArmValue: a return with a value inside a bound match arm is refused" {
	const terminal = refusedOnEveryBackend("function f(v: int32): int32 {\n\tconst r = match (v) {\n\t\t0 => { const n = 1; return n; },\n\t\t_ => 2,\n\t};\n\treturn r;\n}\nconsole.log(`${f(0)}`);", REFUSED_RETURN);
	assert terminal == "", terminal;
	const nested = refusedOnEveryBackend("function f(v: int32): string {\n\tconst r: int32 = match (v) {\n\t\t0 => { if (v == 0) return 1; 3 },\n\t\t_ => 2,\n\t};\n\treturn `${r}`;\n}\nconsole.log(f(0));", REFUSED_RETURN);
	assert nested == "", nested;
	const argument = refusedOnEveryBackend("function g(n: int32): int32 { return n; }\nfunction f(v: int32): int32 {\n\treturn g(match (v) {\n\t\t0 => { return 1; },\n\t\t_ => 2,\n\t});\n}\nconsole.log(`${f(0)}`);", REFUSED_RETURN);
	assert argument == "", argument;
}

test "matchArmValue: an arm used as a value must end in a value on every path" {
	const loop = refusedOnEveryBackend("function f(v: int32): int32 {\n\tconst r: int32 = match (v) {\n\t\t0 => { for (let i: int32 = 0; i < 2; i++) {} },\n\t\t_ => 2,\n\t};\n\treturn r;\n}\nconsole.log(`${f(0)}`);", NO_VALUE);
	assert loop == "", loop;
	const empty = refusedOnEveryBackend("function f(v: int32): int32 {\n\tconst r: int32 = match (v) {\n\t\t0 => {},\n\t\t_ => 2,\n\t};\n\treturn r;\n}\nconsole.log(`${f(0)}`);", NO_VALUE);
	assert empty == "", empty;
	const noElse = refusedOnEveryBackend("function f(v: int32): int32 {\n\tconst r: int32 = match (v) {\n\t\t0 => { if (v > 0) { 1 } },\n\t\t_ => 2,\n\t};\n\treturn r;\n}\nconsole.log(`${f(0)}`);", NO_ELSE);
	assert noElse == "", noElse;
}

test "matchArmValue: return leaves the function from a returned match, an arrow body and a bare return" {
	const sources = [
		"function f(v: int32): string | null {\n\treturn match (v) {\n\t\t0 => { if (v == 0) return \"z\"; null },\n\t\t_ => { return null; },\n\t};\n}\nconsole.log(`${f(0)}`);",
		"const pick = (v: int32): int32 => match (v) {\n\t0 => { return 10; },\n\t_ => { 20 },\n};\nconsole.log(`${pick(0)}`);",
		"function f(v: int32): void {\n\tconst s = match (v) {\n\t\t0 => { return; },\n\t\t_ => \"x\",\n\t};\n\tconsole.log(s);\n}\nf(1);",
		"function f(v: int32): string {\n\tconst s = match (v) {\n\t\t0 => { const n = v + 1; `${n}` },\n\t\t_ => { \"other\" },\n\t};\n\treturn s;\n}\nconsole.log(f(0));",
	];
	for (const src of sources) {
		const c = compileToC(src);
		assert c.ok, c.error;
		const js = compileToJS(src);
		assert js.ok, js.error;
	}
}
