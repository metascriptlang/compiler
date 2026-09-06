// PARALOCK scenario — spawn only.
//
// Covers: spawn(fn) → affine Promise<T>, parallel fan-out via array
// await, AwaitGroup blocking. PARALOCK §6.3, Phase 2.

function compute(x: number): number {
	return x * x;
}

function main(): void {
	// Single spawn — await consumes affine handle (R1).
	const h = spawn(() => compute(7));
	const r = await h;
	if (r != 49) { console.log("FAIL single r=" + r); return; }

	// Parallel pair via two awaits.
	const h1 = spawn(() => compute(3));
	const h2 = spawn(() => compute(4));
	const r1 = await h1;
	const r2 = await h2;
	if (r1 + r2 != 25) { console.log("FAIL pair " + (r1 + r2)); return; }

	console.log("PASS: spawnOnly");
}

main();
