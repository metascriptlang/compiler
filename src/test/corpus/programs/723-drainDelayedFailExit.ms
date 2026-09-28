// @xfail(raiser): an async call runs inline on Raiser, so the throw after its await aborts the program (raiser runtime error: unhandled exception: delayed-orphan-boom) instead of failing its promise, card .inbox/compiler/2026-09-28-raiser-async-call-runs-inline (sibling of 721)
// @exit: 1
// @skip-js: node exits 1 like C but prints its own unhandled-rejection report, and parity compares merged stdout+stderr (sibling of 721)
async function delayedBoom(): Promise<void> {
	await sleepAsync(20);
	throw new Error("delayed-orphan-boom");
}
delayedBoom();
