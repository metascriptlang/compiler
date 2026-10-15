// @stdout: generic-method ok 12
// @xfail(raiser): overloaded class methods run the last-declared body on the Raiser (arc name-to-symbol, corpus 258-classMethodOverload)
// note: an overloaded class method with its own type parameter runs an instantiation bound from the call's arguments: a value or a function picks `sig<T>(value: T)` or `sig<T>(fn: (prev: T | null) => T)` in either declaration order, with an annotated arrow, a contextually typed arrow under an explicit type argument, a number and an object literal, and `T | null` and `T` formals bind `T` from a plain value. Same output on C and JS.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

class Store {
	sig<T>(fn: (prev: T | null) => T): string { return "derived " + fn(null).toString(); }
	sig<T>(value: T): string { return "plain"; }
}
class Rev {
	sig<T>(value: T): string { return "plain"; }
	sig<T>(fn: (prev: T | null) => T): string { return "derived " + fn(null).toString(); }
}
class K {
	g<T>(v: T): string { return "one"; }
	g(v: string, n: number): string { return "two " + v + n.toString(); }
	h<T>(v: T | null): string { return v == null ? "none" : "some"; }
	h(v: string, n: number): string { return "pair"; }
}
const s = new Store();
const r = new Rev();
const k = new K();
row("Store number", s.sig(0), "plain");
row("Store annotated arrow", s.sig((prev: number | null): number => 1), "derived 1");
row("Store explicit arrow", s.sig<number>((prev) => 2), "derived 2");
row("Store object literal", s.sig({ a: 1 }), "plain");
row("Rev number", r.sig(0), "plain");
row("Rev annotated arrow", r.sig((prev: number | null): number => 1), "derived 1");
row("Rev explicit arrow", r.sig<number>((prev) => 2), "derived 2");
row("Rev object literal", r.sig({ a: 1 }), "plain");
row("K bare T", k.g(1), "one");
row("K pair", k.g("a", 2), "two a2");
row("K T or null", k.h(1), "some");
row("K T or null pair", k.h("a", 2), "pair");
console.log(wrong == "" ? "generic-method ok " + rows.toString() : "generic-method WRONG" + wrong);
