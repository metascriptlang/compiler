// @stdout: overload-literal ok 19
// note: a literal argument to an overloaded call takes the winning overload's parameter type, as it does for a single definition: `[]`, `[1, 2]`, `[1.5]`, `[[1]]`, `[7]` and `{ n: 1 }` into functions, generic functions and extensions; `int32[]` against `number[]` picks the same overload in either declaration order. Same output on C, JS and the Raiser.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

function size(): number { return -1; }
function size(xs: number[]): number { return xs.length; }
function grow(): number { return -1; }
function grow(xs: number[]): number { xs.push(0.25); return xs[0] + xs[1]; }

class Held<T> { value: T; constructor(value: T) { this.value = value; } }
function hold<T>(): Held<T> | null { return null; }
function hold<T>(value: T): Held<T> | null { return new Held<T>(value); }
function heldLength(h: Held<number[]> | null): string { return h === null ? "none" : h.value.length.toString(); }
function keep<T>(): T[] { return []; }
function keep<T>(xs: T[]): T[] { return xs; }

function intFirst(xs: int32[]): string { return "i32:" + xs.length.toString(); }
function intFirst(xs: number[]): string { return "num:" + xs.length.toString(); }
function numFirst(xs: number[]): string { return "num:" + xs.length.toString(); }
function numFirst(xs: int32[]): string { return "i32:" + xs.length.toString(); }

function nested(): number { return -1; }
function nested(xs: number[][]): number { xs[0].push(0.5); return xs[0][0] + xs[0][1]; }

interface Box { n: number; }
function boxed(): number { return -1; }
function boxed(b: Box): number { return b.n + 0.5; }

function bytes(xs: uint8[]): string { return "u8:" + xs[0].toString(); }
function bytes(xs: string[]): string { return "s"; }
function singles(xs: float32[]): string { return "f32:" + xs.length.toString() + ":" + xs[0].toString(); }
function singles(xs: string[]): string { return "s"; }
function wide(xs: int64[]): string { return "i64:" + xs[0].toString(); }
function wide(xs: float64[]): string { return "f64"; }

function count(this s: string): number { return -1; }
function count(this s: string, xs: number[]): number { return xs.length; }

row("size-empty", size([]).toString(), "0");
row("size-two", size([1, 2]).toString(), "2");
row("size-float", size([1.5]).toString(), "1");
row("grow", grow([1]).toString(), "1.25");
row("hold-empty", heldLength(hold<number[]>([])), "0");
row("hold-two", heldLength(hold<number[]>([1, 2])), "2");
row("keep-empty", keep<number>([]).length.toString(), "0");
row("keep-two", (keep<number>([1, 2])[0] + 0.5).toString(), "1.5");
row("int-first-int", intFirst([1, 2]), "i32:2");
row("int-first-float", intFirst([1.5]), "num:1");
row("num-first-int", numFirst([1, 2]), "i32:2");
row("num-first-float", numFirst([1.5]), "num:1");
row("nested", nested([[1]]).toString(), "1.5");
row("object", boxed({ n: 1 }).toString(), "1.5");
row("uint8", bytes([7]), "u8:7");
row("float32", singles([1, 1.5]), "f32:2:1");
row("int64", wide([5]), "i64:5");
row("extension-empty", "x".count([]).toString(), "0");
row("extension-two", "x".count([1, 2]).toString(), "2");
console.log(wrong == "" ? "overload-literal ok " + rows.toString() : "overload-literal wrong:" + wrong);
