// @stdout: 5 6
// @stdout: caught boom 5
class Root { n: int32 = 5 }
function make(): Root { return new Root() }
async function main() {
	const root = make();
	const a = spawn(() => root.n);
	const b = spawn(() => root.n + 1);
	console.log(await a, await b);
	const c = spawn((): int32 => { if (root.n == 5) throw new Error("boom"); return root.n; });
	try { await c; } catch (e) { console.log("caught", (e as Error).message, root.n); }
}
await main();
