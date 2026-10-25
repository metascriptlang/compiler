// @stdout: string-literal-union ok 24
// note: a string literal argument ranks an overload whose parameter is a string-literal union by its own literal, in either declaration order and on a method, while a parameter of type `string` keeps taking it. Beside a `string` overload the literal union is the more specific one and wins for a literal it holds, in either order, as a function, method or extension, through an alias and in a later argument, and a lone literal parameter wins the same way; another literal and a `string` variable take `string`. Same output on C, JS and the Raiser.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

function sl(x: "a" | "b"): string { return "lit:" + x; }
function sl(x: number): string { return "num"; }
function ls(x: number): string { return "num"; }
function ls(x: "a" | "b"): string { return "lit:" + x; }
function ws(x: string): string { return "str:" + x; }
function ws(x: number): string { return "num"; }
class M {
	mode(x: "on" | "off"): string { return "mode:" + x; }
	mode(x: boolean): string { return "flag"; }
}
const m = new M();
row("literal first a", sl("a"), "lit:a");
row("literal first b", sl("b"), "lit:b");
row("literal first number", sl(2), "num");
row("number first a", ls("a"), "lit:a");
row("number first number", ls(2), "num");
row("string parameter", ws("z"), "str:z");
row("string parameter number", ws(3), "num");
row("method literal", m.mode("off"), "mode:off");
row("method boolean", m.mode(true), "flag");
function on(e: "a" | "b"): string { return "lit:" + e; }
function on(e: string): string { return "str:" + e; }
function no(e: string): string { return "str:" + e; }
function no(e: "a" | "b"): string { return "lit:" + e; }
type Mode = "up" | "down";
function go(m: string): string { return "str"; }
function go(m: Mode): string { return "mode"; }
function two(a: string, b: string): string { return "str"; }
function two(a: string, b: "x" | "y"): string { return "lit"; }
class Bag {}
function tag(this b: Bag, e: string): string { return "str"; }
function tag(this b: Bag, e: "x" | "y"): string { return "lit"; }
class Sw {
	set(e: string): string { return "str"; }
	set(e: "on" | "off"): string { return "lit"; }
}
function one(x: string): string { return "str"; }
function one(x: "a"): string { return "lit"; }
function eno(x: "a"): string { return "lit"; }
function eno(x: string): string { return "str"; }
const someText: string = "a";
row("union before string a", on("a"), "lit:a");
row("union before string other", on("c"), "str:c");
row("string before union b", no("b"), "lit:b");
row("string variable", on(someText), "str:a");
row("alias", go("down"), "mode");
row("alias other", go("left"), "str");
row("second argument", two("q", "y"), "lit");
row("second argument other", two("q", "z"), "str");
row("extension", new Bag().tag("x"), "lit");
row("extension other", new Bag().tag("w"), "str");
row("method string first", new Sw().set("on"), "lit");
row("method other", new Sw().set("dim"), "str");
row("lone literal after string", one("a"), "lit");
row("lone literal before string", eno("a"), "lit");
row("lone literal other", one("b"), "str");
console.log(wrong == "" ? "string-literal-union ok " + rows.toString() : "string-literal-union WRONG" + wrong);
