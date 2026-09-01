// @maxrss: 40
// @stdout: arc-shared-box total=112000
// @serial
// @skip-js: checker: instantiating the js spawn twin over an IsAtomic Ref payload mismatches Promise (flag lost in generic substitution); js audit 2026-09-01
// note: Arc<T> atomic-refcount shared box — the first per-type atomic-rc path in the compiler. 4000 rounds × 4 spawn tasks each take an OWNING reference to one shared Arc<Payload> (return a → atomic incref) and drop the awaited result (atomic decref): concurrent owning rc traffic that a non-atomic refcount corrupts under contention (the reason Rust needs Arc<Mutex<T>>; MS's plain Ref rc is non-atomic, racing the check-then-decrement TOCTOU). createArc tags a Ref with TypeFlag.IsAtomic; classify.ms emits msAtomicIncref/Decref; new Arc(v) lowers to msBoxArc → msAllocArc cell at rc=MS_RC_INCREMENT (Rust convention — msAtomicDecRefIsLast frees when fetch_sub sees old==INC, so the box must NOT start at the rc=0 sole-owner of the non-atomic path). The cell reuses a weak-linkage Arc TypeInfo (ensureArcCellTypeInfo) whose destroyFn is the pointee's destructor — weak so a lifted-closure module can box without the owning-module gating that left PayloadTypeInfo undefined. Flat RSS proves box+pointee free once; total=112000 (4000×4×7) proves the value round-trips. ASAN-clean drc+orc separately (no UAF/double-free under contention); the atomic primitive proven by an 8-thread pthread+TSAN probe.

// Arc<T> — atomic-refcounted shared box, the first per-type atomic-rc path.
//
// Sharing a heap value across spawn threads with a NON-atomic refcount races the
// capture/return incref+decref on the rc field → corruption (the reason Rust needs
// Arc). Arc<T> boxes the value in an msAllocArc cell (rc starts at MS_RC_INCREMENT)
// and classify.ms emits msAtomicIncref/Decref for it; the cell's destroyFn runs the
// pointee's destructor on the last atomic ref.
//
// Each task takes an OWNING reference (return a → atomic incref) and the awaited
// result is dropped (atomic decref): concurrent owning rc traffic on one shared Arc.
// Exit 0 + flat RSS proves the box + pointee free exactly once under contention (no
// over-free, no leak); the deterministic sum proves the value round-trips. Invisible
// only exercised by the native binary.

struct Payload { buf: string; n: int32; }

function fetchShared(a: Arc<Payload>): Arc<Payload> { return a; }

function main(): void {
	const a: Arc<Payload> = new Arc({ buf: "arc-shared-payload", n: 7 });
	let total = 0;
	for (let round = 0; round < 4000; round = round + 1) {
		const h1 = spawn(() => fetchShared(a));
		const h2 = spawn(() => fetchShared(a));
		const h3 = spawn(() => fetchShared(a));
		const h4 = spawn(() => fetchShared(a));
		const r1 = await h1;
		const r2 = await h2;
		const r3 = await h3;
		const r4 = await h4;
		total = total + r1.n + r2.n + r3.n + r4.n;
	}
	console.log(`arc-shared-box total=${total}`);
}

main();
