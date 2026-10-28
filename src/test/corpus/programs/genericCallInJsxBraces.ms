// @stdout: [7] [ab] [[7]]

import { Node, NodeKind } from "std/meta";

type Scene = () => string;
function Text(props: { text: string }): Scene { return () => props.text; }
function Row(props: { child: Scene }): Scene { return () => "[" + props.child() + "]"; }

converter jsxToScene(n: Node): Scene {
	return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: "element", macroArgs: [n] };
}

macro element(n: Node): Node {
	const l = n.line;
	const c = n.column;
	const keys: string[] = [];
	const values: Node[] = [];
	if (n.jsxTag === "Text") {
		keys.push("text"); values.push(n.jsxAttrs[0].jsxAttrValue);
	} else if (n.jsxTag === "Row") {
		keys.push("child"); values.push(n.jsxChildren[0].jsxExpr);
	} else { error("unsupported scene " + n.jsxTag, n); }
	return {
		kind: NodeKind.CallExpr, line: l, column: c,
		callee: { kind: NodeKind.Identifier, line: l, column: c, name: "createComponent" },
		arguments: [
			{ kind: NodeKind.Identifier, line: l, column: c, name: n.jsxTag },
			{ kind: NodeKind.ObjectLiteral, line: l, column: c, keys: keys, properties: values },
		],
	};
}
function createComponent<P>(Comp: (props: P) => Scene, props: P): Scene { return () => Comp(props)(); }

function Labelled<T>(props: { item: T; label: (item: T) => string }): Scene {
	return <Text text={props.label(props.item)} />;
}

function Outer(): Scene {
	return <Row>{Labelled<int32>({ item: 7, label: (n: int32): string => `${n}` })}</Row>;
}
function OuterText(): Scene {
	return <Row>{Labelled<string>({ item: "ab", label: (s: string): string => s })}</Row>;
}
function Nested(): Scene {
	return <Row>{<Row>{Labelled<int32>({ item: 7, label: (n: int32): string => `${n}` })}</Row>}</Row>;
}
console.log(Outer()() + " " + OuterText()() + " " + Nested()());
