// @stdout: one 1 | two 2 | each 3 4
// note: a macro call inside an arrow inside another macro call keeps its own locals: the outer macro hands the checked arrow back, and the inner expansion's `const _p1` and the arrow's parameters bind to the redeclared names, also when a generic call rechecks an untyped arrow.

import { Node, NodeKind, DeclKind } from "std/meta";

type Text = () => string;

function For<T>(props: { each: T[]; children: (item: T) => Text }): Text {
	return () => {
		let out = "each";
		for (const v of props.each) out = out + " " + props.children(v)();
		return out;
	};
}

converter jsxToText(n: Node): Text {
	return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: "element", macroArgs: [n] };
}

macro element(n: Node): Node {
	const l = n.line;
	const c = n.column;
	if (n.jsxTag === "li") {
		return {
			kind: NodeKind.ArrowFunction, line: l, column: c,
			arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "string",
			arrowBody: {
				kind: NodeKind.BlockStmt, line: l, column: c,
				statements: [
					{ kind: NodeKind.VariableDecl, line: l, column: c, declName: "_p1", declType: "string", declKind: DeclKind.Const, initializer: n.jsxChildren[0].jsxExpr },
					{ kind: NodeKind.ReturnStmt, line: l, column: c, argument: { kind: NodeKind.Identifier, line: l, column: c, name: "_p1" } },
				],
			},
		};
	}
	return n.jsxChildren[0].jsxExpr;
}

const one = element(<div>{((k: int32): Text => element(<li>{"one " + k.toString()}</li>))(1)}</div>);
const two = element(<div>{((k: int32): Text => element(<li>{"two " + k.toString()}</li>))(2)}</div>);
const each = element(<div>{For<int32>({ each: [3, 4], children: (k) => element(<li>{k.toString()}</li>) })}</div>);
console.log(one() + " | " + two() + " | " + each());
