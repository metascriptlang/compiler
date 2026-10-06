import { Node, NodeKind } from "std/meta";

function find(n: int32): Result<int32[], string> {
	if (n < 0) { return Result.err("neg"); }
	return Result.ok([n, n + 1]);
}

export macro total(at: Node): Node {
	const found = find(3);
	if (!found.ok) { error("no", at); }
	let sum = 0;
	for (let w = 0; w < 1; w += 1) {
		for (let i = 1; i >= 0; i -= 1) { sum += found.value[i]; }
	}
	return { kind: NodeKind.NumberLiteral, line: at.line, column: at.column, value: sum as number, isFloat: false, intVal: sum as int64, outOfRangeText: "", isBitPattern: false };
}
