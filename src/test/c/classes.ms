// E2E: Classes and Interfaces → C output
// Classes are instantiated so DCE keeps them.

import { compileToC } from "../helpers";


test "E2E C: class with new" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("Foo");
}

test "E2E C: interface struct" {
	const src = "interface Point { x: number; y: number }\nconst p: Point = { x: 1, y: 2 };";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("struct Point");
}

test "E2E C: constructor allocates with msAllocTyped" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	assert c.ok;
	// Constructor uses heap allocation for class types
	assert c.value.contains("msAllocTyped");
	assert c.value.contains("Foo_typeInfo");
}

const DOWN_NODES = "class BaseNode { id: int32 = 0; }\n" +
	"class NativeNode extends BaseNode { view: string = \"native\"; }\n";

function checkedConversions(code: string): int32 {
	let count = 0 as int32;
	let at = code.indexOf("msObjDownConv(");
	while (at >= 0) {
		count += 1;
		at = code.indexOf("msObjDownConv(", at + 1);
	}
	return count;
}

test "E2E C: a conversion out of unknown and a base-to-derived conversion are each checked" {
	const c = compileToC(DOWN_NODES +
		"function f(u: unknown): string { return (u as NativeNode).view; }\n" +
		"function g(b: BaseNode): string { return (b as NativeNode).view; }\n" +
		"console.log(f(new NativeNode()) + g(new NativeNode()));");
	assert c.ok;
	const checked = checkedConversions(c.value);
	assert checked == 2, "got " + checked.toString();
}

test "E2E C: an upcast is not checked" {
	const c = compileToC(DOWN_NODES +
		"function f(n: NativeNode): BaseNode { return n as BaseNode; }\n" +
		"console.log(f(new NativeNode()).id.toString());");
	assert c.ok;
	assert checkedConversions(c.value) == 0;
}

test "E2E C: an alias of a class is that class as a conversion target, down and up" {
	const c = compileToC(DOWN_NODES +
		"type Native = NativeNode;\ntype Base = BaseNode;\n" +
		"function f(u: unknown): string { return (u as Native).view; }\n" +
		"function g(n: NativeNode): Base { return n as Base; }\n" +
		"console.log(f(new NativeNode()) + g(new NativeNode()).id.toString());");
	assert c.ok;
	const checked = checkedConversions(c.value);
	assert checked == 1, "got " + checked.toString();
}
