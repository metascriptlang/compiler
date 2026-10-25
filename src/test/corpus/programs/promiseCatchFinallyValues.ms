// @stdout: num 7 5 | text fallback hi | pair 4 p4 4 p4 p4 | caught 9 caught | reject plain! | finally 5 -1 sss 2 p2 count 4 | thrown -3 | two 3 2 from f g bad 9 8
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: catch gives a Promise<T> whose value is the handler's result on a rejection and the
// input's value otherwise; finally forwards the input's value or rejection after its handler
// ran, and a throw inside the catch handler rejects the result. A two-callback then runs its second
// callback only for the input's rejection: a throw in the first one skips it and reaches the next
// catch. A rejection with a catch attached is handled, so the unread one at the end leaves the
// exit code 0. Number, string and struct payloads; the struct promise is awaited again after it
// was forwarded.

struct Pair { n: int32; tag: string; }
class Counter { n: int32 = 0; }

async function okNum(n: int32): Promise<int32> { await sleepAsync(1); return n; }
async function boomNum(n: int32): Promise<int32> { await sleepAsync(1); throw new Error("boom " + n.toString()); }
async function okText(s: string): Promise<string> { await sleepAsync(1); return s; }
async function boomText(): Promise<string> { await sleepAsync(1); throw new Error("boom"); }
async function makePair(n: int32): Promise<Pair> { await sleepAsync(1); return { n: n, tag: "p" + n.toString() }; }
async function boomPair(): Promise<Pair> { await sleepAsync(1); throw new Error("boom"); }

async function run(): Promise<void> {
	const a: int32 = await boomNum(1).catch((e: Error) => 7);
	const b: int32 = await okNum(5).catch((e: Error) => 7);
	let out = `num ${a} ${b}`;
	const t1: string = await boomText().catch((e: Error) => "fallback");
	const t2: string = await okText("hi").catch((e: Error) => "x");
	out += ` | text ${t1} ${t2}`;
	const p = makePair(4);
	const q = p.catch((e: Error): Pair => ({ n: 0, tag: "none" }));
	const q1 = await q;
	const q2 = await q;
	out += ` | pair ${q1.n} ${q1.tag} ${q2.n} ${q2.tag} ${(await p).tag}`;
	const bp: Pair = await boomPair().catch((e: Error): Pair => ({ n: 9, tag: "caught" }));
	out += ` | caught ${bp.n} ${bp.tag}`;
	const plain: Promise<string> = Promise.reject(new Error("plain"));
	const r: string = await plain.catch((e: Error) => e.message + "!");
	out += ` | reject ${r}`;
	const c = new Counter();
	const f1: int32 = await okNum(5).finally(() => { c.n += 1; });
	const f2: int32 = await boomNum(1).finally(() => { c.n += 1; }).catch((e: Error) => -1);
	const ps = okText("s");
	const fs = ps.finally(() => { c.n += 1; });
	const f3: string = (await fs) + (await fs) + (await ps);
	const f4: Pair = await makePair(2).finally(() => { c.n += 1; });
	out += ` | finally ${f1} ${f2} ${f3} ${f4.n} ${f4.tag} count ${c.n}`;
	const again: int32 = await boomNum(1).catch((e: Error): int32 => { throw new Error("again"); }).catch((e: Error) => -3);
	out += ` | thrown ${again}`;
	let routed = "";
	const fromF: int32 = await okNum(3).then((v: int32) => v, (e: Error) => -9);
	const fromG: int32 = await boomNum(1).then((v: int32) => v, (e: Error) => 2);
	const fThrows: int32 = await okNum(3)
		.then((v: int32): int32 => { throw new Error("from f"); }, (e: Error): int32 => { routed += "g ran "; return -9; })
		.catch((e: Error): int32 => { routed += e.message; return 9; });
	const gThrows: int32 = await boomNum(1)
		.then((v: int32) => v, (e: Error): int32 => { throw new Error("g bad"); })
		.catch((e: Error): int32 => { routed += " " + e.message; return 8; });
	out += ` | two ${fromF} ${fromG} ${routed} ${fThrows} ${gThrows}`;
	const ignored: Promise<int32> = Promise.reject(new Error("ignored"));
	ignored.catch((e: Error) => 0);
	await sleepAsync(2);
	console.log(out);
}

await run();
