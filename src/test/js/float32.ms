import { compileToJS } from "../helpers";

test "float32: JS rounds every float32 the program produces" {
	const js = compileToJS("let a: float32 = 0.1;\nlet n: number = 2.5;\nconst b: float32 = a * a;\nconst c = n as float32;\nconsole.log(a, b, c);\n");
	assert js.ok;
	assert js.value.indexOf("0.10000000149011612") >= 0;
	assert js.value.indexOf("Math.fround(") >= 0;
}

test "float32: a 64-bit integer becomes float32 with one rounding" {
	const js = compileToJS("let big: int64 = 1152921573326323713;\nconsole.log(big as float32);\n");
	assert js.ok;
	assert js.value.indexOf("msInt64ToFloat32") >= 0;
}
