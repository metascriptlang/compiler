// @stdout: int32 int32 string int32 int32
// @exit: 0
// note: a macro that passes its argument on to another macro leaves the second one able to ask for the argument's type. `getType` and `typeKind` read the checker type of the argument; the type used to be dropped when the first macro returned, so the second one failed with `node has no type` whenever it was reached through another macro. Direct, forwarded, forwarded twice, a string, and the first element of a forwarded list.

import { Node, NodeKind, TypeKind, bindSym, getType, typeKind } from "std/meta";

macro argumentKind(value: Node): Node {
	if (getType(value) == null) error("the argument carries no type", value);
	const kind = typeKind(value);
	const name = kind == TypeKind.Int32 ? "int32" : kind == TypeKind.String ? "string" : "other";
	return { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: name };
}

macro firstElementKind(list: Node): Node {
	const element = list.elements[0];
	if (getType(element) == null) error("the first element carries no type", element);
	const name = typeKind(element) == TypeKind.Int32 ? "int32" : "other";
	return { kind: NodeKind.StringLiteral, line: list.line, column: list.column, value: name };
}

macro forwardArgumentKind(value: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: value.line,
		column: value.column,
		callee: bindSym("argumentKind"),
		arguments: [value],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro forwardAgain(value: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: value.line,
		column: value.column,
		callee: bindSym("forwardArgumentKind"),
		arguments: [value],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro forwardFirstElementKind(list: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: list.line,
		column: list.column,
		callee: bindSym("firstElementKind"),
		arguments: [list],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

function main(): void {
	const integer: int32 = 3;
	const text: string = "three";
	const first: int32 = 1;
	const second: int32 = 2;
	console.log(`${argumentKind(integer)} ${forwardArgumentKind(integer)} ${forwardArgumentKind(text)} ${forwardAgain(integer)} ${forwardFirstElementKind([first, second])}`);
}
main();
