import { compileToJS } from "../helpers";

test "JS: a pattern without a placeholder is emitted, not called by name" {
	const js = compileToJS("extern function answer(): int32 from \"(40 + 2)\";\nconst v = answer();");
	assert js.ok;
	assert js.value.contains("(40 + 2)");
	assert !js.value.contains("answer()");
}

test "JS: a placeholder-free pattern returning a string or an extern class is emitted" {
	const js = compileToJS("extern class Box { size: int32; }\n"
		+ "extern function greeting(): string from \"('h' + 'i')\";\n"
		+ "extern function makeBox(): Box from \"({ size: 3 })\";\n"
		+ "const g = greeting();\nconst n = makeBox().size;");
	assert js.ok;
	assert js.value.contains("('h' + 'i')");
	assert js.value.contains("({ size: 3 })");
	assert !js.value.contains("makeBox()");
}

test "JS: a quoted '#' counts as a placeholder and the surplus is refused at the declaration" {
	const js = compileToJS("extern function tagged(s: string): string from \"('#' + #)\";\nconst t = tagged(\"x\");");
	assert !js.ok;
	assert js.error.contains("has 2 '#' placeholder(s) but the function takes 1 parameter(s)");
	assert js.error.contains("'\\\\x23'");
}

test "JS: a pattern with fewer placeholders than parameters is refused" {
	const js = compileToJS("extern function first(a: int32, b: int32): int32 from \"(#)\";\nconst f = first(1, 2);");
	assert !js.ok;
	assert js.error.contains("has 1 '#' placeholder(s) but the function takes 2 parameter(s)");
}

test "JS: a placeholder-free pattern on a function with a parameter is refused" {
	const js = compileToJS("extern function drop(a: int32): int32 from \"(40 + 2)\";\nconst d = drop(1);");
	assert !js.ok;
	assert js.error.contains("has 0 '#' placeholder(s) but the function takes 1 parameter(s)");
}

test "JS: the escaped literal '#' and a splat keep their counts" {
	const js = compileToJS("extern function hashAt(s: string): int32 from \"(#).indexOf('\\\\x23')\";\n"
		+ "extern function listed(a: int32, b: int32, c: int32): string from \"JSON.stringify([#, @])\";\n"
		+ "const h = hashAt(\"a#b\");\nconst l = listed(1, 2, 3);");
	assert js.ok;
	assert js.value.contains(".indexOf('\\x23')");
	assert js.value.contains("JSON.stringify([1, 2, 3])");
}
