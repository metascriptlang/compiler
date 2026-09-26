// @stdout: after-await 7
// @stdout: loop 11 33 66
// @stdout: gen 1 2
// @stdout: makers 101 112 123
// note: a closure made inside an async function or a generator shares the function's variables: writes through it are seen by the function and by later closures. Before the fix C gave every closure made in the state machine a private copy of what it captured, so `count` stayed 0 after an await, a `.then` callback's write was lost and a generator's `seen` never moved. A local that one state alone touches stays a local of that state, so a closure stored in it does not keep the machine alive.

type Get = () => int32;

async function work(x: int32): Promise<int32> {
	return x * 2;
}

async function afterAwait(): Promise<int32> {
	let count: int32 = 0;
	const v = await work(1);
	const add = (k: int32): void => { count = count + k; };
	add(v);
	add(5);
	return count;
}

async function loopAfterAwait(): Promise<Get[]> {
	let total: int32 = 0;
	const w = await work(5);
	const fs: Get[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		let j: int32 = i * 10;
		fs.push((): int32 => { total = total + i + j + w; return total; });
		j = j + 1;
	}
	return fs;
}

async function thenWrites(): Promise<int32> {
	let local: int32 = 0;
	const p = work(5).then((v: int32): void => { local = v; });
	await p;
	return local;
}

function* bumps(): Iterator<int32> {
	let seen: int32 = 0;
	yield 1;
	const bump = (): void => { seen = seen + 1; };
	bump();
	bump();
	yield seen;
}

function* makers(): Iterator<Get> {
	let base: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		const j: int32 = i * 10 + 1;
		yield (): int32 => base + i + j;
	}
	base = 100;
}

async function main(): Promise<void> {
	const a = await afterAwait();
	console.log(`after-await ${a}`);
	const fs = await loopAfterAwait();
	let s = "loop";
	for (const f of fs) s = s + ` ${f()}`;
	console.log(s);
	const t = await thenWrites();
	console.log(`then ${t}`);
	let g = "gen";
	for (const v of bumps()) g = g + ` ${v}`;
	console.log(g);
	const saved: Get[] = [];
	for (const f of makers()) saved.push(f);
	let m = "makers";
	for (const f of saved) m = m + ` ${f()}`;
	console.log(m);
}

await main();
