async function viaCallee(): Promise<int32> {
	const m = await import("./pure");
	return m.triple(2);
}

async function run(): Promise<void> {
	const direct = await spawn(() => { const m = await import("./pure"); return m.triple(7); });
	const nested = await spawn(() => { const v = await viaCallee(); return v; });
	console.log(`${direct} ${nested}`);
}

run();
