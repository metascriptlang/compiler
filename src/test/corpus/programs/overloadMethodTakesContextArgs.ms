// @stdout: method-context ok 10
// @xfail(raiser): overloaded class methods run the last-declared body on the Raiser (arc name-to-symbol, corpus 258-classMethodOverload)
// note: an object literal or an arrow passed to an overloaded method is checked against the overload it fits, not against the first-declared method: a struct literal picks the method taking that struct over a zero-argument one, an untyped arrow picks the callback overload over a `string` one, in either declaration order, and an arrow whose return does not fit the first callback overload falls to the next. Same output on C and JS.
interface Box { n: number; }
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

class A {
	o(): number { return -1; }
	o(b: Box): number { return b.n + 0.5; }
	on(name: string): string { return "name:" + name; }
	on(cb: (x: number) => number): string { return "cb:" + cb(1.5).toString(); }
}
class B {
	o(b: Box): number { return b.n + 0.25; }
	o(): number { return -2; }
	on(cb: (x: number) => number): string { return "cb:" + cb(2.5).toString(); }
	on(name: string): string { return "name:" + name; }
	pick(f: (x: number) => string): string { return "str " + f(1); }
	pick(f: (x: number) => boolean): string { return "bool " + f(1).toString(); }
}
const a = new A();
const b = new B();
row("A object literal", a.o({ n: 1 }).toString(), "1.5");
row("A no argument", a.o().toString(), "-1");
row("A untyped arrow", a.on((x) => x + 1), "cb:2.5");
row("A name", a.on("n"), "name:n");
row("B object literal", b.o({ n: 1 }).toString(), "1.25");
row("B no argument", b.o().toString(), "-2");
row("B untyped arrow", b.on((x) => x + 1), "cb:3.5");
row("B name", b.on("n"), "name:n");
row("B arrow returning string", b.pick((x) => "s"), "str s");
row("B arrow returning boolean", b.pick((x) => x > 0), "bool true");
console.log(wrong == "" ? "method-context ok " + rows.toString() : "method-context WRONG" + wrong);
