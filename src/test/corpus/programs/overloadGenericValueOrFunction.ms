// @stdout: value-or-function ok 14
// @xfail(raiser): raiser runtime error: cannot evaluate typeof at comptime: 'function' and 'number' variants share Raiser value kind 2 (inbox 2026-09-26-raiser-typeof-yields-the-value, 2026-10-15-raiser-typeof-cannot-tell-a-function-from-an-object)
// note: a generic overload pair over one generic implementation `first: T | ((prev: T | null) => T)` runs the implementation instantiated from the arguments: a value picks the value signature and a function picks the function signature, for a number, a string, an object literal, an interface value, an annotated or contextually typed arrow, in either declaration order, and for a pair that returns `T`. Same output on C and JS.
interface P { a: number; }
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

function createSignal<T>(fn: (prev: T | null) => T): string;
function createSignal<T>(value: T): string;
function createSignal<T>(first: T | ((prev: T | null) => T)): string {
	if (typeof first === "function") { return "derived"; }
	return "plain";
}
function valueFirst<T>(value: T): string;
function valueFirst<T>(fn: (prev: T | null) => T): string;
function valueFirst<T>(first: T | ((prev: T | null) => T)): string {
	if (typeof first === "function") { return "derived"; }
	return "plain";
}
function readFirst<T>(fn: (prev: T | null) => T): T;
function readFirst<T>(value: T): T;
function readFirst<T>(first: T | ((prev: T | null) => T)): T {
	if (typeof first === "function") { return first(null); }
	return first;
}

const p: P = { a: 2 };
row("number", createSignal(0), "plain");
row("annotated arrow", createSignal((prev: number | null): number => 1), "derived");
row("explicit arrow", createSignal<number>((prev) => 1), "derived");
row("object literal", createSignal({ a: 1 }), "plain");
row("interface value", createSignal(p), "plain");
row("string", createSignal("s"), "plain");
row("value first number", valueFirst(0), "plain");
row("value first annotated arrow", valueFirst((prev: number | null): number => 1), "derived");
row("value first explicit arrow", valueFirst<number>((prev) => 1), "derived");
row("value first object literal", valueFirst({ a: 1 }), "plain");
const seven: int32 = readFirst(7);
const eight: number = readFirst((prev: number | null): number => 8);
const nine = readFirst<number>((prev) => 9);
row("read value", seven.toString(), "7");
row("read annotated arrow", eight.toString(), "8");
row("read explicit arrow", nine.toString(), "9");
row("read string", readFirst("x"), "x");
console.log(wrong == "" ? "value-or-function ok " + rows.toString() : "value-or-function WRONG" + wrong);
