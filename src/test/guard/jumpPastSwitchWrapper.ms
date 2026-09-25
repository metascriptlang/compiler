// nim-guard: a jump that leaves a switch wrapper runs the cleanup of every scope it leaves
//
// INVARIANT (injectdestructors.nim:1121 nkBreakStmt `s.needsTry = true` and
//   processScope :625 OR-ing needsTry into the parent): needsTry reaches every
//   enclosing scope, so each scope a jump leaves has its cleanup where the jump runs it.
//
// WHAT IT CATCHES: needsTry stopping at the innermost loop scope. A switch with a
//   non-terminal break is wrapped in a one-shot loop; a `continue` inside it targets
//   the real loop, whose body then keeps its cleanup inline and the jump skips it
//   (TjBox leaks). Axes: the switch directly in the loop body, and one level deeper
//   inside an `if` block that owns a managed local of its own.
//
// RED MEANS: needsTry propagation got a cut-off again. Run /trace-nim on the
//   BreakStmt/ContinueStmt arm of processStmt in inject.ms.
// GUARD-BALANCE TjBox
// GUARD-JS

class TjBox { v: int32; constructor(v: int32) { this.v = v; } }

function direct(): int32 {
	let total = 0;
	let i = 0;
	while (i < 4) {
		const k = i;
		i += 1;
		const keep = new TjBox(k);
		switch (k) {
			case 1:
				if (keep.v > 0) break;
				total += 100;
				continue;
			case 2:
				continue;
			default:
				total += keep.v;
		}
		total += 1000;
	}
	return total;
}

function nested(): int32 {
	let total = 0;
	let i = 0;
	while (i < 4) {
		const k = i;
		i += 1;
		const outer = new TjBox(k);
		if (outer.v >= 0) {
			const inner = new TjBox(k * 10);
			switch (k) {
				case 1:
					if (inner.v > 0) break;
					total += 100;
					continue;
				case 2:
					continue;
				default:
					total += inner.v;
			}
			total += outer.v;
		}
		total += 1000;
	}
	return total;
}

if (direct() == 3003 && nested() == 3034) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
