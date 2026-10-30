// @xfail(raiser): the Raiser does not fill the override's defaults through the base; card 2026-10-29-raiser-override-through-base-corrupts-heap-and-reads-garbage-defaults
// @skip-js: the callee does not evaluate a default; a call typed as the base passes none; card 2026-10-20-an-override-with-fewer-or-defaulted-params-breaks-the-dispatcher
// @stdout: m|m!/n|n! 2
// @stdout: m|m!/n|n! 2
let calls: int32 = 0;
function make(tag: string): string { calls += 1; return tag; }
function inner(a: string, b: string = a + "!"): string { return a + "|" + b; }
class A { value(): string { return "a"; } }
class B extends A { value(s: string = inner(make("m"))): string { return s; } }
class C extends B { value(s: string = inner(make("m")), t: string = inner(make("n"))): string { return s + "/" + t; } }
const viaA: A = new C();
const viaB: B = new C();
console.log(viaA.value(), calls);
calls = 0;
console.log(viaB.value(), calls);
