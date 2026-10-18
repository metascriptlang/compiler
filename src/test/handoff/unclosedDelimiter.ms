import { compileToC, compileToJS, compileToJSBare } from "../helpers";

function refusedOnBoth(source: string, expected: string): string {
	const c = compileToC(source);
	const js = compileToJS(source);
	if (c.ok || js.ok) return `accepted (C ${c.ok}, JS ${js.ok}): ${source}`;
	if (!c.error.includes(expected)) return "C: " + c.error;
	if (!js.error.includes(expected)) return "JS: " + js.error;
	return "";
}

const PRELUDE = "class C { x: int32; constructor(x: int32) { this.x = x; } }\nfunction f(x: int32): int32 { return x; }\nfunction g(x: int32): int32 { return x; }\nconst xs = [1, 2];\n";

test "unclosedDelimiter: an unclosed bracket is a syntax error on C and JS, mid-file and at EOF" {
	const paren = "Expected ')' to close the '('";
	const bracket = "Expected ']' to close the '['";
	const brace = "Expected '}' to close the '{'";
	const shapes = [
		["console.log(\"a \" + xs.join(\",\";\nconsole.log(\"b\");\n", paren],
		["const r = f(g(1);\nconsole.log(`${r}`);\n", paren],
		["const c = new C(1;\nconsole.log(`${c.x}`);\n", paren],
		["const ys = [1, 2;\nconsole.log(`${ys.length}`);\n", bracket],
		["const r = (1 + 2;\nconsole.log(`${r}`);\n", paren],
		["const r = xs[0;\nconsole.log(`${r}`);\n", bracket],
		["const o = { a: 1, b: 2;\nconsole.log(`${o.a}`);\n", brace],
		["console.log(\"a\"\n", paren],
		["const r = f(g(1)\n", paren],
		["const c = new C(1\n", paren],
		["const ys: int32[] = [1, 2\nconsole.log(String(ys.length))\n", bracket],
		["const r = (1 + 2\n", paren],
		["const r = xs[0\n", bracket],
		["const o = { a: 1\n", brace],
	];
	for (const shape of shapes) {
		const verdict = refusedOnBoth(PRELUDE + shape[0], shape[1]);
		assert verdict == "", verdict;
	}
}

test "unclosedDelimiter: the same shapes closed compile on C and JS" {
	const source = PRELUDE + "console.log(\"a \" + xs.join(\",\"));\nconst r = f(g(1));\nconst c = new C(1);\nconst ys = [1, 2];\nconst p = (1 + 2);\nconst q = xs[0];\nconst o = { a: 1, b: 2 };\nconsole.log(`${r} ${c.x} ${ys.length} ${p} ${q} ${o.a}`);\n";
	const c = compileToC(source);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileToJSBare(source);
	assert js.ok, js.ok ? "" : js.error;
}
