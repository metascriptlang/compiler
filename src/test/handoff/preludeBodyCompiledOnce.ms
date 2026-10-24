import { compileToCWithStd } from "../helpers";
import { engineRecheckCount } from "../../codegen/raiser/eval";

test "a prelude routine a macro calls is compiled from its checked body, not checked again" {
	const before = engineRecheckCount();
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro preludeBodies(node: Node): Node {
	const names: string[] = ["a", "b", "c"];
	const nums: int32[] = [3, 1, 2];
	const v = names.join("-") + nums.indexOf(2).toString() + nums.includes(5).toString();
	if (v !== "a-b-c2false") { error("prelude body mismatch", node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = preludeBodies(0);
	console.log(x);
}
`);
	assert result.ok, result.ok ? "" : result.error;
	assert engineRecheckCount() == before, `prelude bodies checked again: ${engineRecheckCount() - before}`;
}
