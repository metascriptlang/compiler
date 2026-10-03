import { compileToJS } from "../helpers";

const NODES = "class BaseNode { id: int32 = 0; }\n" +
	"class NativeNode extends BaseNode { view: string = \"native\"; }\n" +
	"interface I { v: int32; }\n" +
	"class Box<T> { v: T; constructor(v: T) { this.v = v; } }\n";

test "E2E JS: a conversion out of unknown is an instanceof test that reports the failure" {
	const js = compileToJS(NODES +
		"function f(u: unknown): string { return (u as NativeNode).view; }\n" +
		"console.log(f(new NativeNode()));");
	assert js.ok;
	assert js.value.contains("instanceof");
	assert js.value.contains("invalid object conversion: ");
}

test "E2E JS: an alias of a class is tested against the class" {
	const js = compileToJS(NODES + "type Native = NativeNode;\ntype Base = BaseNode;\n" +
		"function f(u: unknown): string { return (u as Native).view; }\n" +
		"function g(n: NativeNode): Base { return n as Base; }\n" +
		"console.log(f(new NativeNode()) + g(new NativeNode()).id.toString());");
	assert js.ok;
	assert js.value.contains("instanceof NativeNode");
}
