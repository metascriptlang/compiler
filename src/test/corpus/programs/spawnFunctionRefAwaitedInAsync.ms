// @stdout: timed 499500
// @stdout: group 999000
// @stdout: timed group 999000
// @exit: 0
// @xfail(raiser): raiser error: 'spawn' from 'std/core/promise' cannot run on the Raiser: no host bridge for 'msSpawn'; it runs on C and JS
// note: an async routine awaits spawns of a bare function reference returning a primitive: a timed one, and two in Promise.all with and without a deadline (old compiler: the C build failed, the group thunk returned int32_t from a void* closure)

function spin(): int32 {
	let s = 0;
	for (let i = 0; i < 1000; i++) s += i;
	return s;
}

async function main(): Promise<void> {
	console.log(`timed ${await spawn(spin, { timeout: 5000 })}`);
	const g = await Promise.all([spawn(spin), spawn(spin)]);
	console.log(`group ${g[0] + g[1]}`);
	const t = await Promise.all([spawn(spin, { timeout: 5000 }), spawn(spin)]);
	console.log(`timed group ${t[0] + t[1]}`);
}

await main();
