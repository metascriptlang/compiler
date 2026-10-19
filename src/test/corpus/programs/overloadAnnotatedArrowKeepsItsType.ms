// @stdout: annotated-arrow 8 ok 4
// @xfail(raiser): raiser runtime error: cannot evaluate typeof at comptime: 'function' and 'number' variants share Raiser value kind 2 (inbox 2026-09-26-raiser-typeof-yields-the-value)
// note: an arrow with every parameter and its return annotated ranks overloads by its own type, so a generic overload binds `T` from it even where the call sits in an `unknown` context such as `console.log`, and a pair that differs only in the arrow's parameter type picks by it, in either declaration order. Same output on C and JS.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

function readFirst<T>(fn: (prev: T | null) => T): T;
function readFirst<T>(value: T): T;
function readFirst<T>(first: T | ((prev: T | null) => T)): T {
	if (typeof first === "function") { return first(null); }
	return first;
}
function numFirst(f: (x: number) => number): string { return "num"; }
function numFirst(f: (x: string) => string): string { return "str"; }
function strFirst(f: (x: string) => string): string { return "str"; }
function strFirst(f: (x: number) => number): string { return "num"; }

row("numFirst string arrow", numFirst((x: string): string => x), "str");
row("numFirst number arrow", numFirst((x: number): number => x), "num");
row("strFirst string arrow", strFirst((x: string): string => x), "str");
row("strFirst number arrow", strFirst((x: number): number => x), "num");
console.log("annotated-arrow", readFirst((prev: number | null): number => 8), wrong == "" ? "ok " + rows.toString() : "WRONG" + wrong);
