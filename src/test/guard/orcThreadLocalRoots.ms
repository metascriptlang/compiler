// nim-guard: ORC collector state is per-thread — the Nim threadvar rule
//
// INVARIANT (reference lib/system/orc.nim:144/317/379 — `roots`, `rootsThreshold`
//   and `freedCyclicObjects` are each {.threadvar.}): a thread's cycle-candidate
//   root set belongs to that thread. A pool worker that reaches scope exit may
//   run a collection, but only over ITS OWN roots — never another thread's.
//   Nim's thread-safe collector (yrc.nim, "candidate roots are THREAD-LOCAL")
//   keeps the same partition, so no reference collector shares a root set.
//
// WHAT IT CATCHES: any of the ORC state variables in runtime/drc.{c,h} losing
//   _Thread_local. A worker's msOrcEndTeardown then collects over the MAIN
//   thread's msRoots — freeing objects main is still using, and hitting the
//   re-entrancy guard (drc.c: threshold=INT32_MAX, roots.len=0) which drops
//   main's registered roots so its cycles are never reclaimed.
//
// SHAPE: cycles are churned on main WHILE spawned workers allocate and drop a
//   ref-typed local. Both halves are required — dropping either one (worker
//   allocates nothing / main builds no cycles) hides the defect completely.
//
// CONTROL: Solo runs the identical cycle churn BEFORE any spawn exists. It
//   isolates "ORC collects at all" from "ORC collects per-thread": Solo red too
//   means the collector itself broke; only Link red means thread-locality did.
//
// DRC is NOT asserted: ARC/DRC does not collect cycles by design (same as Nim
//   ARC) — both types leak under drc forever and that is correct.
//
// MEASURED on the pre-fix runtime (globals): 10/10 red, every one of them an
//   abort (SIGABRT/SIGTRAP) that fires before the ledger can dump — the freed-
//   live-object half reaches the guard first at this size. The GUARD-BALANCE-ORC
//   assertions are the backstop for a regression that corrupts the root set
//   without crashing: they were observed to catch exactly that at 1/3 the churn,
//   where the crash rate fell to 5/6. Post-fix: 10/10 green, Link 2400000
//   alloc == destroy. Do not shrink the loop bounds — the red rate is what they
//   buy.
//
// RED MEANS: ORC collector state stopped being per-thread. Run /trace-nim on
//   msOrcEndTeardown / msRegisterCycle (runtime/drc.{c,h}) against orc.nim.
// GUARD-BALANCE-ORC Link
// GUARD-BALANCE-ORC Solo

class Link { next: Link | null = null }
class Solo { next: Solo | null = null }
class Scratch { tag: string }

function churnScratch(k: number): number {
	let s = 0;
	let i = 0;
	while (i < 20000) {
		const t = new Scratch();
		s = (s + t.tag.length) % 97;
		i = i + 1;
	}
	return (s + k) % 7;
}

// Control: the same cycle churn with no worker thread in existence yet.
let solo = 0;
while (solo < 20000) {
	const x = new Solo();
	const y = new Solo();
	x.next = y;
	y.next = x;
	solo = solo + 1;
}

let acc = 0;
let round = 0;
while (round < 60) {
	const h1 = spawn(() => churnScratch(1));
	const h2 = spawn(() => churnScratch(2));
	const h3 = spawn(() => churnScratch(3));
	const h4 = spawn(() => churnScratch(4));
	let i = 0;
	while (i < 20000) {
		const a = new Link();
		const b = new Link();
		a.next = b;
		b.next = a;
		i = i + 1;
	}
	acc = (acc + (await h1) + (await h2) + (await h3) + (await h4)) % 1000;
	round = round + 1;
}
console.log("done", acc);
