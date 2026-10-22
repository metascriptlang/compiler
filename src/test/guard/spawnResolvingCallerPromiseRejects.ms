// @xfail(c): resolving main's promise from a spawn task runs main's .then on the worker, concurrently with main's synchronous code, so the total loses updates (PARALOCK-runtime Amendment R)
// @xfail(danger): resolving main's promise from a spawn task runs main's .then on the worker, concurrently with main's synchronous code, so the total loses updates (PARALOCK-runtime Amendment R)
// @xfail(raiser): raiser runtime error: Unknown host function: msFutureThen
// @serial

class Box { n: int64 = 0; }

const total = new Box();
const one = new Box();

async function main(): Promise<void> {
	one.n = 1;
	let res: ((v: int32) => void) | null = null;
	const p = new Promise<int32>((resolve: (v: int32) => void): void => { res = resolve; });
	const r = res!;
	p.then((v: int32): void => {
		for (let i = 0; i < 1000000; i++) total.n += one.n;
		console.log(`then v${v}`);
	});
	const h = spawn(() => { r(5); return 1; });
	for (let i = 0; i < 3000000; i++) total.n += one.n;
	console.log("main loop done");
	console.log(`spawned ${await h}`);
	console.log(`awaited ${await p} total ${total.n}`);
}

main();
