// @xfail(raiser): raiser runtime error: cannot evaluate 'super' at comptime — constructing any subclass fails on the raiser, on main too
// @stdout: child=3 deep=5 protected=12 sibling=4
// note: a method inherited from a parent that has fields, called through `this` inside the subclass, one and two levels below the parent, and a protected parent method reached the same way. Checking the subclass body must not re-shape the subclass and lose the parent's fields. Same output on every backend.

class P {
	level: int32 = 1;
	shared(): int32 { return this.level + 1; }
	protected scaled(by: int32): int32 { return this.level * by; }
}

class Q extends P {
	extra: int32 = 2;
	viaThis(): int32 { return this.shared() + this.level; }
	viaProtected(): int32 { return this.scaled(10) + this.extra; }
	viaSibling(other: Q): int32 { return other.shared() + other.extra; }
}

class R extends Q {
	deep(): int32 { return this.shared() + this.viaThis(); }
}

const q = new Q();
const r = new R();
console.log(`child=${q.viaThis()} deep=${r.deep()} protected=${q.viaProtected()} sibling=${q.viaSibling(q)}`);
