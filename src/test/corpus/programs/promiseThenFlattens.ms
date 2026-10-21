// @stdout: num 6 | text a!! | pair 3 p3 | chain 14 | void 7 | named 6 | nested 8 | rejected boom 2 | thrown bad 1
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: a then callback that returns a Promise<U> gives a Promise<U>, one level flattened as in
// TypeScript, for number, string and struct payloads, a chain of them, a void input, a named
// callback and a rejection or a throw inside the callback.

struct Pair { n: int32; tag: string; }

async function loadNum(n: int32): Promise<int32> { await sleepAsync(1); return n * 2; }
async function loadText(s: string): Promise<string> { await sleepAsync(1); return s + "!"; }
async function loadPair(n: int32): Promise<Pair> { await sleepAsync(1); return { n: n, tag: "p" + n.toString() }; }
async function unit(): Promise<void> { await sleepAsync(1); }
async function reject(n: int32): Promise<int32> { await sleepAsync(1); throw new Error("boom " + n.toString()); }

function plusOne(x: int32): Promise<int32> { return loadNum(x + 1); }

async function run(): Promise<void> {
	const num: int32 = await loadNum(1).then((x: int32) => loadNum(x + 1));
	let out = `num ${num}`;
	const text: string = await loadText("a").then((s: string) => loadText(s));
	out += ` | text ${text}`;
	const pair: Pair = await loadNum(1).then((x: int32) => loadPair(x + 1));
	out += ` | pair ${pair.n} ${pair.tag}`;
	const chain: int32 = await loadNum(1).then((x: int32) => loadNum(x)).then((x: int32) => loadNum(x + 3));
	out += ` | chain ${chain}`;
	const fromVoid: int32 = await unit().then(() => loadNum(3)).then((x: int32) => x + 1);
	out += ` | void ${fromVoid}`;
	const named: int32 = await loadNum(1).then(plusOne);
	out += ` | named ${named}`;
	const nested: int32 = await loadNum(1).then((x: int32) => loadNum(x).then((y: int32) => loadNum(y)));
	out += ` | nested ${nested}`;
	try {
		await loadNum(1).then((x: int32) => reject(x));
	} catch (e) {
		out += ` | rejected ${e.message}`;
	}
	try {
		await loadNum(0).then((x: int32): Promise<int32> => { throw new Error("bad " + (x + 1).toString()); });
	} catch (e) {
		out += ` | thrown ${e.message}`;
	}
	console.log(out);
}

await run();
