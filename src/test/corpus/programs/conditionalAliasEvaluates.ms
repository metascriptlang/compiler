// @stdout: conditional-alias ok 14
// note: a conditional type alias instantiates to its evaluated branch wherever it is written: inside a `distinct` alias argument (`Acc<Settled<R>>` is `Acc<number>`), inside a generic class argument (`Box<Settled<R>>`), inside a union with null (`Settled<R> | null` for a nullable `R`), and at the top of a return type (`MemoAcc<R>`). A union substituted for the naked check parameter distributes over its members, so `Settled<Promise<int32> | string | null>` is `int32 | string | null`. Same output on C, JS and the Raiser.
type Acc<T> = distinct (() => T);
type Settled<R> = R extends Promise<infer U> ? U : R;
type MemoAcc<R> = R extends Promise<infer U> ? Acc<U> : Acc<R>;

let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

class Box<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}

function mk<R>(compute: (prev: Settled<R> | null) => R): Acc<Settled<R>> {
	const value = compute(null) as Settled<R>;
	return (() => value) as Acc<Settled<R>>;
}

function boxed<R>(compute: (prev: Settled<R> | null) => R): Box<Settled<R>> {
	return new Box<Settled<R>>(compute(null) as Settled<R>);
}

function again<R>(compute: (prev: Settled<R> | null) => R): string {
	const first = compute(null);
	const h = new Box<Settled<R>>(first as Settled<R>);
	compute(h.value);
	return "again";
}

function memo<R>(compute: () => R): MemoAcc<R> {
	const value = compute();
	return (() => value) as MemoAcc<R>;
}

function label(v: Settled<Promise<int32> | string | null>): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	return "n:" + v.toString();
}

function labelThree(v: Settled<string | int32 | null>): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	return "n:" + v.toString();
}

const a: Acc<int32> = mk<int32>(() => 2);
const b: Box<int32> = boxed<int32>(() => 3);
const c: Acc<string | null> = mk<string | null>(() => "c");
const d: Acc<int32> = memo<int32>(() => 4);
const e: Acc<string> = memo<string>(() => "e");
row("distinct", a().toString(), "2");
row("class", b.value.toString(), "3");
row("nullable", c() ?? "none", "c");
row("memo number", d().toString(), "4");
row("memo string", e(), "e");
row("again nullable", again<string | null>(() => null), "again");
row("again string", again<string>(() => "x"), "again");
row("again three", again<string | int32 | null>(() => 1), "again");
row("three number", label(7), "n:7");
row("three string", label("u"), "s:u");
row("three null", label(null), "null");
row("plain number", labelThree(5), "n:5");
row("plain string", labelThree("t"), "s:t");
row("plain null", labelThree(null), "null");
console.log(wrong == "" ? "conditional-alias ok " + rows.toString() : "conditional-alias WRONG" + wrong);
