import { compileToC, compileToJSWithStd } from "../helpers";
import { errorCount, hasError } from "./helpers";

function ok(body: string): boolean {
	return compileToC(body).ok && compileToJSWithStd(body).ok;
}

const u64max = "const u: uint64 = 18446744073709551615;\n";

test "numeric constants: a float never becomes an integer implicitly" {
	assert hasError("const i: int32 = 3.0;\n", "takes the float 3.0, and a float never becomes an integer implicitly — write 3, or an explicit 'as int32'");
	assert hasError("const K = 3.0;\nconst i: int32 = K;\n", "takes the float 3.0, and a float never becomes an integer implicitly");
	assert hasError("const j: uint8 = 200.0;\n", "write 200, or an explicit 'as uint8'");
	assert hasError("function f(v: int32): int32 { return v; }\nf(2.0);\n", "in 'f' arg 0 takes the float 2.0");
	assert ok("const i = 3.0 as int32;\nconst K = 3;\nconst j: int32 = K;\nconst b: uint8 = 200;\nconsole.log(i, j, b);\n");
}

test "numeric constants: a fractional constant is refused naming the value" {
	assert hasError("const K = 3.5;\nconst i: int32 = K;\n", "drops the fractional part of 3.5");
	assert hasError("const i: int32 = 3.5;\n", "drops the fractional part of 3.5");
}

test "numeric constants: an out-of-range float constant names the range" {
	assert hasError("const K = 300.0;\nconst b: uint8 = K;\n", "300.0 is outside [0, 255]");
	assert hasError("const b: int8 = -200.0;\n", "-200.0 is outside [-128, 127]");
}

test "numeric constants: a typed constant keeps its declared type" {
	assert hasError("const MAX: int64 = 100;\nconst n: int32 = MAX;\n", "'MAX' is declared int64, so its type decides, not its value 100; write an explicit 'as int32', or declare 'MAX' without a type");
	assert hasError("const MAX: int64 = 100;\nconst x: number = MAX;\n", "'MAX' is declared int64");
	assert hasError("const u: uint64 = 9223372036854775808;\nconst n: number = u;\n", "'u' is declared uint64, so its type decides, not its value 9223372036854775808");
	assert ok("const MAX = 100;\nconst n: int32 = MAX;\nconst b: uint8 = MAX;\nconst x: number = MAX;\nconsole.log(n, b, x);\n");
}

test "numeric constants: an untyped integer constant flows into a float slot that holds it" {
	assert ok("const L = 100;\nconst f: float32 = L;\nconst n: number = L;\nfunction t(x: float32): float32 { return x; }\nconsole.log(f, n, t(L), t(16777216));\n");
	assert ok("const i = -9223372036854775808;\nconst n: number = i;\nconsole.log(n);\n");
	assert ok("const p = 4611686018427387904;\nconst q = -9007199254740992;\nconst n: number = p;\nconst m: number = q;\nconsole.log(n, m);\n");
}

test "numeric constants: an untyped float constant goes into a float32 slot as a float literal does" {
	assert errorCount("const K = 0.1;\nconst f: float32 = K;\n") == 0;
	assert errorCount("const f: float32 = 1.0 / 60.0;\n") == 0;
	assert errorCount("const K = 0.1;\nconst A = K;\nfunction t(x: float32): float32 { return A; }\nconst r = t(K);\n") == 0;
	assert errorCount("const K = 0.1;\nconst C = 3;\nconst m: float32 | null = K;\nconst n: float32 | null = C;\nconst s: float32 | string = K;\nconst b: int8 | string = C;\n") == 0;
	assert ok("const K = 0.1;\nstruct P { w: float32; }\nconst p: P = { w: K };\nconst xs: float32[] = [K, 1.0 / 3.0];\nfunction m(v: float32 | null): float32 { return v ?? 0; }\nconsole.log(p.w, xs[1], m(K));\n");
}

test "numeric constants: an untyped constant beside a float32 operand is float32, as a literal is" {
	assert errorCount("const K = 0.1;\nconst C = 3;\nconst W = 70000;\nlet x: float32 = 3;\nconst a: float32 = x * K;\nconst b: float32 = K * x;\nconst c: float32 = x * C;\nconst d: float32 = x * W;\nx *= K;\n") == 0;
	assert hasError("const L = 16777217;\nlet x: float32 = 3;\nconst r: float32 = x + L;\n", "may lose precision");
	assert hasError("const H = 1e39;\nlet x: float32 = 3;\nconst r = x * H;\n", "number out of range: '1e+39' is outside the float32 range");
	assert hasError("const K: number = 0.1;\nlet x: float32 = 3;\nconst r: float32 = x * K;\n", "may lose precision");
}

test "numeric constants: a float out of the float32 range is refused, literal or constant" {
	assert hasError("const K = 1e39;\nconst f: float32 = K;\n", "1e+39 is outside the float32 range");
	assert hasError("const f: float32 = 1e39;\n", "number out of range: '1e+39' is outside the float32 range (±3.4028235e38) — float32 would hold Infinity");
	assert hasError("const f: float32 = -1e39;\n", "number out of range: '1e+39'");
	assert hasError("const f: float32 | string = 1e39;\n", "number out of range: '1e+39'");
	assert hasError("let x: float32 = 3;\nconst r: float32 = x * 1e39;\n", "number out of range: '1e+39'");
	assert hasError("const f: float32 = 3.4028235677973366e38;\n", "is outside the float32 range");
	assert errorCount("const f: float32 = 3.4028235677973362e38;\nconst g: float32 = 1e-50;\nconst K = 1e-50;\nconst h: float32 = K;\n") == 0;
}

test "numeric constants: an integer a float cannot hold is refused naming the mantissa" {
	assert hasError("const L = 16777217;\nconst f: float32 = L;\n", "cannot hold 16777217 exactly (float32 has a 24-bit mantissa)");
	assert hasError("const K: int64 = 9007199254740993;\nconst n: number = K;\n", "cannot hold 9007199254740993 exactly (a double has a 53-bit mantissa)");
	assert hasError("const f: float32 = 16777217;\n", "cannot hold 16777217 exactly (float32 has a 24-bit mantissa)");
	assert hasError("const n: number = 9007199254740993;\n", "cannot hold 9007199254740993 exactly (a double has a 53-bit mantissa)");
	assert hasError("const f: float32 = -16777217;\n", "cannot hold -16777217 exactly");
	assert hasError("function t(x: float32): float32 { return x; }\nt(16777217);\n", "in 't' arg 0 cannot hold 16777217 exactly");
	assert ok("const f = 16777217 as float32;\nconst n = 9007199254740993 as number;\nconsole.log(f, n);\n");
}

test "numeric constants: a uint64 past 2^63 that a float cannot hold is refused at every slot" {
	const says = "cannot hold 18446744073709551615 exactly";
	assert hasError(u64max + "const n: number = u;\n", says + " (a double has a 53-bit mantissa)");
	assert hasError(u64max + "const d: float64 = u;\n", says + " (a double has a 53-bit mantissa)");
	assert hasError(u64max + "const f: float32 = u;\n", says + " (float32 has a 24-bit mantissa)");
	assert hasError(u64max + "let n: number = 0;\nn = u;\n", says);
	assert hasError(u64max + "function f(): number { return u; }\n", says);
	assert hasError(u64max + "const xs: number[] = [u];\n", says);
}

test "numeric constants: a float-typed constant is read as a float whatever its spelling" {
	assert hasError("const K: number = 5;\nconst i: int32 = K;\n", "takes the float 5.0");
	assert hasError("const F: float64 = 7.0;\nconst b: uint8 = F;\n", "takes the float 7.0");
	assert hasError("const K: number = 300;\nconst b: uint8 = K;\n", "300.0 is outside [0, 255]");
}

test "numeric constants: an integer refusal names the value only when the value is outside" {
	assert hasError("const K: uint32 = 4294967295;\nconst i: int32 = K;\n", "4294967295 is outside [-2147483648, 2147483647]");
	assert hasError(u64max + "const i: int64 = u;\n", "18446744073709551615 is outside [-9223372036854775808, 9223372036854775807]");
	assert hasError("const K: uint64 = 5;\nconst i: int32 = K;\n", "may exceed the target's maximum");
}

test "numeric constants: a float constant names what a narrower slot loses" {
	assert hasError("const K: number = 1e300;\nconst f: float32 = K;\n", "is outside the float32 range");
	assert hasError("const K: number = 0.1;\nconst f: float32 = K;\n", "'K' is declared number, so its type decides, not its value 0.1");
	assert hasError("const K: number = 9223372036854775807.0;\nconst i: int64 = K;\n", "9223372036854776000.0 is outside [-9223372036854775808, 9223372036854775807]");
	assert hasError("const K: number = -0.0;\nconst i: int32 = K;\n", "a float never becomes an integer implicitly");
}

test "numeric constants: a runtime value keeps the general wording" {
	assert hasError("function f(v: number): int32 { return v; }\nconst r = f(3.5);\n", "may drop a fractional part or fall outside its range");
	assert errorCount("const K = 3;\nconst i: int32 = K;\n") == 0;
}

test "numeric constants: a float constant outside an integer type is refused at its 'as', signed and unsigned alike" {
	assert hasError("const a = 128.0 as int8;\n", "cannot convert 128.0 to int8");
	assert hasError("const a = 128.9 as int8;\n", "cannot convert 128.9 to int8");
	assert hasError("const a = (-129.0) as int8;\n", "cannot convert -129.0 to int8");
	assert hasError("const a = 2147483648.0 as int32;\n", "cannot convert 2147483648.0 to int32");
	assert hasError("const a = 9223372036854775808.0 as int64;\n", "cannot convert 9223372036854776000.0 to int64");
	assert hasError("const a = 256.0 as uint8;\n", "cannot convert 256.0 to uint8");
	assert hasError("const a = (-1.0) as uint32;\n", "cannot convert -1.0 to uint32");
	assert hasError("const a = 18446744073709551616.0 as uint64;\n", "cannot convert 18446744073709552000.0 to uint64");
	assert hasError("const K: float64 = 65536.0;\nconst a = K as uint16;\n", "cannot convert 65536.0 to uint16");
	assert hasError("const K: number = 300;\nconst a = K as uint8;\n", "cannot convert 300.0 to uint8");
	assert hasError("const K: number = -300;\nfunction f(): int8 { return K as int8; }\n", "cannot convert -300.0 to int8");
	assert hasError("const F: float32 = 2147483647.5 as float32;\nconst a = F as int32;\n", "cannot convert 2147483648.0 to int32");
}

test "numeric constants: NaN and the infinities convert to no integer type" {
	assert hasError("const K: float64 = 1e308 * 10.0;\nconst a = K as int32;\n", "cannot convert Infinity to int32");
	assert hasError("const K: float64 = -1e308 * 10.0;\nconst a = K as uint8;\n", "cannot convert -Infinity to uint8");
	assert hasError("const K: float64 = 1e308 * 10.0 - 1e308 * 10.0;\nconst a = K as uint64;\n", "cannot convert NaN to uint64");
}

test "numeric constants: a float constant inside an integer type truncates toward zero" {
	assert ok("const a = 127.9 as int8;\nconst b = (-128.9) as int8;\nconst c = 255.9 as uint8;\nconst d = (-0.9) as uint32;\nconst e = 18446744073709549568.0 as uint64;\nconst f = (-9223372036854775808.0) as int64;\nconsole.log(a, b, c, d, e, f);\n");
	assert errorCount("const K: number = 255;\nconst a = K as uint8;\n") == 0;
}

test "numeric constants: a constant into char must fit 0..255, at a slot and at its 'as'" {
	assert hasError("const b: char = 300;\n", "cannot convert 300 to char");
	assert hasError("const b: char = -1;\n", "cannot convert -1 to char");
	assert hasError("const K = 1000;\nconst b: char = K;\n", "cannot convert 1000 to char");
	assert hasError("function f(c: char): char { return c; }\nf(256);\n", "cannot convert 256 to char");
	assert hasError("const b: char = 65.0;\n", "takes the float 65.0, and a float never becomes an integer implicitly");
	assert hasError("const a = 300 as char;\n", "cannot convert 300 to char");
	assert hasError("const a = (-1) as char;\n", "cannot convert -1 to char");
	assert hasError("const K = 1000;\nconst a = K as char;\n", "cannot convert 1000 to char");
	assert hasError("const a = 256.0 as char;\n", "cannot convert 256.0 to char");
	assert hasError("const a = (-1.0) as char;\n", "cannot convert -1.0 to char");
	assert hasError("const K: float64 = 1e308 * 10.0 - 1e308 * 10.0;\nconst a = K as char;\n", "cannot convert NaN to char");
	assert hasError("const a = (200 as char) as int8;\n", "cannot convert 200 to int8");
}

test "numeric constants: a constant inside 0..255 becomes a char with as char" {
	assert ok("const a: char = 65 as char;\nconst b: char = \"A\".code as char;\nconst c = 255 as char;\nconst d = 200.9 as char;\nconst e = (200 as char) as int16;\nconst K = 97;\nconst f: char = K as char;\nconsole.log(a, b, c, d, e, f);\n");
}
