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

test "JS: '$1' in a from name is the declared name, so a bare '$1' names the global" {
	const js = compileToJS("extern function parseInt(s: string): int32 from \"$1\";\nconst n = parseInt(\"42\");");
	assert js.ok;
	assert js.value.contains("parseInt(\"42\")");
}

test "JS: '$1' inside a pattern is the declared name and '$$' a literal '$'" {
	const js = compileToJS("extern function abs(x: int32): int32 from \"Math.$1(#)\";\n"
		+ "extern function priced(x: int32): string from \"(# + '$$1')\";\n"
		+ "const a = abs(-3);\nconst p = priced(4);");
	assert js.ok;
	assert js.value.contains("Math.abs(");
	assert js.value.contains("+ '$1')");
}

test "JS: an unknown '$' sequence in a from name is refused at the declaration" {
	const js = compileToJS("extern function two(x: int32): int32 from \"$2(#)\";\nconst t = two(1);");
	assert !js.ok;
	assert js.error.contains("extern function 'two': invalid from name \"$2(#)\"");
}

test "JS: \\x1f emits a literal '#' inside and outside a JS string" {
	const js = compileToJS("extern class Box { size: int32; }\n"
		+ "extern function tagged(s: string): string from \"('\\x1f' + #)\";\n"
		+ "extern function makeBox(): Box from \"({ size: 3 })\";\n"
		+ "extern function secret(b: Box): int32 from \"#.\\x1fsize\";\n"
		+ "const t = tagged(\"x\");\nconst s = secret(makeBox());");
	assert js.ok;
	assert js.value.contains("('#' + ");
	assert js.value.contains(".#size");
}

test "JS: \\x1d emits a literal '@' inside and outside a JS string" {
	const js = compileToJS("extern function mailed(s: string): string from \"(# + '\\x1dhost')\";\n"
		+ "extern function noted(x: int32): int32 from \"(# /*\\x1d*/)\";\n"
		+ "const m = mailed(\"me\");\nconst n = noted(1);");
	assert js.ok;
	assert js.value.contains("+ '@host')");
	assert js.value.contains("/*@*/)");
}

test "JS: a '#' after '@' is refused, since '@' has taken every remaining argument" {
	const js = compileToJS("extern function joined(a: int32, b: int32): string from \"[@].concat([#]).join('/')\";\nconst j = joined(1, 2);");
	assert !js.ok;
	assert js.error.contains("extern function 'joined': in the pattern \"[@].concat([#]).join('/')\" a '#' follows '@'");
}

test "JS: '@' alone, or after fewer '#' than parameters, stays accepted" {
	const js = compileToJS("extern function biggest(a: int32, b: int32): int32 from \"Math.max(@)\";\n"
		+ "extern function clampTo(x: int32, lo: int32, hi: int32): int32 from \"Math.min(Math.max(#, @))\";\n"
		+ "const b = biggest(1, 2);\nconst c = clampTo(5, 1, 9);");
	assert js.ok;
	assert js.value.contains("Math.max(1, 2)");
	assert js.value.contains("Math.min(Math.max(5, 1, 9))");
}

test "JS: a plain from name is called as written, a dotted path included" {
	const js = compileToJS("extern function myAbs(x: number): number from \"Math.abs\";\nconst a = myAbs(-3);");
	assert js.ok;
	assert js.value.contains("Math.abs(");
	assert !js.value.contains("myAbs(");
}

test "JS: a plain from name naming a bare global is called by that name" {
	const js = compileToJS("extern function toInt(s: string): int32 from \"parseInt\";\nconst n = toInt(\"42\");");
	assert js.ok;
	assert js.value.contains("parseInt(\"42\")");
	assert !js.value.contains("toInt(");
}

test "JS: a plain from name on an extern const is read by that name" {
	const js = compileToJS("extern const biggest: number from \"Number.MAX_SAFE_INTEGER\";\nconst b = biggest + 1;");
	assert js.ok;
	assert js.value.contains("Number.MAX_SAFE_INTEGER + 1");
}
