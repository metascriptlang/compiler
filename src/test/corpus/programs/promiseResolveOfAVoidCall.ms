// @stdout: g ran 1
// @stdout: direct resolved
// @stdout: g ran 2
// @stdout: generic resolved
// @stdout: g ran 3
// @stdout: then after void 3
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
class Counter { n: int32 = 0; }
const c = new Counter();

function g(): void {
	c.n += 1;
	console.log(`g ran ${c.n}`);
}

function wrap<R>(f: () => R): Promise<R> {
	return Promise.resolve(f());
}

async function main(): Promise<void> {
	await Promise.resolve(g());
	console.log("direct resolved");
	await wrap(g);
	console.log("generic resolved");
	await Promise.resolve(g()).then(() => { console.log(`then after void ${c.n}`); });
}
await main();
