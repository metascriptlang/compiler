// @stdout: single timed out after the child
// @stdout: group timed out after the children
// @exit: 0
// @skip-js: the JS spawn runs its thunk in one microtask and takes no deadline
// @skip-raiser
// note: an async routine whose timed spawn outlives the deadline throws once the children settle, alone and in Promise.all (old compiler: the single form failed to build, the group returned its late values)

function slow(): int32 {
	const until = Date.now() + 300;
	let n: int32 = 0;
	while (Date.now() < until) n = (n + 1) % 7;
	return 5;
}

async function single(): Promise<string> {
	const t0 = Date.now();
	try {
		const v = await spawn((): int32 => slow(), { timeout: 20 });
		return `single returned ${v}`;
	} catch (e) {
		return Date.now() - t0 >= 250 ? "single timed out after the child" : "single timed out before the child";
	}
}

async function group(): Promise<string> {
	const t0 = Date.now();
	try {
		const g = await Promise.all([spawn((): int32 => slow(), { timeout: 20 }), spawn((): int32 => slow())]);
		return `group returned ${g[0] + g[1]}`;
	} catch (e) {
		return Date.now() - t0 >= 250 ? "group timed out after the children" : "group timed out before the children";
	}
}

console.log(await single());
console.log(await group());
