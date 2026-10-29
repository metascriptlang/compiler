import { compileToC, compileToJS, raiserErrors, refusedOnEveryBackend } from "../helpers";

function acceptedOnEveryBackend(source: string): string {
	const c = compileToC(source);
	if (!c.ok) return "C: " + c.error;
	const js = compileToJS(source);
	if (!js.ok) return "JS: " + js.error;
	return raiserErrors(source);
}

test "routineCast: a named function converts to no number, naming the function" {
	const integer = refusedOnEveryBackend("function seven(): number { return 7; }\nconst z = seven as int32;\nconsole.log(z);", "'seven' is a function, not a int32; call it (seven())");
	assert integer == "", integer;
	const float = refusedOnEveryBackend("function seven(): number { return 7; }\nconst z = seven as float32;\nconsole.log(z);", "'seven' is a function, not a float32");
	assert float == "", float;
}

test "routineCast: a method value and a closure convert to no number" {
	const method = refusedOnEveryBackend("class Box { m(): int32 { return 1; } }\nconst obj = new Box();\nconst z = obj.m as int64;\nconsole.log(z);", "'obj.m' is a function, not a int64");
	assert method == "", method;
	const closure = refusedOnEveryBackend("let n: int32 = 2;\nconst f = (): int32 => n + 1;\nconst z = f as int32;\nconsole.log(z);", "'f' is a function, not a int32");
	assert closure == "", closure;
	const literal = refusedOnEveryBackend("const z = ((): int32 => 1) as float64;\nconsole.log(z);", "a function is not a float64; call it");
	assert literal == "", literal;
}

test "routineCast: a function converts to no boolean or string, and a number to no function" {
	const truth = refusedOnEveryBackend("function seven(): number { return 7; }\nconst z = seven as boolean;\nconsole.log(z);", "'seven' is a function, not a boolean");
	assert truth == "", truth;
	const text = refusedOnEveryBackend("function seven(): number { return 7; }\nconst z = seven as string;\nconsole.log(z);", "'seven' is a function, not a string");
	assert text == "", text;
	const routine = refusedOnEveryBackend("const k: int32 = 3;\nconst f = k as (() => int32);\nconsole.log(f());", "only a function converts to a function type");
	assert routine == "", routine;
}

test "routineCast: a function still converts to its own and a nullable function type" {
	const same = acceptedOnEveryBackend("function seven(): int32 { return 7; }\nconst f = seven as (() => int32);\nconsole.log(f());");
	assert same == "", same;
	const nullable = acceptedOnEveryBackend("function seven(): int32 { return 7; }\nconst f = seven as (() => int32) | null;\nconsole.log(f != null);");
	assert nullable == "", nullable;
	const none = acceptedOnEveryBackend("const f = null as (() => int32) | null;\nconsole.log(f == null);");
	assert none == "", none;
}
