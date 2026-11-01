// @xfail(raiser): raiser runtime error: Unknown host function: msFutureThen
// @stdout: ok
// @stdout: then 1
// @stdout: passed
// @stdout: value 7
async function take(p: Promise<void>): Promise<void> {
	await p;
	console.log("passed");
}

async function run(): Promise<void> {
	const p: Promise<void> = Promise.resolve();
	await p;
	console.log("ok");
	await p;
	await Promise.resolve().then((): void => { console.log("then 1"); });
	await take(Promise.resolve());
	const v = await Promise.resolve(7);
	console.log(`value ${v}`);
}
run();
