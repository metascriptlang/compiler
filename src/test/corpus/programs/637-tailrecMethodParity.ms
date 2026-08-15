// @stdout: tailrec-method r=
// `this.m(...)` is a static call only when no subclass can replace m — the Nim
// tfFinal question (types.nim:456, ccgexprs.nim:1995), answered here by the
// OpenClass bit. Counter is final, so both methods run 5M deep in O(1) stack.
//
// The open-class half of the gate has NO automated assertion: proving it needs a
// subclass override to win over its base, which the C backend cannot do yet (it
// binds `b.step()` statically), so a parity program would fail for a reason that
// has nothing to do with tail calls. It is checked by reading the emitted JS —
// an extended class keeps its plain recursive method, no `__tcp` locals.

class Counter {
	loop(n: int64, acc: int64): int64 {
		if (n <= 0) return acc;
		return this.loop(n - 1, acc + 1);
	}

	grow(n: int64, s: string): string {
		return n <= 0 ? s : this.grow(n - 1, s.slice(0, 1) + "y");
	}
}

const c = new Counter();
console.log("tailrec-method r=" + c.loop(5000000, 0).toString() + "-" + c.grow(200000, "y").length.toString());
