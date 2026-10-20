// @stdout: one:b! two:a1 one:b~ only:c!
// An overload whose callback slot matches the function's arity outranks one that needs the
// arity adapter; an overload reachable only through the adapter is still chosen.
function one(s: string): string { return s + "!"; }
function both(s: string, i: int32): string { return s + i; }
function opt(s: string, t?: string): string { return s + (t ?? "~"); }
function run(f: (s: string, i: int32) => string): string { return "two:" + f("a", 1); }
function run(f: (s: string) => string): string { return "one:" + f("b"); }
function only(f: (s: string, i: int32) => string): string { return "only:" + f("c", 2); }
function only(x: int32): string { return "int"; }
console.log(run(one), run(both), run(opt), only(one));
