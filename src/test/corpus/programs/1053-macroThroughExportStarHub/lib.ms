import { Node, NodeKind, bindSym } from "std/meta";

export function wrap(): Result<int32, string> { return Result.ok(41); }

export macro fortyTwo(): Node {
	return { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 42, isFloat: false,
		intVal: 42, outOfRangeText: "", isBitPattern: false };
}

export macro tried(): Node {
	return { kind: NodeKind.CallExpr, line: 0, column: 0, callee: bindSym("wrap"),
		arguments: [], isDirectCall: false, resolvedOverloadIdx: -1 };
}
