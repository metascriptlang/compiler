import { Node, NodeKind } from "std/meta";

export macro declareWireShape(node: Node): Node {
	const L = node.line;
	const C = node.column;
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [
			{
				kind: NodeKind.InterfaceDecl, line: L, column: C,
				interfaceName: "WireShape",
				interfaceFields: ["a"],
				interfaceFieldTypes: ["number"],
				interfaceExtends: [],
				nameLocation: { line: L, column: C },
			},
		],
	};
}
