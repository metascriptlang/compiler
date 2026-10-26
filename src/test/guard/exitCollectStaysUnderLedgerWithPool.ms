// guard: a build with the DRC ledger collects, at pool shutdown, the cycles a worker left
//
// INVARIANT: as exitCollectStaysUnderLedger, for the spawn pool. A worker's roots reach the main
//   thread only when the pool joins it at exit (runtime/promise/pool.c msPoolShutdown), after the
//   generated exit has run, so only the shutdown's ledger collect can reach WorkerCell.
//
// RED MEANS: msPoolShutdown lost its ledger collect; restore it under MS_DRC_LEDGER after the
//   drains, before reading any SAN-lane balance.
// GUARD-BALANCE WorkerCell

class WorkerCell {
	next: WorkerCell | null = null;
}

function workerCycle(): int32 {
	const c = new WorkerCell();
	c.next = c;
	return 1;
}

async function run(): Promise<void> {
	const v = await spawn(() => workerCycle());
	console.log("cycles " + v.toString());
}

run();
