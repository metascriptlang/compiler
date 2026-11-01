// @stdout: value 499500
// @stdout: returned 499500
// @stdout: void done
// @stdout: group 499500 499500
// @exit: 0
// @xfail(raiser): raiser runtime error: Unknown host function: msSpawn
// note: an async routine awaits a timed spawn by yielding until it settles, as a value, a returned await, a discarded void result and in Promise.all (old compiler: the C build failed, msSpawn given two arguments)

function spin(): int32 {
	let s = 0;
	for (let i = 0; i < 1000; i++) s += i;
	return s;
}

async function returned(): Promise<int32> {
	return await spawn(() => spin(), { timeout: 5000 });
}

async function main(): Promise<void> {
	console.log(`value ${await spawn(() => spin(), { timeout: 5000 })}`);
	console.log(`returned ${await returned()}`);
	await spawn((): void => { spin(); }, { timeout: 5000 });
	console.log("void done");
	const g = await Promise.all([spawn(() => spin(), { timeout: 5000 }), spawn(() => spin())]);
	console.log(`group ${g[0]} ${g[1]}`);
}

await main();
