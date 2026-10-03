// bug690 — a call to a @comptime function ran at run time
//
// Symptom:    `const PROGRAM: uint64 = digitSum("2222")` with `@comptime function digitSum`
//             emitted a runtime call, so `--os=solana` reported FREESTANDING E02; only a
//             `@comptime { }` block was evaluated while compiling.
// Root cause: `@comptime` on a function was a pass-through directive: no symbol flag, no
//             call-site evaluation.
// Fix:        the decorator sets SymbolFlag.CompileTime, and checkCallExpr evaluates a call to
//             such a function when every argument is a compile-time value, replacing the call
//             by its result (NIM-REF CT-32); any other argument is an error at the call.

import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

const LIB = `@comptime function digitSum(text: string): uint64 {
	let total: uint64 = 0;
	for (let i = 0; i < text.length; i++) { total = total * 58 + ((text.charCodeAt(i) - 49) as uint64); }
	return total;
}
`;

function cOf(body: string): string {
	const c = compileToCWithStd(LIB + body);
	return c.ok ? c.value : "error: " + c.error;
}

function mentions(c: string, name: string): int32 {
	return c.split(name).length - 1;
}

function callsLeft(c: string, name: string): int32 {
	return mentions(c, name) - mentions(cOf(`console.log(1);`), name);
}

test "bug690: a module const from a @comptime call is the folded value" {
	const c = cOf(`const PROGRAM: uint64 = digitSum("2222");
		console.log(PROGRAM);`);
	assert c.includes("198535ULL"), c.slice(0, 300);
	assert callsLeft(c, "digitSum__") == 0, c.slice(0, 300);
}

test "bug690: a module const argument and a nested call fold" {
	const c = cOf(`const NAME = "22";
		const PARTS: string[] = ["22", "22"];
		@comptime function twice(n: uint64): uint64 { return n * 2; }
		const A: uint64 = digitSum(NAME + "22");
		const B: uint64 = twice(digitSum(PARTS[0] + PARTS[1]));
		console.log(A, B);`);
	assert c.includes("198535ULL") && c.includes("397070ULL"), c.slice(0, 300);
	assert callsLeft(c, "digitSum__") == 0, c.slice(0, 300);
}

test "bug690: a call inside a function body folds" {
	const c = cOf(`function main(): void { const s: uint64 = digitSum("2222"); console.log(s); }
		main();`);
	assert c.includes("198535ULL") && callsLeft(c, "digitSum__") == 0, c.slice(0, 300);
}

test "bug690: a run-time argument is an error at the call" {
	const refused = "is @comptime, so it runs while compiling";
	assert cOf(`function f(s: string): uint64 { return digitSum(s); }
		console.log(f("22"));`).includes(refused);
	assert cOf(`function f(): uint64 { const s = "22"; return digitSum(s); }
		console.log(f());`).includes(refused);
	assert cOf(`let name = "22";
		const X: uint64 = digitSum(name);
		console.log(X);`).includes(refused);
}

test "bug690: calls inside @comptime code are not checked as run-time calls" {
	const c = cOf(`@comptime function viaParam(text: string): uint64 { return digitSum(text) + 1; }
		@comptime function viaLambda(text: string): uint64 { const g = (t: string): uint64 => digitSum(t); return g(text); }
		const A: uint64 = viaParam("2222");
		const B: uint64 = viaLambda("2222");
		const C: uint64 = @comptime { return digitSum("2222"); };
		console.log(A, B, C);`);
	assert c.includes("198536ULL") && c.includes("198535ULL"), c.slice(0, 300);
}

test "bug690: an overloaded @comptime function is refused by name" {
	assert cOf(`@comptime function pick(n: int32): int32 { return n; }
		@comptime function pick(s: string): int32 { return s.length; }
		const X: int32 = pick(9);
		console.log(X);`).includes("'pick' is @comptime and overloaded");
}

test "bug690: the JS backend folds the same call" {
	const js = compileProjectToJSWithStd([{ entryPath: "test/main.ms", entrySource: LIB + `
		const PROGRAM: uint64 = digitSum("2222");
		console.log(PROGRAM);
	` }], "test/main.ms");
	assert js.includes("198535") && !js.includes("digitSum("), js.slice(0, 300);
}

struct Key690 {
	a: uint64;
	b: uint64;
}

enum Kind690 { Small, Large }

@comptime function key690(n: uint64): Key690 {
	return { a: n, b: n * 2 };
}

@comptime function weight690(kind: Kind690, base: int32): int32 {
	return kind == Kind690.Large ? base * 10 : base;
}

const KEY690: Key690 = key690(7);
const WEIGHT690: int32 = weight690(Kind690.Large, 3);

test "bug690: struct and enum arguments and results fold to the run-time values" {
	assert KEY690.a == 7 && KEY690.b == 14;
	assert WEIGHT690 == 30;
}
