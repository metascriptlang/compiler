// @stdout: fn=-1,2 arrow=none,x method=-1,3 ctor=-1,5 iface=-1,3 ftype=-1,2 fexpr=-1,4 generic=none,some,none,some mixed=1,9
// note: `x?: T` is `x: T | null = null`: the argument may be omitted and the parameter then reads null. It holds for a function, an arrow, a method, a constructor, a function-typed interface member, a value of function type `(x?: T) => R` and a generic parameter, for value, string, array and class types alike.

class P { v: int32 = 3; }

function fn(xs?: number[]): number { return xs == null ? -1 : xs.length; }
const arrow = (s?: string): string => s == null ? "none" : s;

class C {
	n: int32;
	constructor(n?: int32) { this.n = n == null ? -1 : n; }
	m(p?: P): int32 { return p == null ? -1 : p.v; }
}

interface I { m: (xs?: number[]) => number; }

function h<T>(x?: T): string { return x == null ? "none" : "some"; }
function mixed(a?: int32, b: int32 = 9): string { return `${a == null ? 1 : a},${b}`; }

const iface: I = { m: (xs?: number[]): number => fn(xs) };
const ftype: (xs?: number[]) => number = (xs?: number[]): number => fn(xs);
const fexpr: (n?: int32) => int32 = function (n?: int32): int32 { return n == null ? -1 : n; };

console.log(
	`fn=${fn()},${fn([1, 2])} arrow=${arrow()},${arrow("x")} method=${new C().m()},${new C().m(new P())} `
	+ `ctor=${new C().n},${new C(5).n} iface=${iface.m()},${iface.m([1, 2, 3])} ftype=${ftype()},${ftype([1, 2])} `
	+ `fexpr=${fexpr()},${fexpr(4)} generic=${h<int32>()},${h<int32>(1)},${h<P>()},${h<P>(new P())} mixed=${mixed()}`
);
