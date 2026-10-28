// E2E JS: a line break after `return` ends the statement, so the next line is not its value.
// Parser sibling: the inline tests of src/parser/statements/control.ms.

import { compileProjectToJSWithStd, MapEntry } from "../helpers";

function emitBareReturn(src: string): string {
	const entries: MapEntry[] = [{ entryPath: "test/bareReturnLineBreak.ms", entrySource: src }];
	return compileProjectToJSWithStd(entries, "test/bareReturnLineBreak.ms");
}

test "E2E JS: a call on the line after return stays a statement in a function" {
	const js = emitBareReturn(`
let hits = 0;
function side(): void { hits += 1; }
function f(x: boolean): void {
	if (x) return
	side()
}
f(true);
console.log(\`\${hits}\`);
`);
	assert js.indexOf("ERROR", 0) < 0;
	assert js.indexOf("return side", 0) < 0;
}

test "E2E JS: an identifier on the line after return stays a statement in an arrow block" {
	const js = emitBareReturn(`
let count = 0;
const g = (x: boolean): void => {
	if (x) return
	count
}
g(true);
console.log(\`\${count}\`);
`);
	assert js.indexOf("ERROR", 0) < 0;
	assert js.indexOf("return count", 0) < 0;
}
