// @stdout: three=handled method=handled
// @stdout: two=always number=handled
// @stdout: string=plain class=7 classes=bee,3
// @stdout: generic=handled updater=always

type Mode = "never" | "always" | "handled";
type Pair = "never" | "always";

function takeMode(m: Mode): string { return m; }
function takePair(m: Pair): string { return m; }
function takeString(m: string): string { return m; }

class Holder {
	take(m: Mode): string { return m; }
}

class Foo { n: number; constructor(n: number) { this.n = n; } }
class A { n: number; constructor(n: number) { this.n = n; } }
class B { s: string; constructor(s: string) { this.s = s; } }
function takeFoo(m: Foo): string { return m.n.toString(); }
function takeAB(m: A | B): string { return m instanceof A ? m.n.toString() : m.s; }

function three(v: Mode | ((prev: Mode) => Mode)): string {
	if (typeof v === "function") { return takeMode(v("never")); }
	return takeMode(v);
}
function viaMethod(v: Mode | ((prev: Mode) => Mode)): string {
	if (typeof v === "function") { return "fn"; }
	return new Holder().take(v);
}
function two(v: Pair | ((prev: Pair) => Pair)): string {
	if (typeof v === "function") { return "fn"; }
	return takePair(v);
}
function withNumber(v: Mode | number): string {
	if (typeof v === "number") { return "number"; }
	return takeMode(v);
}
function plain(v: string | ((prev: string) => string)): string {
	if (typeof v === "function") { return "fn"; }
	return takeString(v);
}
function oneClass(v: Foo | ((prev: Foo) => Foo)): string {
	if (typeof v === "function") { return "fn"; }
	return takeFoo(v);
}
function twoClasses(v: A | B | ((prev: A | B) => A | B)): string {
	if (typeof v === "function") { return "fn"; }
	return takeAB(v);
}
function generic<T>(v: T | ((prev: T) => T), start: T, read: (x: T) => string): string {
	if (typeof v === "function") { return read(v(start)); }
	return read(v);
}

console.log("three=" + three("handled") + " method=" + viaMethod("handled"));
console.log("two=" + two("always") + " number=" + withNumber("handled"));
console.log("string=" + plain("plain") + " class=" + oneClass(new Foo(7)) + " classes=" + twoClasses(new B("bee")) + "," + twoClasses(new A(3)));
console.log("generic=" + generic<Mode>("handled", "never", takeMode) + " updater=" + generic<Mode>((p: Mode): Mode => p == "never" ? "always" : "handled", "never", takeMode));
