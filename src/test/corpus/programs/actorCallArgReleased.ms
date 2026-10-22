// @stdout: named 3
// @stdout: destroyed=1
// @stdout: inline 3
// @stdout: destroyed=2
// @stdout: loop 12
// @stdout: destroyed=3
// @stdout: twice 6
// @stdout: destroyed=4
// @stdout: array 3
// @stdout: both inline 6
// @stdout: destroyed=6
// @exit: 0
// @skip-js: onDestroy runs where the DRC runs; JS has no destructors
// @xfail(raiser): raiser runs no user lifecycle hooks and has no actors
// @ledger-slack(Tally) 1
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// note: an object lent to an awaited actor CALL from an async function is released once, by its owner, after the reply (old compiler: the caller increfed it into the message and nothing released it, one object leaked per call)

class State { count: int32 = 0; }

let destroyed = 0;
function onDestroy(this s: State): void { destroyed += 1; }

actor Tally {
	seen: int32 = 0;
	take(s: State): int32 { return s.count + 3; }
	both(a: State, b: State): int32 { return a.count + b.count + 6; }
	size(xs: int32[]): int32 { return xs.length; }
}

async function named(w: Tally): Promise<void> {
	const st = new State();
	const k = await w.take(st);
	console.log(`named ${k}`);
}

async function inline(w: Tally): Promise<void> {
	const k = await w.take(new State());
	console.log(`inline ${k}`);
}

async function loop(w: Tally): Promise<void> {
	const st = new State();
	let sum = 0;
	for (let i = 0; i < 4; i += 1) sum += await w.take(st);
	console.log(`loop ${sum}`);
}

async function twice(w: Tally): Promise<void> {
	const st = new State();
	const k = await w.both(st, st);
	console.log(`twice ${k}`);
}

async function array(w: Tally): Promise<void> {
	const xs: int32[] = [1, 2, 3];
	const k = await w.size(xs);
	console.log(`array ${k}`);
}

function makeState(): State { return new State(); }

async function bothInline(w: Tally): Promise<void> {
	const k = await w.both(new State(), makeState());
	console.log(`both inline ${k}`);
}

async function main(): Promise<void> {
	const w = new Tally();
	await named(w);
	console.log(`destroyed=${destroyed}`);
	await inline(w);
	console.log(`destroyed=${destroyed}`);
	await loop(w);
	console.log(`destroyed=${destroyed}`);
	await twice(w);
	console.log(`destroyed=${destroyed}`);
	await array(w);
	await bothInline(w);
	console.log(`destroyed=${destroyed}`);
}

await main();
