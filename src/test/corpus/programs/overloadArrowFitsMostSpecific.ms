// @stdout: arrow-most-specific ok 14
// note: an unannotated arrow is typed against each overload, and among the overloads it fits the most specific wins, in either declaration order: `(x) => x + x` fits both `(x: string) => string` and `<U>(x: int32) => U` and takes the concrete one, `(x) => x * 2` fits only the generic one; beside a plain argument before or after it, as a function, a method and an extension. Same output on C, JS and the Raiser.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

function gf<U>(cb: (x: int32) => U): string { return "generic " + cb(2).toString(); }
function gf(cb: (x: string) => string): string { return "string " + cb("s"); }
function sf(cb: (x: string) => string): string { return "string " + cb("s"); }
function sf<U>(cb: (x: int32) => U): string { return "generic " + cb(2).toString(); }
function pre<U>(n: int32, cb: (x: int32) => U): string { return "generic " + cb(n).toString(); }
function pre(n: int32, cb: (x: string) => string): string { return "string " + cb(n.toString()); }
function post(cb: (x: string) => string, n: int32): string { return "string " + cb(n.toString()); }
function post<U>(cb: (x: int32) => U, n: int32): string { return "generic " + cb(n).toString(); }
class Runner {
	run<U>(cb: (x: int32) => U): string { return "generic " + cb(2).toString(); }
	run(cb: (x: string) => string): string { return "string " + cb("s"); }
}
class Cell { n: int32 = 2; }
function at(this c: Cell, cb: (x: string) => string): string { return "string " + cb("c"); }
function at<U>(this c: Cell, cb: (x: int32) => U): string { return "generic " + cb(c.n).toString(); }

row("generic first, both fit", gf((x) => x + x), "string ss");
row("generic first, int only", gf((x) => x * 2), "generic 4");
row("string first, both fit", sf((x) => x + x), "string ss");
row("string first, int only", sf((x) => x * 2), "generic 4");
row("before, both fit", pre(4, (x) => x + x), "string 44");
row("before, int only", pre(4, (x) => x * 2), "generic 8");
row("after, both fit", post((x) => x + x, 4), "string 44");
row("after, int only", post((x) => x * 2, 4), "generic 8");
const r = new Runner();
row("method, both fit", r.run((x) => x + x), "string ss");
row("method, int only", r.run((x) => x * 2), "generic 4");
row("method block, both fit", r.run((x) => { return x + x; }), "string ss");
const c = new Cell();
row("extension, both fit", c.at((x) => x + x), "string cc");
row("extension, int only", c.at((x) => x * 2), "generic 4");
row("extension block, both fit", c.at((x) => { return x + x; }), "string cc");
console.log(wrong == "" ? "arrow-most-specific ok " + rows.toString() : "arrow-most-specific WRONG" + wrong);
