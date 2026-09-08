import { Node, NodeKind } from "std/meta";

export macro bug137Iface(node: Node): Node {
	const L = node.line;
	const C = node.column;
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [
			{
				kind: NodeKind.InterfaceDecl, line: L, column: C,
				interfaceName: "Bug137Shape",
				interfaceFields: ["a"],
				interfaceFieldTypes: ["number"],
				interfaceExtends: [],
				nameLocation: { line: L, column: C },
			},
		],
	};
}
