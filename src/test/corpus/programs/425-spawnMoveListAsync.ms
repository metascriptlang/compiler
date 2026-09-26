class Counter {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

async function movedWrite(): Promise<int32> {
	const c = new Counter(7);
	const h = spawn(() => { c.n = c.n + 2; return c.n; }, { move: [c] });
	return await h;
}

async function movedBesideBorrow(): Promise<int32> {
	const c = new Counter(1);
	const size = 8;
	const h = spawn(() => { c.n = c.n * 10; return c.n + size; }, { move: [c] });
	return await h;
}

console.log(`moved-write v=${await movedWrite()}`);
console.log(`moved-beside-borrow v=${await movedBesideBorrow()}`);
