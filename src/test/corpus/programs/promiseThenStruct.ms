// @stdout: then 2,3 | text a:1 | handled 5 1 | direct 9 | two 4,0 -1,2
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: A then or catch callback that returns an object literal, under a destination that
// names the struct (const p: Promise<Pt> = ...), builds that struct, as it does for a plain call;
// so do both callbacks of a two-callback then, on a fulfilled and on a rejected input.

struct Pt { x: int32; y: int32; }
struct Tagged { tag: string; n: int32; }

async function run(): Promise<void> {
	const p: Promise<Pt> = Promise.resolve(2).then((n) => ({ x: n, y: n + 1 }));
	const a = await p;
	const t: Promise<Tagged> = Promise.resolve("a").then((s) => ({ tag: s + ":1", n: 1 }));
	const b = await t;
	const rejected: Promise<Pt> = Promise.reject(new Error("e"));
	const h: Promise<Pt> = rejected.catch((e) => ({ x: 5, y: e.message.length }));
	const c = await h;
	const d: Promise<Pt> = Promise.resolve(4).then((n): Pt => ({ x: n + 5, y: 0 }));
	const q: Promise<Pt> = Promise.resolve(4).then((n) => ({ x: n, y: 0 }), (e) => ({ x: -1, y: -1 }));
	const failed: Promise<Pt> = Promise.reject(new Error("no"));
	const r: Promise<Pt> = failed.then((v) => ({ x: v.x, y: v.y }), (e) => ({ x: -1, y: e.message.length }));
	const two = `${(await q).x},${(await q).y} ${(await r).x},${(await r).y}`;
	console.log(`then ${a.x},${a.y} | text ${b.tag} | handled ${c.x} ${c.y} | direct ${(await d).x} | two ${two}`);
}

await run();
