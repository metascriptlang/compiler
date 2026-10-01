import { compileToC, compileToJS } from "../helpers";
import { errorCount, hasError } from "./helpers";

function ok(body: string): boolean {
	return compileToC(body).ok && compileToJS(body).ok;
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
	assert hasError("const K = 0.1;\nconst f: float32 = K;\n", "cannot hold 0.1 exactly (float32 has a 24-bit mantissa)");
	assert hasError("const K: number = 9223372036854775807.0;\nconst i: int64 = K;\n", "9223372036854776000.0 is outside [-9223372036854775808, 9223372036854775807]");
	assert hasError("const K: number = -0.0;\nconst i: int32 = K;\n", "a float never becomes an integer implicitly");
}

test "numeric constants: a runtime value keeps the general wording" {
	assert hasError("function f(v: number): int32 { return v; }\nconst r = f(3.5);\n", "may drop a fractional part or fall outside its range");
	assert errorCount("const K = 3;\nconst i: int32 = K;\n") == 0;
}
