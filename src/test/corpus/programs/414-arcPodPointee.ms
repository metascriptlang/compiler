// @skip-js: Arc<T> has no js binding (atomic-rc box is C-only, PARALOCK tier 2/3) - same as 405/406
// note: Arc<POD pointee> regression - until 2026-09-03 (Amendment I step 0) every
// `new Arc<PODStruct>` died at LINK: the weak Arc cell TypeInfo wired the pointee's
// destroyFn, but a POD struct's destroy hook is dropped by reachability (a POD temp
// gets no analyzer destroy call, so no AST edge keeps the hook alive) - undefined
// `XDestroy`. Fix: the cell wires destroyFn only when the pointee carries owned refs
// (the same predicate the ref-array cell uses); destroyFn == NULL is the documented
// "no RC fields" convention (runtime/types.h). This program builds, links, and
// round-trips a POD pointee through spawn fan-out on every lane; total=8400 pins
// the value round-trip (100 rounds x 2 tasks x 42).

struct PodCell { n: int32; }

function bump(a: Arc<PodCell>): int32 { return a.n + 1; }

function main(): void {
	const a: Arc<PodCell> = new Arc({ n: 41 });
	let total = 0;
	for (let r = 0; r < 100; r = r + 1) {
		const h1 = spawn(() => bump(a));
		const h2 = spawn(() => bump(a));
		const x = await h1;
		const y = await h2;
		total = total + x + y;
	}
	console.log(`arc-pod total=${total}`);
}

main();
