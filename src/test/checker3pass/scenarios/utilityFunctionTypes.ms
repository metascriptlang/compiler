import { checkOnly } from "../helpers";

function errorsOf(body: string): string {
	return checkOnly("type Fn = (a: int32, b: string) => string;\n" + body).errors.join("\n");
}

test "ReturnType and Parameters read a function type written out or named by an alias" {
	assert errorsOf("const r: ReturnType<Fn> = \"x\";\nconst p: Parameters<Fn> = [1, \"s\"];\nconst v: ReturnType<() => int32> = 3;\n") == "";
	const wrongReturn = errorsOf("const r: ReturnType<Fn> = 5;\n");
	assert wrongReturn.contains("not assignable to type 'string'"), wrongReturn;
	const wrongParams = errorsOf("const p: Parameters<Fn> = [\"s\", 1];\n");
	assert wrongParams.contains("not assignable"), wrongParams;
}

test "ReturnType and Parameters refuse a non-function, a type parameter and a rest or optional parameter" {
	const plain = errorsOf("const r: ReturnType<int32> = 1;\n");
	assert plain.contains("type 'int32' does not satisfy the constraint '(...args: any) => any' of ReturnType"), plain;
	const generic = errorsOf("function f<F>(x: ReturnType<F>): int32 { return 1; }\n");
	assert generic.contains("over a type parameter is not supported"), generic;
	const optional = errorsOf("const p: Parameters<(a: int32, b?: string) => void> = [1];\n");
	assert optional.contains("not supported for a function with a rest or optional parameter"), optional;
}

test "Awaited unwraps a promise, leaves another type alone and distributes over a union" {
	assert errorsOf("const a: Awaited<Promise<int32>> = 1;\nconst b: Awaited<string> = \"s\";\nconst c: Awaited<Promise<int32> | string> = \"y\";\nconst d: Awaited<Promise<int32> | string> = 4;\n") == "";
	const notPromise = errorsOf("const a: Awaited<Promise<int32>> = \"s\";\n");
	assert notPromise.contains("not assignable to type 'int32'"), notPromise;
	const leftAlone = errorsOf("const b: Awaited<string> = 5;\n");
	assert leftAlone.contains("not assignable to type 'string'"), leftAlone;
}
