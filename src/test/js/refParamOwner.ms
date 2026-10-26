// A parameter passed to a `ref` formal is boxed in a cell by the routine that declares it.

import { compileToJSWithStd } from "../helpers";

const BUMP = "function bump(ref x: int32): void { x += 1; }\n";
const BOX = "n = [n];";

function emitted(source: string): string {
	const js = compileToJSWithStd(BUMP + source);
	if (!js.ok) throw new Error(js.error);
	return js.value;
}

function boxedAfter(source: string, marker: string): boolean {
	const js = emitted(source);
	const at = js.indexOf(marker, js.indexOf("function bump"));
	if (at < 0) throw new Error("marker '" + marker + "' not emitted:\n" + js);
	return js.indexOf(BOX, at) > at && js.indexOf(BOX) == js.lastIndexOf(BOX);
}

test "E2E JS: an arrow, function expression or method boxes its own ref-passed parameter" {
	assert boxedAfter("const f = (n: int32): int32 => { bump(n); return n; };\nconsole.log(f(1));", "=>");
	assert boxedAfter("const f = function (n: int32): int32 { bump(n); return n; };\nconsole.log(f(1));", "function(");
	assert boxedAfter("class C { at(n: int32): int32 { bump(n); return n; } }\nconsole.log(new C().at(1));", "at(");
}

test "E2E JS: an expression-bodied arrow gets a block for the box" {
	assert boxedAfter("const f = (n: int32): void => bump(n);\nf(1);", "=>");
}

test "E2E JS: an inner parameter that shadows an outer one is boxed by the inner routine" {
	const source = "function h(n: int32): int32 {\n\tconst g = (n: int32): int32 => { bump(n); return n; };\n\treturn g(n);\n}\nconsole.log(h(1));";
	assert boxedAfter(source, "=>");
}
