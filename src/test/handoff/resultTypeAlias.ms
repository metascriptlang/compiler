// Test: Result type aliases with class/pointer value types resolve in C codegen
// Bug: `type NodeResult = Result<Node, string>` where Node is a class (pointer)
// emits incomplete struct NodeResult instead of resolving to underlying Result type.

import { compileToC } from "../helpers";

test "Result alias with primitive resolves" {
	const src = "type MyResult = Result<number, string>;\nfunction foo(): MyResult {\nreturn Result.ok(42);\n}";
	const c = compileToC(src);
	assert c.ok;
	assert !c.value.contains("struct MyResult");
}

test "Result alias with class value type resolves" {
	const src = "class Item { name: string; }\ntype ItemResult = Result<Item, string>;\nfunction foo(): ItemResult {\nreturn Result.ok(new Item(\"x\"));\n}";
	const c = compileToC(src);
	assert c.ok;
	assert !c.value.contains("struct ItemResult");
}

test "Result alias as callback return type" {
	const src = "type NumResult = Result<number, string>;\ntype ParseFn = (s: string) => NumResult;\nlet fn: ParseFn = (s: string): NumResult => {\nreturn Result.ok(1);\n};";
	const c = compileToC(src);
	assert c.ok;
}
