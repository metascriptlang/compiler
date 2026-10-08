// @stdout: rows 30 31; enabled 0 1

import { Node, NodeKind } from "std/meta";

interface Style { height: number | string | null; enabled: boolean | int32 | null; }
type Scene = () => Style;
type Accessor<T> = distinct (() => T);

function accessor<T>(f: () => T): Accessor<T> { return f as Accessor<T>; }
function createComponent<P>(Comp: (props: P) => Scene, props: P): Scene { return () => Comp(props)(); }
function View(props: { style: Accessor<Style> | null }): Scene {
	return () => props.style !== null ? props.style() : { height: null, enabled: null };
}
function For<T>(props: { each: T[]; children: (item: T) => Scene }): Scene {
	return () => props.children(props.each[0])();
}
function FlatList<T>(props: { data: T[]; ListFooterComponent: Scene | null }): Scene {
	return props.ListFooterComponent !== null ? props.ListFooterComponent : () => ({ height: null, enabled: null });
}

converter jsxToScene(n: Node): Scene {
	return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: "element", macroArgs: [n] };
}

macro element(n: Node): Node {
	const l = n.line;
	const c = n.column;
	const keys: string[] = [];
	const values: Node[] = [];
	if (n.jsxTag === "View") {
		keys.push("style");
		values.push({
			kind: NodeKind.CallExpr, line: l, column: c,
			callee: { kind: NodeKind.Identifier, line: l, column: c, name: "accessor" },
			arguments: [{
				kind: NodeKind.ArrowFunction, line: l, column: c,
				arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
				arrowBody: n.jsxAttrs[0].jsxAttrValue,
			}],
		});
	} else if (n.jsxTag === "For") {
		keys.push("each"); values.push(n.jsxAttrs[0].jsxAttrValue);
		keys.push("children"); values.push(n.jsxChildren[0].jsxExpr);
	} else if (n.jsxTag === "FlatList") {
		keys.push("data"); values.push(n.jsxAttrs[0].jsxAttrValue);
		keys.push("ListFooterComponent");
		values.push({ kind: NodeKind.MacroInvocation, line: l, column: c, macroName: "element", macroArgs: [n.jsxAttrs[1].jsxAttrValue] });
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
const row0 = element(<For each={first}>{function (n: int32): Scene { return <View style={{ height: 30, enabled: n }} />; }}</For>);
const row1 = element(<For each={second}>{function (n: int32): Scene { return <View style={{ height: 31, enabled: n }} />; }}</For>);

const a = row0();
const b = row1();
if ((a.height as number) !== 30 || (b.height as number) !== 31) throw new Error("numeric payloads");
if ((a.enabled as int32) !== 0 || (b.enabled as int32) !== 1) throw new Error("integer payloads");
console.log("rows " + (a.height as number).toString() + " " + (b.height as number).toString()
	+ "; enabled " + (a.enabled as int32).toString() + " " + (b.enabled as int32).toString());
