// @stdout: rows 20 21; footer 48; variants auto true 2.5 false; empty null

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
const row0 = element(<For each={first}>{(n: int32): Scene => <View style={{ height: 20, enabled: n }} />}</For>);
const row1 = element(<For each={second}>{(n: int32): Scene => <View style={{ height: 21, enabled: n }} />}</For>);
const footer = element(<FlatList data={first} ListFooterComponent={<View style={{ height: 48 }} />} />);
const text = element(<For each={first}>{(n: int32): Scene => <View style={{ height: "auto", enabled: true }} />}</For>);
const fractional = element(<FlatList data={first} ListFooterComponent={<View style={{ height: 2.5, enabled: false }} />} />);
const empty = element(<FlatList data={first} ListFooterComponent={<View style={{ height: null, enabled: null }} />} />);

const a = row0();
const b = row1();
const f = footer();
const t = text();
const v = fractional();
const e = empty();
if ((a.height as number) !== 20 || (b.height as number) !== 21 || (f.height as number) !== 48) throw new Error("numeric payloads");
if ((a.enabled as int32) !== 0 || (b.enabled as int32) !== 1) throw new Error("integer payloads");
if ((t.height as string) !== "auto" || (t.enabled as boolean) !== true) throw new Error("string and boolean payloads");
if ((v.height as number) !== 2.5 || (v.enabled as boolean) !== false) throw new Error("fractional and false payloads");
if (e.height !== null || e.enabled !== null) throw new Error("absent payloads");
console.log("rows " + (a.height as number).toString() + " " + (b.height as number).toString()
	+ "; footer " + (f.height as number).toString() + "; variants " + (t.height as string)
	+ " " + (t.enabled as boolean).toString() + " " + (v.height as number).toString()
	+ " " + (v.enabled as boolean).toString() + "; empty null");
