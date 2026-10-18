import { compileToJSWithStd } from "../helpers";

function defs(code: string, name: string): int32 {
	const r = compileToJSWithStd(code);
	if (!r.ok) return -1;
	return r.value.split("function " + name + "_").length - 1;
}

test "number and float64 spell one instance" {
	assert defs("function id<T>(x: T): T { return x; }\nconsole.log(id<float64>(1.5), id(2.5 as number));\n", "id") == 1;
	assert defs("function id<T>(x: T): T { return x; }\nconsole.log(id<number[]>([1.5]), id<float64[]>([2.5]));\n", "id") == 1;
	assert defs("function id<T>(x: T): T { return x; }\nconsole.log(id<Map<number, int32>>(new Map<number, int32>()), id<Map<float64, int32>>(new Map<float64, int32>()));\n", "id") == 1;
}
