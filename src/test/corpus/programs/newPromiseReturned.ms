// @stdout: int 6 | text six | pair 6 six | void ok | pending made | after done
// note: a plain function that returns new Promise<T>(...) types the executor from T like any
// other position, for every T; one that never settles still makes its promise.

struct Pair { n: int32; tag: string; }

function makeInt(n: int32): Promise<int32> { return new Promise<int32>((resolve) => { resolve(n); }); }
function makeText(s: string): Promise<string> { return new Promise<string>((resolve, reject) => { resolve(s); }); }
function makePair(n: int32, s: string): Promise<Pair> { return new Promise<Pair>((resolve) => { resolve({ n: n, tag: s }); }); }
function makeVoid(): Promise<void> { return new Promise<void>((resolve) => { resolve(); }); }
function never(): Promise<int32> { return new Promise<int32>((resolve, reject) => {}); }

async function run(): Promise<void> {
	let out = `int ${await makeInt(6)}`;
	out += ` | text ${await makeText("six")}`;
	const p = await makePair(6, "six");
	out += ` | pair ${p.n} ${p.tag}`;
	await makeVoid();
	out += " | void ok";
	const pending = never();
	out += " | pending made";
	console.log(out + " | after done");
}

await run();
