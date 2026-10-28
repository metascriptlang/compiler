// @stdout: 2 1

import { Node, NodeKind } from "std/meta";

enum Toggle { None, Open, Folded }
interface Style { height: number | null; }
type Scene = () => Style;

function createComponent<P>(Comp: (props: P) => Scene, props: P): Scene { return () => Comp(props)(); }
function View(props: { height: number }): Scene {
	return () => ({ height: props.height });
}
function For<T>(props: { each: T[]; children: (item: T) => Scene }): Scene {
	return () => props.children(props.each[0])();
}
function heightOf(t: Toggle): number { return t == Toggle.Open ? 2 : 1; }

converter jsxToScene(n: Node): Scene {
	return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: "element", macroArgs: [n] };
}

macro element(n: Node): Node {
	const l = n.line;
	const c = n.column;
	const keys: string[] = [];
	const values: Node[] = [];
	if (n.jsxTag === "View") {
		keys.push("height"); values.push(n.jsxAttrs[0].jsxAttrValue);
	} else if (n.jsxTag === "For") {
		keys.push("each"); values.push(n.jsxAttrs[0].jsxAttrValue);
		keys.push("children"); values.push(n.jsxChildren[0].jsxExpr);
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

const first: int32[] = [0];
const second: int32[] = [1];
const row0 = element(<For each={first}>{function (n: int32): Scene {
	const toggle = n == 0 ? Toggle.Open : Toggle.None;
	return <View height={heightOf(toggle)} />;
}}</For>);
const row1 = element(<For each={second}>{function (n: int32): Scene {
	const toggle = n == 0 ? Toggle.Open : Toggle.None;
	return <View height={heightOf(toggle)} />;
}}</For>);
console.log(`${row0().height as number} ${row1().height as number}`);
