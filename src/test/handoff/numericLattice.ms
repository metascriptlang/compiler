import { compileToC, compileToJS } from "../helpers";
import { errorCount, hasError } from "./helpers";

function ok(body: string): boolean {
	return compileToC(body).ok && compileToJS(body).ok;
}

function errorOf(body: string): string {
	const r = compileToC(body);
	return r.ok ? "" : r.error;
}

const id = "let id: int64 = 9007199254740993;\n";

const total = "let total: int64 = 9007199254740993;\nlet n: number = 0.5;\n";

test "numeric lattice: an unsigned integer widens into a signed slot whose range holds it" {
	assert ok("const u: uint8 = 3;\nconst i: int16 = u;\nconst j: int32 = u;\nconst k: int64 = u;\nconsole.log(i, j, k);\n");
	assert ok("const u: uint16 = 40000;\nconst i: int32 = u;\nconsole.log(i);\n");
	assert ok("const u: uint32 = 3000000000;\nconst i: int64 = u;\nconsole.log(i);\n");
}

test "numeric lattice: a contained unsigned argument takes the wider signed parameter" {
	assert ok("function t16(x: int16): int16 { return x; }\nconst u: uint8 = 7;\nconsole.log(t16(u));\n");
	assert ok("function ret(): int64 { const u: uint32 = 1; return u; }\nconsole.log(ret());\n");
}

test "numeric lattice: an overload takes the contained wider signed parameter" {
	assert ok("function ov(x: int32): string { return \"i\"; }\nfunction ov(x: string): string { return x; }\nconst u: uint8 = 2;\nconst s = ov(u);\nconsole.log(s);\n");
}

test "numeric lattice: an integer conversion that can change a value needs as" {
	assert errorCount("const u: uint8 = 3;\nconst i: int16 = u;\n") == 0;
	assert hasError("const n: int32 = -1;\nconst u: uint32 = n;\n", "-1 is outside [0, 4294967295]");
	assert hasError("const u: uint64 = 5;\nconst i: int64 = u;\n", "may exceed the target's maximum");
	assert hasError("const n: int32 = 300;\nconst b: int8 = n;\n", "300 is outside [-128, 127]");
}

test "numeric lattice: an integer the float's mantissa holds widens into it" {
	assert ok("const a: int16 = 300;\nconst f: float32 = a;\nconst g: float64 = a;\nconst n: number = a;\nconsole.log(f, g, n);\n");
	assert ok("const u: uint16 = 60000;\nconst f: float32 = u;\nconsole.log(f);\n");
	assert ok("const b: int32 = 16777216;\nconst n: number = b;\nconsole.log(n);\n");
	assert ok("const u: uint32 = 4000000000;\nconst n: number = u;\nconsole.log(n);\n");
}

test "numeric lattice: a float widens and aliases within the float family" {
	assert ok("const f: float32 = 0.5;\nconst d: float64 = f;\nconst n: number = f;\nconsole.log(d, n);\n");
	assert ok("const n: number = 0.5;\nconst d: float64 = n;\nconst m: number = d;\nconsole.log(d, m);\n");
}

test "numeric lattice: an integer too wide for the float's mantissa is refused" {
	assert hasError("const n: int32 = 16777217;\nconst f: float32 = n;\n", "cannot hold 16777217 exactly (float32 has a 24-bit mantissa)");
	assert hasError("const u: uint32 = 4294967295;\nconst f: float32 = u;\n", "cannot hold 4294967295 exactly (float32 has a 24-bit mantissa)");
	assert hasError("const b: int64 = 9007199254740993;\nconst n: number = b;\n", "cannot hold 9007199254740993 exactly (a double has a 53-bit mantissa)");
	assert hasError("const u: uint64 = 9007199254740993;\nconst f: float64 = u;\n", "cannot hold 9007199254740993 exactly (a double has a 53-bit mantissa)");
	assert hasError("function t(x: float32): float32 { return x; }\nconst n: int32 = 16777217;\nconst r = t(n);\n",
		"implicit int32 → float32 conversion in 't' arg 0 cannot hold 16777217 exactly (float32 has a 24-bit mantissa)");
}

test "numeric lattice: a float into an integer or a narrower float is refused" {
	assert hasError("const d: float64 = 0.1;\nconst f: float32 = d;\n", "may lose precision (float32 has a 24-bit mantissa) — 'd' is declared float64");
	assert hasError("const n: number = 0.1;\nconst f: float32 = n;\n", "may lose precision (float32 has a 24-bit mantissa) — 'n' is declared number");
	assert hasError("const d: float64 = 1.5;\nconst i: int32 = d;\n", "drops the fractional part of 1.5");
	assert hasError("const f: float32 = 1.5;\nconst i: int32 = f;\n", "drops the fractional part of 1.5");
}

test "numeric lattice: a literal and a fitting constant flow where a value is refused" {
	assert errorCount("const f: float32 = 0.5;\nconst i: int32 = 3;\nconst K = 3;\nconst j: int32 = K;\nconst U = 5;\nfunction t(x: float32): float32 { return x; }\nconsole.log(f, i, j, t(7), t(2.5), t(U));\n") == 0;
}

test "numeric lattice: a 64-bit integer argument into a number parameter is refused at every call form" {
	const says = "implicit int64 → number conversion in ";
	assert hasError(id + "function save(x: number): void {}\nsave(id);\n", says + "'save' arg 0 may lose integer precision above 2^53 — write an explicit 'as number'");
	assert hasError(id + "class C { f(x: number): void {} }\nnew C().f(id);\n", says + "'f' arg 0");
	assert hasError(id + "function ext(this s: string, x: number): void {}\n\"a\".ext(id);\n", says + "'ext' arg 0");
	assert hasError(id + "const m = new Map<string, number>();\nm.set(\"a\", id);\n", says + "'set' arg 1");
	assert hasError("let u: uint64 = 5;\nfunction g(x: float64): void {}\ng(u);\n", "implicit uint64 → float64 conversion in 'g' arg 0");
}

test "numeric lattice: a union slot names the numeric member it refuses" {
	assert hasError(id + "const u: number | string = id;\n", "implicit int64 → number conversion into 'number | string' may lose integer precision above 2^53");
}

test "numeric lattice: exact arguments flow" {
	assert ok("let a: int32 = 7;\nlet b: uint32 = 8;\nconst K = 9;\nfunction save(x: number): number { return x; }\nconsole.log(save(a), save(b), save(K));\n");
	assert errorCount(id + "function save(x: number): number { return x; }\nconst r = save(id as number);\n") == 0;
}

test "numeric lattice: an out argument must be exactly the out type" {
	assert hasError("function f(out r: number): void { r = 1.5; }\nlet x: int64 = 0;\nf(x);\n", "an out parameter of type number is written in place, so the variable must be number, not int64");
	assert hasError("function f(out r: int32): void { r = 7; }\nlet x: number = 0;\nf(x);\n", "the variable must be int32, not number");
	assert errorCount("function f(out r: number): void { r = 1.5; }\nlet x: number = 0;\nf(x);\nconsole.log(x);\n") == 0;
}

test "numeric lattice: a sink parameter keeps the lattice" {
	assert hasError("extern function takes(sink v: number): void from \"&abs\";\nlet x: int64 = 9007199254740993;\ntakes(x);\n", "implicit int64 → number conversion in 'takes' arg 0 may lose integer precision above 2^53");
}

test "numeric lattice: an overload no-match names the numeric reason" {
	const e = errorOf("function f(x: float32): string { return \"f\"; }\nfunction f(x: string): string { return x; }\nlet n: int32 = 5;\nconst s = f(n);\n");
	assert e.contains("first mismatch at position 1: expected 'float32', got 'int32'"), e;
	assert e.contains("may lose integer precision above 2^24; write an explicit 'as float32'"), e;
}

test "numeric lattice: a non-numeric overload mismatch stays plain" {
	const e = errorOf("function g(x: string): string { return x; }\nfunction g(x: boolean): string { return \"b\"; }\nlet n: int32 = 5;\nconst s = g(n);\n");
	assert e.contains("first mismatch at position 1: expected 'string', got 'int32'"), e;
	assert !e.contains("as float32"), e;
}

test "numeric lattice: a 64-bit integer beside a float in an operator is refused" {
	assert hasError(total + "const avg = total + n;\n", "operator '+' would convert the int64 operand to number implicitly, which may lose integer precision above 2^53 — write an explicit 'as number' on it");
	assert hasError(total + "const big = total > n;\n", "operator '>' would convert the int64 operand to number");
	assert hasError(total + "const same = n == total;\n", "operator '==' would convert the int64 operand to number");
	assert hasError(total + "n += total;\n", "operator '+=' would convert the int64 operand to number");
	assert hasError("let u: uint64 = 5;\nlet f: float64 = 1.5;\nconst r = u * f;\n", "operator '*' would convert the uint64 operand to float64");
}

test "numeric lattice: an exact integer or an explicit conversion mixes with a float" {
	assert ok("let i: int32 = 7;\nlet n: number = 0.5;\nconst r = i * n;\nconsole.log(r, i < n);\n");
	assert ok("let n: number = 0.5;\nconst r = n + 5000000000;\nconsole.log(r);\n");
	assert errorCount(total + "const avg = total as number + n;\n") == 0;
}

test "numeric lattice: a number goes into the one union member that holds it implicitly" {
	assert errorCount("let h: int16 = 7;\nconst c: int32 | string = h;\nfunction t(v: int32 | string): void {}\nt(h);\n") == 0;
	assert errorCount("let i: int32 = 3;\nconst a: number | string = i;\nlet f: float32 = 1.5;\nlet b: number | string = \"x\";\nb = f;\n") == 0;
	assert errorCount("let i: int32 = 3;\nconst a: int64 | number = i;\nfunction t(v: int64 | number): void {}\nt(i);\n") == 0;
	assert hasError("let s: int16 = 2;\nconst a: float32 | number = s;\n", "implicit int16 conversion into 'float32 | number' fits both float32 and number — write an explicit 'as float32' or 'as number'");
	assert hasError("let u: uint8 = 1;\nfunction t(v: int64 | uint32): void {}\nt(u);\n", "fits both int64 and uint32");
	assert hasError("let d: float64 = 0.1;\nconst f: float32 | string = d;\n", "may lose precision");
}

test "numeric lattice: a compound assignment converts its right operand as an assignment would" {
	assert hasError("let i: int64 = 5000000000;\nlet x: int32 = 3;\nx += i;\n", "implicit int64 → int32 conversion in '+=' narrows — write an explicit 'as int32'");
	assert hasError("let d: number = 0.1;\nlet x: float32 = 3;\nx *= d;\n", "implicit number → float32 conversion in '*=' may lose precision");
	assert hasError("let x: int32 = 3;\nx += 0.5;\n", "in '+=' drops the fractional part of 0.5");
	assert hasError("let x: int8 = 1;\nx += 300;\n", "in '+=' 300 is outside [-128, 127]");
	assert hasError("let x: int32 = 1;\nlet y: uint32 = 2;\nx -= y;\n", "in '-='");
	assert hasError("let total = 0;\nconst v: number = 1.5;\ntotal += v;\n", "implicit number → int32 conversion in '+=' may drop a fractional part or fall outside its range — 'total' is int32, inferred from its integer initializer; declare it 'total: number', or write an explicit 'as int32'");
	assert errorCount("let u: uint8 = 0;\nu -= 1;\nlet h: int64 = 5;\nh *= 33;\nlet s: int32 = 1;\nlet w: int16 = 2;\ns += w;\nlet f: float32 = 1;\nlet k: int16 = 3;\nf += k;\nlet n: number = 1;\nn += s;\nlet t = \"a\";\nt += 1;\n") == 0;
}
