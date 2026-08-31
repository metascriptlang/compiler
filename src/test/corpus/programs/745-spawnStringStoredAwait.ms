// @stdout: stored acc=80000
// @maxrss: 16
// @serial

// note: Regression guard for STORED string-spawn futures (array, then for-of
// await). Companion of 744 (direct-await fused path): the stored shape goes
// through lowerPromiseSpawn → msSpawnInto's typed-inline future (worker
// memcpys the msString struct into the inline slot and frees the box shell)
// and the reader is msFutureReadString. Before the sink-box fix the same
// msBoxString incref corruption applied here; after it, this cell pins the
// whole chain: shell ownership moves worker→future→reader, one decref frees
// the payload. The array-drop at batch end exercises the crossThreadPublished
// deferred release (Amendment H) — a rc regression here leaks (RSS gate) or
// crashes. acc = 5000 batches × 4 spawns × 4 chars.
function run(): void {
	let acc = 0;
	let batch = 0;
	while (batch < 5000) {
		const futs: Promise<string>[] = [];
		let k = 0;
		while (k < 4) {
			const kk = k;
			futs.push(spawn(() => { return "pt-" + kk.toString(); }));
			k = k + 1;
		}
		for (const f of futs) {
			const s = await f;
			acc = acc + s.length;
		}
		batch = batch + 1;
	}
	console.log("stored acc=" + acc.toString());
}

run();
