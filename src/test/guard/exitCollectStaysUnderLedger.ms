// guard: a build with the DRC ledger still collects the cycles left at exit
//
// INVARIANT: production exits as the reference does, leaving garbage cycles uncollected
//   (corpus cycleHookNotRunAtExit). The ledger build alone keeps the exit collects, so a
//   balance it reports separates a leaked cell from a cycle that was merely still floating.
//
// WHAT IT CATCHES: a self-cycle on the main thread of a program that never starts the spawn
//   pool, so only the collect in the generated MsMain/MsDestroyGlobals can reach it. The pool
//   shutdown's collect is pinned by exitCollectStaysUnderLedgerWithPool.
//
// RED MEANS: the generated exit lost its ledger collect; restore it under MS_DRC_LEDGER before
//   reading any SAN-lane balance.
// GUARD-BALANCE MainCell

class MainCell {
	next: MainCell | null = null;
}

function mainCycle(): void {
	const c = new MainCell();
	c.next = c;
}

mainCycle();
console.log("cycle left");
