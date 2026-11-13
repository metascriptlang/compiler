import { Node, NodeKind } from "std/meta";

export type Thunk = (host: int32, parent: int32, before: int32) => void;

export function make<P>(fn: (p: P) => Thunk, p: P): Thunk { return fn(p); }

export function holdHandler(h: (e: int32) => void): void { h(7); }

export macro el(n: Node): Node {
	const ln = n.line;
	const col = n.column;
	if (n.jsxTag === "Box") {
		const row = n.jsxChildren[0].jsxExpr;
		return { kind: NodeKind.CallExpr, line: ln, column: col, callee: { kind: NodeKind.Identifier, line: ln, column: col, name: "make" }, arguments: [
			{ kind: NodeKind.Identifier, line: ln, column: col, name: "Box" },
			{ kind: NodeKind.ObjectLiteral, line: ln, column: col, keys: ["row"], properties: [row] },
		] };
	}
	const handler = n.jsxAttrs[0].jsxAttrValue;
	return {
		kind: NodeKind.ArrowFunction, line: ln, column: col, arrowParams: ["host", "parent", "before"], arrowParamTypes: ["int32", "int32", "int32"], arrowFlags: "", arrowReturnType: "void",
		arrowBody: { kind: NodeKind.CallExpr, line: ln, column: col, callee: { kind: NodeKind.Identifier, line: ln, column: col, name: "holdHandler" }, arguments: [handler] },
	};
}

export converter jsx(n: Node): Thunk {
	return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: "el", macroArgs: [n] };
}
