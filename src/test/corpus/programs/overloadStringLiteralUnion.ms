// @stdout: string-literal-union ok 9
// note: a string literal argument ranks an overload whose parameter is a string-literal union by its own literal, in either declaration order and on a method, while a parameter of type `string` keeps taking it. Same output on C and JS.
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
console.log(wrong == "" ? "string-literal-union ok " + rows.toString() : "string-literal-union WRONG" + wrong);
