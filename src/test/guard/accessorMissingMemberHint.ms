// A missing member lists the accessors of its class and no private name
//
// INVARIANT: `Property 'x' does not exist on type 'C'. Available: ...` names the class's accessors and
//   leaves out a private field an outside reader cannot touch.
//
// WHAT IT CATCHES: the hint reading only the stored field list, which named the private `count` and left out `value`.
//
// RED MEANS: the hint changed its members. The same read of `value` still compiles.
//
// GUARD-CHECK-FAIL Property 'nope' does not exist on type 'GuardCounter'. Available: value
// GUARD-JS

class GuardCounter {
	private count: int32 = 3;
	get value(): int32 { return this.count; }
}
const c = new GuardCounter();
console.log(c.value);
console.log(c.nope); // GUARD-REFUSED
