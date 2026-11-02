import { compileToJSBare } from "../helpers";

test "a sized array of a primitive element is allocated then filled" {
	const result = compileToJSBare("function f(n: int32): uint8[] { return new Array<uint8>(n); }");
	assert result.ok;
	assert result.value.contains("new globalThis.Array(msChkCount");
	assert result.value.contains("(n)).fill(0)");
	assert !result.value.contains("() => (0)");
}

test "a sized array of booleans and strings fills the literal zero" {
	const bools = compileToJSBare("function f(n: int32): boolean[] { return new Array<boolean>(n); }");
	assert bools.ok;
	assert bools.value.contains(").fill(false)");
	const texts = compileToJSBare("function f(n: int32): string[] { return new Array<string>(n); }");
	assert texts.ok;
	assert texts.value.contains(").fill(\"\")");
}

test "a sized array of structs builds one zero value per slot" {
	const result = compileToJSBare("struct P { x: int32; y: int32; } function f(n: int32): P[] { return new Array<P>(n); }");
	assert result.ok;
	assert result.value.contains("}, () => ({ x: 0, y: 0 }))");
}
