// @stdout: late -2 | awaited late | forwarded boom
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// @xfail(san): a throw in an async finally after its try returned leaks the Error (.inbox/compiler/2026-10-20-c-async-finally-that-throws-after-a-return-loses-the-throw.md)
// note: a throw inside a finally handler rejects the promise finally makes, in place of the value
// or the rejection it would forward: a catch after it receives the handler's Error, and so does
// an await of it.

async function okNum(n: int32): Promise<int32> { await sleepAsync(1); return n; }
async function boomNum(): Promise<int32> { await sleepAsync(1); throw new Error("first"); }

async function run(): Promise<void> {
	const late: int32 = await okNum(1).finally(() => { throw new Error("late"); }).catch((e: Error) => -2);
	let out = `late ${late}`;
	try {
		await okNum(5).finally(() => { throw new Error("late"); });
		out += " | not thrown";
	} catch (e) {
		out += ` | awaited ${e.message}`;
	}
	const forwarded: string = await boomNum().finally(() => { throw new Error("boom"); }).then((n: int32) => "value", (e: Error) => e.message);
	console.log(`${out} | forwarded ${forwarded}`);
}

await run();
