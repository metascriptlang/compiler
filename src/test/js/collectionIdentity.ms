import { compileToJSWithStd } from "../helpers";

// A collection constructor is the std declaration the symbol names (its @builtin tag), not any
// extern class that spells the same name.

test "a std Map keyed by a struct is built through the value-key runtime" {
	const js = compileToJSWithStd("struct P { x: int32; y: int32; }\nconst m = new Map<P, int32>();\nconsole.log(m.size);\n");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("msValueKeys()");
}

test "an extern class named Map keyed by a struct is a plain constructor call" {
	const js = compileToJSWithStd("struct P { x: int32; y: int32; }\nextern class Map<K, V> { size: number; }\nconst m = new Map<P, int32>();\nconsole.log(m.size);\n");
	assert js.ok, js.ok ? "" : js.error;
	assert !js.value.contains("msValueKeys()");
}
