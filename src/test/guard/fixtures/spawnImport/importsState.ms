async function viaCallee(): Promise<int32> {
	const m = await import("./stateful");
	return m.bump();
}

async function run(): Promise<void> {
	const direct = await spawn(() => { const m = await import("./stateful"); return m.bump(); });
	const nested = await spawn(() => { const v = await viaCallee(); return v; });
	console.log(`${direct} ${nested}`);
}

run();
