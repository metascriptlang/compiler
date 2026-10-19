// @stdout: overload-literal-method ok 8
// note: a literal argument to an overloaded instance or static method takes the winning overload's parameter type, as it does for a single definition and for an overloaded function: `[]`, `[1, 2]` and `[1.5]` into `number[]`, and `int32[]` against `number[]` or `int32` against `number` picks the same overload in either declaration order. Same output on C and JS.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

class Bag {
	size(): number { return -1; }
	size(xs: number[]): number { return xs.length; }
	intFirst(xs: int32[]): string { return "i32:" + xs.length.toString(); }
	intFirst(xs: number[]): string { return "num:" + xs.length.toString(); }
	numFirst(xs: number[]): string { return "num:" + xs.length.toString(); }
	numFirst(xs: int32[]): string { return "i32:" + xs.length.toString(); }
	scalarNumFirst(x: number): string { return "num"; }
	scalarNumFirst(x: int32): string { return "i32"; }
	static make(): string { return "none"; }
	static make(xs: number[]): string { return "made:" + xs.length.toString(); }
}

const bag = new Bag();
row("method-empty", bag.size([]).toString(), "0");
row("method-two", bag.size([1, 2]).toString(), "2");
row("method-int-first-int", bag.intFirst([1, 2]), "i32:2");
row("method-int-first-float", bag.intFirst([1.5]), "num:1");
row("method-num-first-int", bag.numFirst([1, 2]), "i32:2");
row("method-num-first-float", bag.numFirst([1.5]), "num:1");
row("method-scalar", bag.scalarNumFirst(1) + "/" + bag.scalarNumFirst(1.5), "i32/num");
row("static", Bag.make([]) + "/" + Bag.make([1]), "made:0/made:1");
console.log(wrong == "" ? "overload-literal-method ok " + rows.toString() : "overload-literal-method wrong:" + wrong);
