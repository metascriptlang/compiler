// nim-guard: the `this: T` receiver parameter — every misuse is a diagnostic.
//
// INVARIANT (PARALOCK Amendment M): `this: Readonly<C>` on a method makes the
//   body read-only (E24), a method without it stays uncallable through a view,
//   and the form is meaningless anywhere but a class method's first parameter.
//
// WHAT IT CATCHES: the read-only receiver silently becoming mutable, the view
//   call gate opening for plain methods, or `this: T` being accepted as an
//   ordinary parameter named `this` on a function, lambda, constructor or
//   static method.
//
// RED MEANS: one of the six diagnostics stopped firing.
//
// GUARD-CHECK-FAIL cannot write through Readonly<Tally>
// GUARD-CHECK-FAIL a method callable through the view declares its receiver
// GUARD-CHECK-FAIL has no receiver
// GUARD-CHECK-FAIL only valid as the receiver of a class method
// GUARD-CHECK-FAIL a method's 'this' must be Tally or Readonly<Tally>
// GUARD-CHECK-FAIL a constructor has no 'this' parameter

class Other { m: int32 = 0; }

class Tally {
	n: int32 = 3;
	// 1 — the read-only receiver refuses a write.
	reset(this: Readonly<Tally>): void { this.n = 0; }
	bump(): void { this.n += 1; }
	// 5 — the receiver must be this class.
	wrong(this: Readonly<Other>): int32 { return this.m; }
	// 3 — a static method has no receiver.
	static make(this: Readonly<Tally>): Tally { return new Tally(); }
}

// 6 — a constructor has no receiver parameter.
class Built {
	v: int32;
	constructor(this: Built, v: int32) { this.v = v; }
}

// 2 — a plain method is not callable through a view.
function viewCallsMutator(): void {
	const t = new Tally();
	const v: Readonly<Tally> = t;
	v.bump();
}

// 4 — `this: T` on a free function is not an extension receiver.
function freeThis(this: Tally): int32 { return 1; }
