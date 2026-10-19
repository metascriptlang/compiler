// @stdout: 5 9 7
// note: a function a macro hands back keeps every name that read an outer local, even when the function declares a local of that name in a block, a for-of or a catch and the macro wraps it in a scope that declares the name again. Only the function's own locals are rebound. Same output on every backend.
import { Node, NodeKind } from "std/meta";

type Text = () => string;

macro shadowX(n: Node): Node {
	const l = n.line;
	const c = n.column;
	return {
		kind: NodeKind.CallExpr, line: l, column: c,
		callee: {
			kind: NodeKind.ArrowFunction, line: l, column: c,
			arrowParams: ["x"], arrowParamTypes: ["int32"], arrowFlags: "", arrowReturnType: "Text",
			arrowBody: n,
		},
		arguments: [{ kind: NodeKind.NumberLiteral, line: l, column: c, value: 99, isFloat: false, intVal: 99 as int64, outOfRangeText: "", isBitPattern: false }],
		isDirectCall: true, resolvedOverloadIdx: -1,
	};
}

function blockLocal(): string {
	const x = 5;
	const t = shadowX((): string => { { const x = 1; } return x.toString(); });
	return t();
}

function forOfBinding(): string {
	const x = 6;
	const t = shadowX((): string => { let s = 0; for (const x of [1, 2]) s += x; return (x + s).toString(); });
	return t();
}

function catchBinding(): string {
	const x = 7;
	const t = shadowX((): string => { try { throw new Error("e"); } catch (x) { } return x.toString(); });
	return t();
}

console.log(`${blockLocal()} ${forOfBinding()} ${catchBinding()}`);
