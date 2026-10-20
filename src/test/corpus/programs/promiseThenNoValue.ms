// @stdout: void 1 | int 11 | text 111 | chain 1111 | after done
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: a then callback written with no parameter ignores the value whatever the promise holds:
// a Promise<void> has none, a number or a string has one the callback does not name. The
// callbacks capture a local, so they run with their environment.

class Counter { n: int32 = 0; }

async function load(n: int32): Promise<int32> { await sleepAsync(1); return n; }
async function text(): Promise<string> { await sleepAsync(1); return "s"; }

async function run(): Promise<void> {
	const c = new Counter();
	await sleepAsync(1).then(() => { c.n += 1; });
	let out = `void ${c.n}`;
	await load(1).then(() => { c.n += 10; });
	out += ` | int ${c.n}`;
	await text().then(() => { c.n += 100; });
	out += ` | text ${c.n}`;
	await load(1).then(() => c.n + 1000).then((v: int32) => { c.n = v; });
	out += ` | chain ${c.n}`;
	console.log(out + " | after done");
}

await run();
