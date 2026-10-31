// @stdout: 3 12
// @stdout: 4 22
// An overload signature may leave out the implementation's defaulted parameters: a call through it
// fills the default, for a function and for a method.
function f(a: string): number;
function f(a: string, n: int32): number;
function f(a: string, n: int32 = 1): number { return a.length + n; }

class K {
	m(a: string): number;
	m(a: string, n: int32): number;
	m(a: string, n: int32 = 2): number { return a.length + n; }
}

console.log(f("ab"), f("ab", 10));
const k = new K();
console.log(k.m("ab"), k.m("ab", 20));
