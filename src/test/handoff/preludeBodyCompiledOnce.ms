import { compileToCWithStd, compileToJSWithStd } from "../helpers";
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

test "a macro helper the build checked for another target is checked again for the engine" {
	const result = compileToJSWithStd(`
interface Person {
	name: string;
	age: int32;
}

const p: Person = { name: "Alice", age: 30 };
console.log(JSON.stringify(p));
`);
	assert result.ok, result.ok ? "" : result.error;
}

test "a macro helper the C build checked is checked again for the engine" {
	const result = compileToCWithStd(`
interface Person {
	name: string;
	age: int32;
}

function main(): void {
	const p: Person = { name: "Alice", age: 30 };
	console.log(JSON.stringify(p));
}
`);
	assert result.ok, result.ok ? "" : result.error;
}
