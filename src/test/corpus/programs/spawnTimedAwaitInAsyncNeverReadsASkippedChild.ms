// @stdout: timeout 0: 300 of 300 settled, 0 silent defaults
// @stdout: timeout 1: 300 of 300 settled, 0 silent defaults
// @exit: 0
// @xfail(raiser): raiser error: 'spawn' from 'std/core/promise' cannot run on the Raiser: no host bridge for 'msSpawn'; it runs on C and JS
// note: a timed spawn awaited in an async routine either returns the child's value or throws; a child the deadline skipped before it started is never read as the type's default (a candidate that compared the settle time with `>` returned the default 292 times in 300 at timeout 0)

function slow(): int32 {
	const until = Date.now() + 2;
	let n: int32 = 0;
	while (Date.now() < until) n = (n + 1) % 7;
	return 5;
}

async function once(ms: int32): Promise<int32> {
	try {
		return await spawn((): int32 => slow(), { timeout: ms });
	} catch (e) {
		return -1;
	}
}

async function main(): Promise<void> {
	for (let ms: int32 = 0; ms < 2; ms++) {
		let settled = 0;
		let silent = 0;
		for (let i = 0; i < 300; i++) {
			const r = await once(ms);
			if (r == -1 || r == 5) settled++;
			else silent++;
		}
		console.log(`timeout ${ms}: ${settled} of 300 settled, ${silent} silent defaults`);
	}
}

await main();
