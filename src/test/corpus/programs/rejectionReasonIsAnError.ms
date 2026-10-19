// Every rejection reaches its reader as an Error on every backend: a string reason becomes an
// Error carrying it as the message, an Error (a subclass too) passes as it is, whether the
// promise comes from Promise.reject, the executor's reject or an async function that returns
// a rejection, and whether the reader is try/catch around an await, .catch or the second
// callback of .then. A .then rejection handler sees only the input's rejection; a throw from
// the fulfilled callback fails the promise .then returns.
// @xfail(raiser): raiser-solid owns Raiser Promise APIs (no host bridge for then/catch)
// @stdout: await reject: boom|catch reject: boom|then reject: boom|await executor: boom|catch executor: boom|then executor: boom
// @stdout: await returned: boom|await returned error: rich|catch coded 7|then coded 7|out from fulfilled|done

class CodeError extends Error {
	code: int32;
	constructor(message: string, code: int32) {
		super(message);
		this.code = code;
	}
}

async function returnsRejection(): Promise<int32> { return Promise.reject("boom"); }
async function returnsRejectedError(): Promise<int32> { return Promise.reject(new Error("rich")); }

function executorRejects(): Promise<int32> {
	return new Promise<int32>((resolve, reject) => { reject("boom"); });
}

function coded(e: Error): string {
	if (e instanceof CodeError) return `coded ${(e as CodeError).code}`;
	return `plain ${e.message}`;
}

async function run(): Promise<void> {
	let log = "";
	try { await Promise.reject("boom"); log += "lost|"; } catch (e) { log += `await reject: ${e.message}|`; }
	const caught: Promise<int32> = Promise.reject("boom");
	await caught.catch((e: Error): void => { log += `catch reject: ${e.message}|`; });
	const thened: Promise<int32> = Promise.reject("boom");
	await thened.then((v: int32): void => { log += "lost|"; }, (e: Error): void => { log += `then reject: ${e.message}|`; });

	try { await executorRejects(); log += "lost|"; } catch (e) { log += `await executor: ${e.message}|`; }
	await executorRejects().catch((e: Error): void => { log += `catch executor: ${e.message}|`; });
	await executorRejects().then((v: int32): void => { log += "lost|"; }, (e: Error): void => { log += `then executor: ${e.message}|`; });
	console.log(log);

	log = "";
	try { await returnsRejection(); log += "lost|"; } catch (e) { log += `await returned: ${e.message}|`; }
	try { await returnsRejectedError(); log += "lost|"; } catch (e) { log += `await returned error: ${e.message}|`; }
	const sub: Promise<string> = Promise.reject(new CodeError("sub", 7));
	await sub.catch((e: Error): void => { log += `catch ${coded(e)}|`; });
	await sub.then((v: string): void => { log += "lost|"; }, (e: Error): void => { log += `then ${coded(e)}|`; });
	const fine: Promise<int32> = Promise.resolve(1);
	try {
		await fine.then((v: int32): void => { throw new Error("from fulfilled"); }, (e: Error): void => { log += "lost|"; });
	} catch (e) { log += `out ${e.message}|`; }
	console.log(`${log}done`);
}

await run();
