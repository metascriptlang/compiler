// Route 17: try-expr Result type propagation
//
// When `try f()` is used inside a function returning Result<void, E>,
// the early-return error path must construct Result<void, E>, not
// propagate the inner Result<T, E> directly.

import { compileToC } from "../helpers";
import { errorCount } from "./helpers";

test "simple Result fn compiles" {
	const src = "function foo(): Result<number, string> {\nreturn Result.ok(42);\n}\nconst r = foo();";
	const result = compileToC(src);
	if (!result.ok) { console.log("ERROR-simple: " + result.error); }
	assert result.ok;
}

test "try with simple Result fn compiles" {
	const src = "function bar(): Result<number, string> {\nreturn Result.ok(42);\n}\nfunction foo(): Result<number, string> {\nconst x = try bar();\nreturn Result.ok(x + 1);\n}\nconst r = foo();";
	const result = compileToC(src);
	if (!result.ok) { console.log("ERROR-try-simple: " + result.error); }
	assert result.ok;
}

test "JSON.parse without try compiles" {
	const src = "interface Person { name: string; value: number; }\nconst r = JSON.parse<Person>(\"{}\");\nif (r.ok) { console.log(r.value.name); }";
	const result = compileToC(src);
	if (!result.ok) { console.log("ERROR-json-no-try: " + result.error); }
	assert result.ok;
}

test "try inside Result<void, string> fn compiles" {
	const src = "interface Person { name: string; value: number; }\nfunction hello(): Result<void, string> {\nconst me = try JSON.parse<Person>(\"{}\");\nconsole.log(me.name);\nreturn Result.ok(undefined);\n}\nhello();";
	const result = compileToC(src);
	if (!result.ok) { console.log("ERROR-with-return: " + result.error); }
	assert result.ok;
}

test "try void Result fn without explicit return" {
	const src = "interface Person { name: string; value: number; }\nfunction hello(): Result<void, string> {\nconst me = try JSON.parse<Person>(\"{}\");\nconsole.log(me.name);\n}\nhello();";
	const result = compileToC(src);
	if (!result.ok) { console.log("ERROR-no-return: " + result.error); }
	assert result.ok;
}

test "try-catch fallback at root level compiles" {
	const src = "interface Person { name: string; value: number; }\nconst me = try JSON.parse<Person>(\"{}\") catch { name: \"CL\", value: 99 };\nconsole.log(me.name);";
	const result = compileToC(src);
	assert result.ok;
}

test "try inside Result<number, string> fn compiles" {
	const src = "function compute(): Result<number, string> {\nconst x = try JSON.parse<number>(\"42\");\nreturn Result.ok(x + 1);\n}\nconst r = compute();";
	const result = compileToC(src);
	assert result.ok;
}

test "try in nested functions with different Result types" {
	const src = "interface Person { name: string; value: number; }\nfunction inner(): Result<number, string> {\nconst p = try JSON.parse<Person>(\"{}\");\nreturn Result.ok(p.value);\n}\nfunction outer(): Result<void, string> {\nconst n = try inner();\nconsole.log(n);\nreturn Result.ok(undefined);\n}\nouter();";
	const result = compileToC(src);
	if (!result.ok) { console.log("ERROR-nested: " + result.error); }
	assert result.ok;
}
