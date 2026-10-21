// @stdout: two:a! one:b! three:c! two:a1 one:b~ only:f! gen:g! gen:h! two:i! one:j! int:7 str:k two:lam
// When the arity adapter makes several overloads applicable, the call takes the first declared one, in either order and for generic and method overloads.
function one(s: string): string { return s + "!"; }
function both(s: string, i: int32): string { return s + i; }
function opt(s: string, t?: string): string { return s + (t ?? "~"); }
function wideFirst(f: (s: string, i: int32) => string): string { return "two:" + f("a", 1); }
function wideFirst(f: (s: string) => string): string { return "one:" + f("a"); }
function exactFirst(f: (s: string) => string): string { return "one:" + f("b"); }
function exactFirst(f: (s: string, i: int32) => string): string { return "two:" + f("b", 1); }
function adapted(f: (s: string, i: int32, j: int32) => string): string { return "three:" + f("c", 1, 2); }
function adapted(f: (s: string, i: int32) => string): string { return "two:" + f("c", 1); }
function only(f: (s: string, i: int32) => string): string { return "only:" + f("f", 2); }
function only(x: int32): string { return "int"; }
function gen<T>(x: T, f: (s: string, i: int32) => string): string { return "gen:" + f(String(x), 1); }
function gen<T>(x: T, f: (s: string) => string): string { return "one:" + f(String(x)); }
class Bus {
	on(f: (s: string, i: int32) => string): string { return "two:" + f("i", 1); }
	on(f: (s: string) => string): string { return "one:" + f("i"); }
	off(f: (s: string) => string): string { return "one:" + f("j"); }
	off(f: (s: string, i: int32) => string): string { return "two:" + f("j", 1); }
}
function pick(x: int32): string { return "int:" + x; }
function pick(x: string): string { return "str:" + x; }
const bus = new Bus();
console.log(wideFirst(one), exactFirst(one), adapted(one), wideFirst(both), exactFirst(opt), only(one), gen("g", one), gen("h", one),
	bus.on(one), bus.off(one), pick(7), pick("k"), wideFirst((s: string): string => "lam"));
