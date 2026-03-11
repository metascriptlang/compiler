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

test "Result-returning closure cast includes NRVO out-param" {
	// The lambda returns Result (NRVO type), so its C signature is:
	//   void fn(ResultType* __result, msString s)
	// The closure cast for the function type must match:
	//   void(*)(ResultType*, msString)
	// NOT: ResultType(*)(msString) — which is what happens without NRVO in closure casts
	const src = "type MyResult = Result<number, string>;\ntype Callback = (x: number) => MyResult;\nfunction run(cb: Callback): void {\n  const r = cb(42);\n}\nrun((x: number): MyResult => { return Result.ok(x); });";
	const c = compileToC(src);
	assert c.ok;
	// The closure call must cast with void return + Result* first param
	assert c.value.contains("void(*)");
}
