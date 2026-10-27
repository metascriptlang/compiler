import { Node, NodeKind } from "std/meta";

export macro same(x: Node): Node { return x; }

export function mount<P>(component: (props: P) => number, props: P): number { return component(props); }

export macro mountWith(component: Node, value: Node): Node {
	const at = { line: value.line, column: value.column };
	return {
		kind: NodeKind.CallExpr, line: at.line, column: at.column,
		callee: { kind: NodeKind.Identifier, line: at.line, column: at.column, name: "mount" },
		arguments: [
			component,
			{ kind: NodeKind.ObjectLiteral, line: at.line, column: at.column, keys: ["renderItem"], properties: [value], keyLocations: [] },
		],
	};
}
