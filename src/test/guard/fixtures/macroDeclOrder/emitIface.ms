import { Node, NodeKind } from "std/meta";

export macro emitIface(node: Node): Node {
	const L = node.line;
	const C = node.column;
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [
			{
				kind: NodeKind.InterfaceDecl, line: L, column: C,
				interfaceName: "MacroEmitted",
				interfaceFields: ["a"],
				interfaceFieldTypes: ["float64"],
				interfaceExtends: [],
				nameLocation: { line: L, column: C },
			},
		],
	};
}
