// @stdout: counter 11 12
// @stdout: text ready-5 7
// note: an await of the future its own call made is that future's only reader, so it takes the value; the async function's frame keeps its future, and a closure in the value that shares that frame no longer makes a cycle through it.
class Counter {
	step: () => int32;
	constructor(step: () => int32) {
		this.step = step;
	}
}

async function work(x: int32): Promise<int32> {
	return x;
}

async function makeCounter(): Promise<Counter> {
	let n: int32 = await work(10);
	return new Counter((): int32 => {
		n = n + 1;
		return n;
	});
}

async function makeText(): Promise<string> {
	const w = await work(5);
	return `ready-${w}`;
}

async function main(): Promise<void> {
	const c = await makeCounter();
	const a = c.step();
	const b = c.step();
	console.log(`counter ${a} ${b}`);
	const t = await makeText();
	console.log(`text ${t} ${t.length}`);
}

await main();
