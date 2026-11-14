// GUARD-JS
// onDestroy and onTrace must not throw. Each shape below is a compile error naming the throw
// or the call that reaches it, on C and on JS. Shapes: a throw through a callee, two callees
// deep, a direct throw, a method hook, a throwing constructor, a throwing override, an extern
// marked @throws, a throw after a catch, onTrace, a generic hook per instance, a toString radix checked at run time. A throw caught
// inside the hook, a lockedUpdate with a literal and a toString with a literal or no radix compile.
// RED MEANS: walkEffect (effects.ms) lost a way to throw, a hook kind is no longer checked,
// or a throw that cannot leave the hook is refused.
//
// GUARD-CHECK-FAIL lifecycle hook 'onDestroy' of 'Tag' must not throw, but it calls 'check' at 27:
// GUARD-CHECK-FAIL it calls 'deep1' at 33:
// GUARD-CHECK-FAIL of 'Direct' must not throw, but it throws at 36:
// GUARD-CHECK-FAIL of 'MethodHook' must not throw, but it calls 'check' at 40:
// GUARD-CHECK-FAIL it constructs 'Fails' at 45:
// GUARD-CHECK-FAIL it calls 'name' as overridden in 'Loud' at 50:
// GUARD-CHECK-FAIL it calls 'externThrow' at 54:
// GUARD-CHECK-FAIL it throws at 57:
// GUARD-CHECK-FAIL lifecycle hook 'onTrace' of 'Cyc' must not throw, but it calls 'check' at 60:
// GUARD-CHECK-FAIL of 'Box<Deep>' must not throw, but it calls 'close' at 65:
// GUARD-CHECK-FAIL of 'Radix' must not throw, but it calls 'toString' with a radix checked at run time at 76:

import { lockedUpdate } from "std/core/promise";

struct Tag { id: int32; }
function check(id: int32): void { if (id == 7) throw new Error(`tag ${id}`); }
function onDestroy(this t: Tag): void { // GUARD-REFUSED
	check(t.id);
}

function deep2(): void { throw new Error("deep"); }
function deep1(): void { deep2(); }
class DeepCallee { v: int32 = 1; }
function onDestroy(this x: DeepCallee): void { deep1(); } // GUARD-REFUSED

struct Direct { n: int32; }
function onDestroy(this d: Direct): void { if (d.n > 0) throw new Error("direct"); } // GUARD-REFUSED

class MethodHook {
	v: int32 = 1;
	onDestroy(): void { check(this.v); } // GUARD-REFUSED
}

class Fails { constructor() { throw new Error("ctor"); } }
class BuildsFails { v: int32 = 1; }
function onDestroy(this x: BuildsFails): void { const f = new Fails(); } // GUARD-REFUSED

class Quiet { name(): string { return "quiet"; } }
class Loud extends Quiet { name(): string { throw new Error("loud"); } }
class Names { q: Quiet = new Loud(); }
function onDestroy(this x: Names): void { console.log(x.q.name()); } // GUARD-REFUSED

@throws extern function externThrow(): void from "msGuardExternThrow";
class Extern { v: int32 = 1; }
function onDestroy(this x: Extern): void { externThrow(); } // GUARD-REFUSED

class Rethrows { v: int32 = 1; }
function onDestroy(this x: Rethrows): void { try { check(7); } catch (e) { throw e; } } // GUARD-REFUSED

class Cyc { id: int32 = 0; next: Cyc | null = null; }
function onTrace(this x: Cyc, env: Ptr<void>): void { check(x.id); } // GUARD-REFUSED

class Deep { close(): void { throw new Error("close"); } }
class Shallow { close(): void { console.log("closed"); } }
class Box<T> { v: T; constructor(v: T) { this.v = v; } } // GUARD-REFUSED
function onDestroy<T>(this b: Box<T>): void { b.v.close(); }
function useBoxes(): void { const s = new Box<Shallow>(new Shallow()); const d = new Box<Deep>(new Deep()); }

class Caught { v: int32 = 1; }
function onDestroy(this x: Caught): void { try { check(7); } catch (e) { console.log("caught"); } }

const cell: Locked<int32> = new Locked<int32>(0);
class Locks { v: int32 = 1; }
function onDestroy(this x: Locks): void { lockedUpdate(cell, (n: int32): int32 => n + 1); }

class Radix { r: int32 = 16; }
function onDestroy(this x: Radix): void { console.log((255).toString(x.r)); } // GUARD-REFUSED
class LiteralRadix { v: int32 = 255; }
function onDestroy(this x: LiteralRadix): void { console.log(x.v.toString(16) + x.v.toString()); }
console.log("GUARD-OK");
