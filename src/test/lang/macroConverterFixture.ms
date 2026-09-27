import { Node, NodeKind } from "std/meta";

export type MkNum = () => number;

export function mkImpl(): number { return 7; }

export converter toThunk(n: Node): MkNum {
	return { kind: NodeKind.Identifier, line: n.line, column: n.column, name: "mkImpl" };
}
