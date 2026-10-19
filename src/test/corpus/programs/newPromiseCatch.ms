// @stdout: catch handed | thrown raw | try boom | after done
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: a .catch handler on a rejected new Promise receives the Error it rejected with, and an
// Error carrying a string the executor throws, on every backend.

async function run(): Promise<void> {
	let handed = "";
	await new Promise<void>((resolve, reject) => { reject(new Error("handed")); }).catch((e: Error): void => { handed = e.message; });
	let out = `catch ${handed}`;

	let thrown = "";
	await new Promise<void>((resolve) => { throw "raw"; }).catch((e: Error): void => { thrown = e.message; });
	out += ` | thrown ${thrown}`;

	try { await new Promise<int32>((resolve, reject) => { reject(new Error("boom")); }); out += " | try lost"; }
	catch (e) { out += ` | try ${(e as Error).message}`; }
	console.log(out + " | after done");
}

await run();
