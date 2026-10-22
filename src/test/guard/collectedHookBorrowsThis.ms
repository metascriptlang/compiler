// nim-guard: a destroy hook on a collected cycle may borrow `this` and run once
//
// INVARIANT (ULTRALOCK M6): a hook that only borrows `this` (a closure or a callee) runs once
//   and frees nothing twice, whether the cell dies by its last decref or in the collector's
//   free loop. The free loop hands each cell to its hook with the
//   sole-owner count, the count a last decref leaves, so the borrow's incref/decref pair
//   cannot reach "last" again.
//
// WHAT IT CATCHES: a collected cell keeping its trial-decremented count into the hook —
//   the borrow's decref then reads "last" and destroys the cell a second time
//   (DOUBLE-DESTROY of Tri / Solo / Pair).
//
// AXES: cycle length 3 / 1 / 2; the borrow through a local closure and a closure argument.
//   Seed's hook builds a fresh cycle, so roots arrive while the free loop runs and must not start a collection over cells it is still freeing.
//   The spawn-thunk axis is refused at compile time by the hook law (T7, 7b93f92bf); collectedHookSpawnRejects pins that refusal.
//   DRC is NOT asserted: DRC does not collect cycles by design.
//
// RED MEANS: the collector's free loop runs a hook on a cell whose count is not the
//   sole-owner count, or lets a hook re-enter the collector. Run /trace-ref on
//   collectCyclesBacon (runtime/drc.c).
// GUARD-BALANCE Tri
// GUARD-BALANCE Solo
// GUARD-BALANCE Pair
// GUARD-BALANCE Seed

class Tri { next: Tri | null = null; tag: int32 = 1; }
class Solo { next: Solo | null = null; tag: int32 = 1; }
class Pair { next: Pair | null = null; tag: int32 = 1; }
class Seed { next: Seed | null = null; tag: int32 = 1; }
class Sprout { next: Sprout | null = null; }

let hooks: int32 = 0;
let seen: int32 = 0;

function work(n: int32): int32 { return n + 1; }
function apply(f: () => int32): int32 { return f(); }

function onDestroy(this x: Tri): void {
	const c = () => work(x.tag);
	seen += c();
	hooks += 1;
}

function onDestroy(this x: Solo): void {
	const c = () => work(x.tag);
	seen += c();
	hooks += 1;
}

function onDestroy(this x: Pair): void {
	seen += apply(() => work(x.tag));
	hooks += 1;
}

function onDestroy(this x: Seed): void {
	const a = new Sprout();
	const b = new Sprout();
	a.next = b;
	b.next = a;
	seen += x.tag;
	hooks += 1;
}

function churn(): void {
	for (let i: int32 = 0; i < 2000; i += 1) {
		const a = new Tri();
		const b = new Tri();
		const c = new Tri();
		a.next = b;
		b.next = c;
		c.next = a;
		const s = new Solo();
		s.next = s;
		const p = new Pair();
		const q = new Pair();
		p.next = q;
		q.next = p;
		const e = new Seed();
		const f = new Seed();
		e.next = f;
		f.next = e;
	}
}

churn();
console.log("GUARD-OK");
