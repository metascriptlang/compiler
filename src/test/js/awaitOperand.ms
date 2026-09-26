// E2E JS: an awaited value used as the base of `.`, `[]` or a call keeps its parentheses.
// Corpus sibling: src/test/corpus/programs/423-awaitInExpression.ms runs member and index reads on every lane.

import { compileProjectToJSWithStd, MapEntry } from "../helpers";

function emitAwaitOperand(src: string): string {
	const entries: MapEntry[] = [{ entryPath: "test/awaitOperand.ms", entrySource: src }];
	return compileProjectToJSWithStd(entries, "test/awaitOperand.ms");
}

test "E2E JS: an awaited class instance is parenthesized before a field read" {
	const js = emitAwaitOperand(`
class Box { n: int32; constructor(n: int32) { this.n = n; } }
async function box(): Promise<Box> { return new Box(42); }
async function read(): Promise<int32> { return (await box()).n; }
console.log(\`\${await read()}\`);
`);
	assert js.indexOf("ERROR", 0) < 0;
	assert js.contains("()).n");
}

test "E2E JS: an awaited array is parenthesized before an index" {
	const js = emitAwaitOperand(`
async function nums(): Promise<int32[]> { return [4, 5, 6]; }
async function read(): Promise<int32> { return (await nums())[1]; }
console.log(\`\${await read()}\`);
`);
	assert js.indexOf("ERROR", 0) < 0;
	assert js.contains("())[1]");
}

test "E2E JS: an awaited receiver of a native-pattern method is parenthesized" {
	const js = emitAwaitOperand(`
async function mk(): Promise<Map<string, int32>> { const m = new Map<string, int32>(); m.set("k", 42); return m; }
async function read(): Promise<string> { return \`\${(await mk()).get("k")}\`; }
console.log(await read());
`);
	assert js.indexOf("ERROR", 0) < 0;
	assert js.contains("()).get(\"k\")");
}
