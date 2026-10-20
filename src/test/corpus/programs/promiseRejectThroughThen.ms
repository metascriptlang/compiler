// @stdout: then 100 | string e2! | finally -1 1 | flatten 55 | ran 1
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: a rejection passes through a value-returning `.then` and `.finally` without running the
// then callback and reaches the `.catch` after them, which gives the handler's value: number and
// string payloads, a finally that runs on the way, and a then whose callback returns a promise.

class Counter { n: int32 = 0; }

async function load(n: int32): Promise<int32> { await sleepAsync(1); return n * 2; }

async function run(): Promise<void> {
	const c = new Counter();
	const numberRejected: Promise<int32> = Promise.reject(new Error("e1"));
	const a: int32 = await numberRejected.then((x: int32) => { c.n += 10; return x + 1; }).catch((e: Error) => 100);
	let out = `then ${a}`;
	const stringRejected: Promise<string> = Promise.reject(new Error("e2"));
	const b: string = await stringRejected.then((s: string) => s + "?").catch((e: Error) => e.message + "!");
	out += ` | string ${b}`;
	const finallyRejected: Promise<int32> = Promise.reject(new Error("e3"));
	const f: int32 = await finallyRejected.finally(() => { c.n += 1; }).catch((e: Error) => -1);
	out += ` | finally ${f} ${c.n}`;
	const flattenRejected: Promise<int32> = Promise.reject(new Error("e4"));
	const g: int32 = await flattenRejected.then((x: int32) => load(x)).catch((e: Error) => 55);
	out += ` | flatten ${g}`;
	console.log(`${out} | ran ${c.n}`);
}

await run();
