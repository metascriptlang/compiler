// @stdout: catch handed | thrown raw | try boom | after done
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// @xfail(san): the Error a .catch handler consumes is never destroyed (.inbox/compiler/2026-10-06-catch-handler-never-destroys-the-error.md); the try below destroys one, so the ledger shows it
// note: a .catch handler on a rejected new Promise receives the reject message, and the
// message of a string the executor throws, on every backend.

async function run(): Promise<void> {
	let handed = "";
	await new Promise<void>((resolve, reject) => { reject(new Error("handed")); }).catch((e: string): void => { handed = e; });
	let out = `catch ${handed}`;

	let thrown = "";
	await new Promise<void>((resolve) => { throw "raw"; }).catch((e: string): void => { thrown = e; });
	out += ` | thrown ${thrown}`;

	try { await new Promise<int32>((resolve, reject) => { reject(new Error("boom")); }); out += " | try lost"; }
	catch (e) { out += ` | try ${(e as Error).message}`; }
	console.log(out + " | after done");
}

await run();
