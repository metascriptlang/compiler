// @stdout: after-await 7
// @stdout: loop 11 33 66
// @stdout: gen 1 2
// @stdout: makers 101 112 123
// @stdout: crossing 1 2 9
// @stdout: crossing-async 5
// @stdout: between-async 5
// @stdout: abandoned 1 2
// @stdout: routine-loop 1 3 5 6
// @stdout: routine-pair 1 7
// @stdout: routine-text a ab abb
// @stdout: same-state 1 42 42
// @stdout: escaped 12 13 14
// @xfail(raiser): the Raiser VM cannot evaluate std/core/struct.ms INITIAL_CAPACITY at comptime
// note: a closure made inside an async function or a generator shares the function's variables: writes through it are seen by the function and by later closures. Before the fix C gave every closure made in the state machine a private copy of what it captured, so `count` stayed 0 after an await, a `.then` callback's write was lost and a generator's `seen` never moved. A nested `function` or `const` arrow is never stored in the machine: every resume rebuilds it over the machine's variables, so it does not keep the machine alive whether it is made before a suspension, between two, inside a suspending loop, yielded out, or still in scope when the caller stops early. A closure held in a `let` is a value the machine stores and is not covered here.

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

function* crossing(): Iterator<int32> {
	let seen: int32 = 0;
	function bump(): void { seen = seen + 1; }
	yield 1;
	bump();
	bump();
	yield seen;
	yield 9;
}

async function crossingAsync(): Promise<int32> {
	let total: int32 = 0;
	const add = (k: int32): void => { total = total + k; };
	await work(1);
	add(2);
	add(3);
	return total;
}

async function betweenAwaits(): Promise<int32> {
	let total: int32 = 0;
	await work(1);
	function add(k: int32): void { total = total + k; }
	add(2);
	add(3);
	await work(2);
	return total;
}

function* abandoned(): Iterator<int32> {
	let seen: int32 = 0;
	const bump = (): void => { seen = seen + 1; };
	yield 1;
	bump();
	bump();
	yield seen;
	yield 9;
}

function* routineLoop(): Iterator<int32> {
	let seen: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		const bump = (): void => { seen = seen + 1; };
		bump();
		yield seen;
		bump();
	}
	yield seen;
}

function* routinePair(): Iterator<int32> {
	let seen: int32 = 0;
	const add = (k: int32): void => { seen = seen + k; };
	const twice = (k: int32): void => { add(k); add(k); };
	yield 1;
	twice(3);
	add(1);
	yield seen;
}

function* routineText(): Iterator<string> {
	let text = "a";
	const grow = (): void => { text = text + "b"; };
	yield text;
	grow();
	yield text;
	grow();
	yield text;
}

function* sameState(): Iterator<int32> {
	yield 1;
	let base: int32 = 40;
	const read = (): int32 => base + 2;
	yield read();
	yield read();
}

function* escaping(): Iterator<Get> {
	let seen: int32 = 10;
	const bump = (): int32 => { seen = seen + 1; return seen; };
	yield bump;
	bump();
	yield bump;
}

function expectInt(label: string, actual: int32, expected: int32): void {
	if (actual != expected) throw new Error(label + " expected=" + expected.toString() + " actual=" + actual.toString());
}

function expectStr(label: string, actual: string, expected: string): void {
	if (actual != expected) throw new Error(label + " expected=" + expected + " actual=" + actual);
}

async function main(): Promise<void> {
	const a = await afterAwait();
	expectInt("afterAwait", a, 7);
	console.log(`after-await ${a}`);
	const fs = await loopAfterAwait();
	let s = "loop";
	for (const f of fs) s = s + ` ${f()}`;
	expectStr("loopAfterAwait", s, "loop 11 33 66");
	console.log(s);
	const t = await thenWrites();
	expectInt("thenWrites", t, 10);
	console.log(`then ${t}`);
	let g = "gen";
	for (const v of bumps()) g = g + ` ${v}`;
	expectStr("bumps", g, "gen 1 2");
	console.log(g);
	const saved: Get[] = [];
	for (const f of makers()) saved.push(f);
	let m = "makers";
	for (const f of saved) m = m + ` ${f()}`;
	expectStr("makers", m, "makers 101 112 123");
	console.log(m);
	let c = "crossing";
	for (const v of crossing()) c = c + ` ${v}`;
	expectStr("crossing", c, "crossing 1 2 9");
	console.log(c);
	const ca = await crossingAsync();
	expectInt("crossingAsync", ca, 5);
	console.log(`crossing-async ${ca}`);
	const ba = await betweenAwaits();
	expectInt("betweenAwaits", ba, 5);
	console.log(`between-async ${ba}`);
	let ab = "abandoned";
	for (const v of abandoned()) {
		ab = ab + ` ${v}`;
		if (v == 2) break;
	}
	expectStr("abandoned", ab, "abandoned 1 2");
	console.log(ab);
	let rl = "routine-loop";
	for (const v of routineLoop()) rl = rl + ` ${v}`;
	expectStr("routineLoop", rl, "routine-loop 1 3 5 6");
	console.log(rl);
	let rp = "routine-pair";
	for (const v of routinePair()) rp = rp + ` ${v}`;
	expectStr("routinePair", rp, "routine-pair 1 7");
	console.log(rp);
	let rt = "routine-text";
	for (const v of routineText()) rt = rt + ` ${v}`;
	expectStr("routineText", rt, "routine-text a ab abb");
	console.log(rt);
	let ss = "same-state";
	for (const v of sameState()) ss = ss + ` ${v}`;
	expectStr("sameState", ss, "same-state 1 42 42");
	console.log(ss);
	const escaped: Get[] = [];
	for (const f of escaping()) escaped.push(f);
	const es = `escaped ${escaped[0]()} ${escaped[1]()} ${escaped[0]()}`;
	expectStr("escaping", es, "escaped 12 13 14");
	console.log(es);
}

await main();
