// @stdout: jsx 1 sets 1; plain 2; generic 3; constraint 4

import { Node, NodeKind } from "std/meta";

enum Lens { Status, Compute }
type Setter<T> = (v: T | ((prev: T) => T)) => void;
type Scene = () => number;

function createComponent<P>(Comp: (props: P) => Scene, props: P): Scene { return () => Comp(props)(); }
function Button(props: { active: boolean; onPress: () => void }): Scene {
	return () => { props.onPress(); return props.active ? 1 : 0; };
}

converter jsxToScene(n: Node): Scene {
	return { kind: NodeKind.MacroInvocation, line: n.line, column: n.column, macroName: "element", macroArgs: [n] };
}

macro element(n: Node): Node {
	const l = n.line;
	const c = n.column;
	return {
		kind: NodeKind.CallExpr, line: l, column: c,
		callee: { kind: NodeKind.Identifier, line: l, column: c, name: "createComponent" },
		arguments: [
			{ kind: NodeKind.Identifier, line: l, column: c, name: n.jsxTag },
			{
				kind: NodeKind.ObjectLiteral, line: l, column: c, keys: ["active", "onPress"],
				properties: [n.jsxAttrs[0].jsxAttrValue, n.jsxAttrs[1].jsxAttrValue],
			},
		],
	};
}

let sets = 0;
function signal(v: Lens): [() => Lens, Setter<Lens>] {
	return [(): Lens => v, (x: Lens | ((prev: Lens) => Lens)): void => { sets += 1; }];
}

function holder<P>(props: P): P { return props; }
function holderBound<P extends { f: () => void }>(props: P): P { return props; }
function plain(props: { f: () => void }): void { props.f(); }

function screen(): Scene {
	const [lens, setLens] = signal(Lens.Compute);
	return <Button active={lens() == Lens.Compute} onPress={(): void => { setLens(Lens.Status); }} />;
}

const first = screen()();
const afterJsx = sets;
const [, setLens] = signal(Lens.Compute);
plain({ f: (): void => { setLens(Lens.Status); } });
const afterPlain = sets;
holder({ f: (): void => { setLens(Lens.Compute); } }).f();
const afterGeneric = sets;
holderBound({ f: (): void => { setLens(Lens.Status); } }).f();
console.log("jsx " + first.toString() + " sets " + afterJsx.toString() + "; plain " + afterPlain.toString()
	+ "; generic " + afterGeneric.toString() + "; constraint " + sets.toString());
