import { Node, NodeKind } from "std/meta";

export struct Meters { v: number; }

export converter toMeters(n: Node): Meters {
	return {
		kind: NodeKind.ObjectLiteral, line: n.line, column: n.column,
		keys: ["v"], keyLocations: [],
		properties: [{ kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 3 }],
	};
}

export enum Kind { A, B }

export struct Shape = match (kind: Kind) {
	Kind.A => {},
	Kind.B => { size: int32 },
};
