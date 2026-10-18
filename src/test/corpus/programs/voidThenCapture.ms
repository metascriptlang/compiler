// @stdout: fn 2
// @stdout: one 2
// @stdout: fnValue 2
// @stdout: asyncVoid w2
// @stdout: chain 12
// @stdout: voidChain ab
// @stdout: block 2
// @stdout: deep 2
// @stdout: top 2
// @xfail(raiser): raiser runtime error: Unknown host function: msFutureThen
// note: A `.then` callback on a `Promise<void>` that captures a local reads it through its env. A void parameter has no runtime slot, so the callback's C signature is `(env)`; the runtime called it as `(value, env)`, the callback read the NULL value as its env and crashed on C (drc and orc) while JS printed the right result.

async function work(log: string[]): Promise<void> {
	await sleepAsync(0);
	log.push("w");
}

async function inFunction(): Promise<void> {
	let order = "";
	sleepAsync(0).then((): void => { order += "2"; });
	await sleepAsync(5);
	console.log(`fn ${order}`);

	let one = "";
	await sleepAsync(0).then((v: void): void => { one += "2"; });
	console.log(`one ${one}`);

	let viaValue = "";
	const cb = (): void => { viaValue += "2"; };
	await sleepAsync(0).then(cb);
	console.log(`fnValue ${viaValue}`);

	const log: string[] = [];
	let seen = "";
	await work(log).then((): void => { seen = log.join("") + "2"; });
	console.log(`asyncVoid ${seen}`);

	let chain = "";
	await Promise.resolve(0).then((v: int32): void => { chain += "1"; }).then((): void => { chain += "2"; });
	console.log(`chain ${chain}`);

	let voidChain = "";
	await sleepAsync(0).then((): void => { voidChain += "a"; }).then((): void => { voidChain += "b"; });
	console.log(`voidChain ${voidChain}`);
}

await inFunction();

{
	let block = "";
	await sleepAsync(0).then((): void => { block += "2"; });
	console.log(`block ${block}`);
	if (block.length > 0) {
		let deep = "";
		await sleepAsync(0).then((): void => { deep += "2"; });
		console.log(`deep ${deep}`);
	}
}

let top = "";
await sleepAsync(0).then((): void => { top += "2"; });
console.log(`top ${top}`);
