// @xfail(esm): tree emit: native Promise.resolve shadowed by the emitted class Promise in _std/core/promise
// @stdout: concat acc=100000
// @serial

// note: Regression guard for the string-returning spawn box path. The worker
// closure builds a heap string ("pt-" + digit) and returns it boxed; the fused
// await reads it back via msUnboxString. Historic bug: spawnLower boxed strings
// with msBoxString, whose "keep payload alive" incref targeted msStrPayload —
// a COW value-type payload with NO refcount header (msStrContentSize = cap +
// data only) — so the incref wrote into the heap slot BEFORE the payload and
// corrupted it (0xC0000374 after a few hundred spawns on Windows; latent on
// POSIX, same layout). Fix: string boxing goes through msSinkBoxStruct
// (malloc + memcpy + memset-move), the same sink contract structs already use,
// so payload ownership transfers to the box exactly once and the source's
// scope-exit destroy no-ops. This cell also exercises string concat +
// number→string INSIDE the worker (the allocation shapes that made the
// corruption deterministic). acc = 25000 × len("pt-" + (k%10)) = 25000 × 4.
function run(): void {
	let acc = 0;
	let k = 0;
	while (k < 25000) {
		const kk = k % 10;
		const s = await spawn(() => { return "pt-" + kk.toString(); });
		acc = acc + s.length;
		k = k + 1;
	}
	console.log("concat acc=" + acc.toString());
}

run();
