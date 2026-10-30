// E2E JS: a line break after `throw` is refused, since the next line is not its operand.
// Parser sibling: the inline tests of src/parser/statements/errorHandling.ms.

import { compileProjectToJSWithStd, MapEntry } from "../helpers";

function emitThrow(src: string): string {
	const entries: MapEntry[] = [{ entryPath: "test/throwLineBreak.ms", entrySource: src }];
	return compileProjectToJSWithStd(entries, "test/throwLineBreak.ms");
}

test "E2E JS: throw followed by a line break is refused" {
	const js = emitThrow(`
function f(): void {
	throw
	new Error("x")
}
f();
`);
	assert js.indexOf("Line break is not permitted after 'throw'", 0) >= 0;
}

test "E2E JS: throw followed by a block comment that spans a line break is refused" {
	const js = emitThrow(`
function f(): void {
	throw /*
	*/ new Error("x")
}
f();
`);
	assert js.indexOf("Line break is not permitted after 'throw'", 0) >= 0;
}

test "E2E JS: throw with its value on the same line or inside parentheses is kept" {
	const js = emitThrow(`
function f(): void {
	throw (
		new Error("x")
	)
}
function g(): void {
	throw new Error("y")
}
f();
g();
`);
	assert js.indexOf("ERROR", 0) < 0;
	assert js.indexOf("throw", 0) >= 0;
}
