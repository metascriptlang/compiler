import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

const REFUSAL = "a computed key must be a string literal";
const SCREEN = "const screen = { wide: \"wide\", narrow: \"narrow\" };\n";
const DROP = "import { Node, NodeKind } from \"std/meta\";\n"
	+ "macro drop(v: Node): Node { return { kind: NodeKind.NumberLiteral, line: v.line, column: v.column, value: 0 }; }\n";

function errorsOf(source: string): string {
	const c = compileToCWithStd(source);
	const js = compileProjectToJSWithStd([{ entryPath: "test/computedKey.ms", entrySource: source }], "test/computedKey.ms");
	if (c.ok && !js.startsWith("ERROR:")) return "";
	if (!c.ok && js.startsWith("ERROR:")) return c.error + "\n" + js;
	return "backends disagree: " + (c.ok ? "C ok" : c.error) + " / " + js;
}

function refusals(source: string): int32 {
	return errorsOf(source).split(REFUSAL).length - 1;
}

test "a string-literal computed key is the field it names" {
	const errors = errorsOf("const o = { [\"lit\"]: 3, plain: 4 };\nconsole.log(o.lit + o.plain);\n");
	assert errors == "", errors;
}

test "a member-access computed key is refused at the key on C and JS" {
	assert refusals(SCREEN + "const o = { [screen.wide]: 1 };\n") == 2;
}

test "a const identifier key is refused, since its type is string" {
	assert refusals("const k = \"kv\";\nconst o = { [k]: 2 };\n") == 2;
}

test "two computed keys are each refused rather than collapsed into one field" {
	assert refusals(SCREEN + "const o = { [screen.wide]: 1, [screen.narrow]: 2 };\n") == 4;
}

test "a computed key nested inside a macro argument reaches the macro" {
	const errors = errorsOf(DROP + SCREEN + "const n = drop({ sidebar: { when: { [screen.wide]: { width: 280 } } } });\nconsole.log(n);\n");
	assert errors == "", errors;
}
