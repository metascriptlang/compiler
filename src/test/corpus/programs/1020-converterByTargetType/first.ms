import { Node, NodeKind } from "std/meta";

export struct Meters { v: number; }

export converter toFirstMeters(n: Node): Meters {
	return {
		kind: NodeKind.ObjectLiteral, line: n.line, column: n.column,
		keys: ["v"], keyLocations: [],
		properties: [{ kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 1 }],
	};
}
