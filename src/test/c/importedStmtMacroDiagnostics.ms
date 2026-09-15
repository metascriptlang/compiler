import { checkProjectDiagnostics, MapEntry } from "../helpers";

const EMITTER = `import { Node, NodeKind } from "std/meta";

export macro failsAtTop(node: Node): Node {
	error("failsAtTop refused its argument", node);
	return { kind: NodeKind.SpliceMany, line: node.line, column: node.column, spliceNodes: [] };
}

export macro emitsNothing(node: Node): Node {
	return { kind: NodeKind.SpliceMany, line: node.line, column: node.column, spliceNodes: [] };
}
`;

function occurrences(messages: string[], needle: string): int32 {
	let n = 0;
	for (const m of messages) {
		if (m.indexOf(needle, 0) >= 0) n = n + 1;
	}
	return n;
}

test "an imported statement macro that fails reports its error once" {
	const entries: MapEntry[] = [
		{ entryPath: "src/emitter.ms", entrySource: EMITTER },
		{ entryPath: "src/main.ms", entrySource: `import { failsAtTop } from "./emitter";

failsAtTop(0);
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, "failsAtTop refused its argument") == 1;
}

test "an import read only as an imported statement macro argument counts as used" {
	const entries: MapEntry[] = [
		{ entryPath: "src/emitter.ms", entrySource: EMITTER },
		{ entryPath: "src/limits.ms", entrySource: `export const LIMIT = 3;
` },
		{ entryPath: "src/main.ms", entrySource: `import { emitsNothing } from "./emitter";
import { LIMIT } from "./limits";

emitsNothing(LIMIT);
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, "'emitsNothing' is imported but never used") == 0;
	assert occurrences(messages, "'LIMIT' is imported but never used") == 0;
}
