// guard: the cycle collector frees a cycle that passes through a field of a distinct type
//
// INVARIANT (reference liftdestructors.nim:1266-1269 tyDistinct arm, types.nim canFormAcycle
//   skipping tyDistinct through abstractInst): a distinct is traced as the type it wraps unless it
//   declares its own trace hook, and cycle analysis meets the cycle's origin through it by the
//   wrapped type's identity, so a destroy hook on the distinct changes neither.
//
// WHAT IT CATCHES: a distinct with an onDestroy dropping its element from the trace, or the cycle
//   analysis keying a distinct on its own name so the back edge never matches; both leave the
//   holder's trace empty and every cell of the cycle alive (alloc=N destroy=0).
//
// AXES: distinct of a class vs distinct of a struct holding a ref; nullable vs non-null field;
//   hooked vs unhooked distinct; two-node vs three-node vs self cycle.
//   DRC is NOT asserted: DRC does not collect cycles by design.
//
// RED MEANS: a distinct field fell out of the trace or out of cycle analysis. Run /trace-ref on
//   the named type (destructorLifting.ms fillBody Distinct arm, cycles.ms canFormAcycle).
// GUARD-BALANCE Pair
// GUARD-BALANCE Tri
// GUARD-BALANCE Plain
// GUARD-BALANCE Solo
// GUARD-BALANCE Holder
// GUARD-BALANCE Keeper

class Pair { h: PairH | null = null; }
type PairH = distinct Pair;
function onDestroy(this x: PairH): void { closes += 1; }

class Tri { h: TriH | null = null; }
type TriH = distinct Tri;
function onDestroy(this x: TriH): void { closes += 1; }

class Plain { h: PlainH | null = null; }
type PlainH = distinct Plain;

class Solo {
	h: SoloH;
	constructor() { this.h = this as SoloH; }
}
type SoloH = distinct Solo;
function onDestroy(this x: SoloH): void { closes += 1; }

class Holder { b: BoxH | null = null; }
struct Box { n: Holder | null; }
type BoxH = distinct Box;
function onDestroy(this x: BoxH): void { closes += 1; }

class Keeper {
	b: KeepH;
	constructor() { const c: Cell = { k: null }; this.b = c as KeepH; }
}
struct Cell { k: Keeper | null; }
type KeepH = distinct Cell;
function onDestroy(this x: KeepH): void { closes += 1; }

let closes: int32 = 0;

function churn(): int32 {
	let i: int32 = 0;
	while (i < 500) {
		const a = new Pair();
		const b = new Pair();
		a.h = b as PairH;
		b.h = a as PairH;
		const t1 = new Tri();
		const t2 = new Tri();
		const t3 = new Tri();
		t1.h = t2 as TriH;
		t2.h = t3 as TriH;
		t3.h = t1 as TriH;
		const p = new Plain();
		p.h = p as PlainH;
		const s = new Solo();
		const h = new Holder();
		const box: Box = { n: h };
		h.b = box as BoxH;
		const k = new Keeper();
		const cell: Cell = { k: k };
		k.b = cell as KeepH;
		i = i + 1;
	}
	return i;
}
console.log("done", churn());
