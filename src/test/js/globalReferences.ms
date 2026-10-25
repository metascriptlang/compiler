import { compileToJS } from "../helpers";

test "a typed array the compiler emits is read through globalThis" {
	const js = compileToJS("const a: float32[2] = [1.5, 2.5];\nconsole.log(a[1]);\n");
	assert js.ok;
	assert js.value.contains("new globalThis.Float32Array(");
	assert !js.value.contains("new Float32Array(");
}

test "an integer conversion reads BigInt and Math through globalThis" {
	const js = compileToJS("let f = 3.9; const a = f as int64;");
	assert js.ok;
	assert js.value.contains("globalThis.BigInt(globalThis.Math.trunc(");
}

test "a float32 rounding reads Math through globalThis" {
	const js = compileToJS("let n: number = 2.5;\nconst c = n as float32;\nconsole.log(c);\n");
	assert js.ok;
	assert js.value.contains("globalThis.Math.fround(");
}

test "a binding spelled globalThis is renamed" {
	const js = compileToJS("function f(): int32 { const globalThis = 1; return globalThis; }\nconsole.log(f());\n");
	assert js.ok;
	assert js.value.contains("const $globalThis = 1");
}
