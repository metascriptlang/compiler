// @xfail(raiser): the Raiser does not fill the override's defaults through the base; card 2026-10-29-raiser-override-through-base-corrupts-heap-and-reads-garbage-defaults
// @skip-js: the callee does not evaluate a default; a call typed as the base passes none; card 2026-10-20-an-override-with-fewer-or-defaulted-params-breaks-the-dispatcher
// @stdout: m|m! 1
// @stdout: given 1
// @stdout: m|m! 2
let calls: int32 = 0;
function make(): string { calls += 1; return "m"; }
function inner(a: string, b: string = a + "!"): string { return a + "|" + b; }
class Base { value(): string { return "base"; } }
class Child extends Base {
	value(s: string = inner(make())): string { return s; }
}
const base: Base = new Child();
console.log(base.value(), calls);
console.log(new Child().value("given"), calls);
console.log(new Child().value(), calls);
