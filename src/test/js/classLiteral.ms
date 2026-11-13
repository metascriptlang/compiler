import { compileToJS } from "../helpers";

const header = "class P { x: int32; y: int32; tag: string; }\n";

test "a class-typed literal stores each field into an instance of its class" {
	const result = compileToJS(header + "function f(a: int32): P { return { x: a, y: 2, tag: \"t\" }; }");
	assert result.ok;
	assert result.value.contains("(($o) => ($o.x = a, $o.y = 2, $o.tag = \"t\", $o))(globalThis.Object.create(");
	assert !result.value.contains("Object.assign");
}

test "a field the literal omits is stored as its zero" {
	const result = compileToJS(header + "function f(a: int32): P { return { x: a }; }");
	assert result.ok;
	assert result.value.contains("$o.x = a, $o.y = 0, $o.tag = \"\", $o))");
}

test "a value that spells the instance's name moves the name aside" {
	const result = compileToJS(header + "function f($o: int32): P { return { x: $o, y: 1, tag: \"\" }; }");
	assert result.ok;
	assert result.value.contains("(($o1) => ($o1.x = $o, ");
}

test "a literal whose value awaits keeps the copy into the instance" {
	const result = compileToJS(header + "async function g(): Promise<int32> { return 1; }\nasync function f(): Promise<P> { return { x: await g(), y: 1, tag: \"\" }; }");
	assert result.ok;
	assert result.value.contains("globalThis.Object.assign(globalThis.Object.create(");
}
