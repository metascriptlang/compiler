// @stdout: PLACEHOLDER
// note: a macro argument is checked against the macro's declared formal, with the macro's type parameters bound in argument order, so an unannotated lambda is typed from the receiver before the macro reads it (as an ordinary generic call types it). The body sees a function-typed formal as a Node. Variants: dot call and bare call, a second type parameter, a lambda with its own annotation, a `fn: Node` formal that stays untyped.

import { ArrowFunctionData, MemberExprData, Node, NodeKind, TypeObjectData, createNodeAt, getType } from "std/meta";

struct Card {
	column: string;
	owner: uint32;
}

class Table<R, K> {
	rows: R[] = [];
	key: K | null = null;
}

function shown(n: Node): string {
	const t = getType(n);
	if (t == null) return "none";
	if (t.kind === NodeKind.TypeObject) {
		const o = t as TypeObjectData;
		return "row:" + o.typExprTypeName + "{" + o.typExprFieldNames.join(",") + "}";
	}
	return "other";
}

function report(f: Node): string {
	const arrow = f as ArrowFunctionData;
	return "declared=[" + arrow.arrowParamTypes.join(",") + "] " + shown((arrow.arrowBody as MemberExprData).object);
}

macro where<R, K>(this t: Table<R, K>, f: (row: R) => boolean): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: report(f) }, f.location);
}

macro whereOne<R>(t: Table<R, string>, f: (row: R) => boolean): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: report(f) }, f.location);
}

macro untyped(fn: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: report(fn) }, fn.location);
}

const cards = new Table<Card, string>();
console.log(cards.where(c => c.column == "todo"));
console.log(where(cards, c => c.owner == 1));
console.log(whereOne(cards, (c: Card) => c.column == "x"));
console.log(untyped((c) => c.column));
