// E2E: Expressions → C output
// Tests operator codegen: ternary, unary, logical, comparison.

import { compileToC } from "../helpers";


test "E2E C: ternary expression" {
	const src = "function f(n: number): number { return (n > 0) ? 1 : -1; }\nconst r = f(5);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("?");
	assert c.value.contains(":");
}

test "E2E C: unary not" {
	const src = "function f(b: boolean): boolean { return !b; }\nconst r = f(true);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("!");
}

test "E2E C: unary negation" {
	const src = "function f(x: number): number { return -x; }\nconst r = f(5);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("-");
}

test "E2E C: logical AND" {
	const src = "function f(a: boolean, b: boolean): boolean { return a && b; }\nconst r = f(true, false);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("&&");
}

test "E2E C: logical OR" {
	const src = "function f(a: boolean, b: boolean): boolean { return a || b; }\nconst r = f(true, false);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("||");
}

test "E2E C: comparison operators" {
	const src = "function inRange(x: number): boolean { return x >= 0 && x <= 100; }\nconst r = inRange(50);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains(">=");
	assert c.value.contains("<=");
}

// bug038 — integer-valued float literals must emit with `.0` suffix so C
// uses float division (IEEE 754) not integer division (UB → trap).
test "E2E C: float literal 0.0 emits with decimal point" {
	const src = "function f(): number { const x: number = 0.0; return x; }";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("0.0");
}

test "E2E C: 0.0 / 0.0 emits as float division not integer" {
	const src = "function f(): number { const x: number = 0.0 / 0.0; return x; }";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("0.0 / 0.0");
	assert !c.value.contains("(0 / 0)");
}

test "E2E C: 1.0 / 0.0 emits as float division" {
	const src = "function f(): number { const x: number = 1.0 / 0.0; return x; }";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("1.0 / 0.0");
	assert !c.value.contains("(1 / 0)");
}
