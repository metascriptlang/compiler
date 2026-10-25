import { Node, NodeKind } from "std/meta";
import { arity } from "./helpers";

export macro countArgs(n: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: `${arity(n)}` };
}
