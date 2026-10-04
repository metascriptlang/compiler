import { checkProjectDiagnostics, MapEntry } from "../helpers";

function occurrences(messages: string[], text: string): int32 {
	let n = 0;
	for (const m of messages) {
		if (m.contains(text)) n += 1;
	}
	return n;
}

const helperModule = `export function helper(n: int32): int32 { return n * 2; }
export function other(): int32 { return 1; }
`;

test "compileTimeNameUse: a macro's return type and a literal bindSym name count as uses" {
	const entries: MapEntry[] = [
		{ entryPath: "src/helpers.ms", entrySource: helperModule },
		{ entryPath: "src/lib.ms", entrySource: `import { Node, NodeKind, bindSym } from "std/meta";
import { helper } from "./helpers";
export macro seven(): Node {
	return { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 7, isFloat: false, intVal: 7, outOfRangeText: "", isBitPattern: false };
}
export macro twice(): Node {
	return { kind: NodeKind.CallExpr, line: 0, column: 0, callee: bindSym("helper"), arguments: [], isDirectCall: false, resolvedOverloadIdx: -1 };
}
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/lib.ms");
	assert occurrences(messages, "'Node' is imported but never used") == 0, messages.join("\n");
	assert occurrences(messages, "'helper' is imported but never used") == 0, messages.join("\n");
}

test "compileTimeNameUse: a @comptime block and a macro type argument count as uses; a dead import still warns" {
	const entries: MapEntry[] = [
		{ entryPath: "src/helpers.ms", entrySource: helperModule },
		{ entryPath: "src/ops.ms", entrySource: `export enum Op { A, B, C }
` },
		{ entryPath: "src/count.ms", entrySource: `import { Node, NodeKind } from "std/meta";
export macro countMembers(): Node {
	const decl = getTypeArg();
	return { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: decl.enumMembers.length, isFloat: false, intVal: decl.enumMembers.length, outOfRangeText: "", isBitPattern: false };
}
` },
		{ entryPath: "src/main.ms", entrySource: `import { helper, other } from "./helpers";
import { Op } from "./ops";
import { countMembers } from "./count";
const doubled: int32 = @comptime { return helper(3); };
const n: int32 = countMembers<Op>();
console.log(doubled + n);
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, "'helper' is imported but never used") == 0, messages.join("\n");
	assert occurrences(messages, "'Op' is imported but never used") == 0, messages.join("\n");
	assert occurrences(messages, "'other' is imported but never used") == 1, messages.join("\n");
}
