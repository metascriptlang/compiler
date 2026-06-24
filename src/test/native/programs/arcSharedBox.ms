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
// to test-ms — Bun never runs the atomic C rc.

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
