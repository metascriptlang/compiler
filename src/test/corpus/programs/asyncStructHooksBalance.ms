// @stdout: r1
// @stdout: none made=1 copies=0 destroys=1 live=0
// @stdout: r2
// @stdout: one made=1 copies=1 destroys=2 live=0
// @stdout: r4
// @stdout: two made=2 copies=1 destroys=3 live=0
// @stdout: r5
// @stdout: fresh made=1 copies=0 destroys=1 live=0
// @stdout: r7
// @stdout: nested made=1 copies=3 destroys=4 live=0
// @skip-js: JS runs no onCopy or onDestroy hook, so its counters stay at zero
// note: a struct returned from an async function (with zero, one and two awaits before its return, a fresh value, a value passed up through a second async function) runs each hook as on C: the future takes the value at settle and the await that is its only reader takes it out, so every value made or copied is destroyed once.

let made = 0;
let copies = 0;
let destroys = 0;
struct R { id: int32; s: string; }
function onDestroy(this r: R): void { if (r.id != 0) destroys += 1; }
function onCopy(this ref dest: R, src: R): void { if (src.id != 0) copies += 1; dest.id = src.id; dest.s = src.s; }
function mk(id: int32): R { made += 1; return { id: id, s: "r" + id.toString() }; }
async function tick(): Promise<void> { await sleepAsync(0); }
async function report(tag: string): Promise<void> {
	await tick();
	console.log(`${tag} made=${made} copies=${copies} destroys=${destroys} live=${made + copies - destroys}`);
	made = 0; copies = 0; destroys = 0;
}

async function none(): Promise<R> { const r = mk(1); return r; }
async function one(): Promise<R> { const r = mk(2); await tick(); return r; }
async function two(): Promise<R> { let r = mk(3); await tick(); r = mk(4); await tick(); return r; }
async function fresh(): Promise<R> { await tick(); return mk(5); }

async function readNone(): Promise<void> { const a = await none(); console.log(a.s); }
async function readOne(): Promise<void> { const a = await one(); console.log(a.s); }
async function readTwo(): Promise<void> { const a = await two(); console.log(a.s); }
async function readFresh(): Promise<void> { const a = await fresh(); console.log(a.s); }
async function passUp(): Promise<R> { const r = mk(7); await tick(); const back = await relay(r); return back; }
async function relay(r: R): Promise<R> { await tick(); return r; }
async function readNested(): Promise<void> { const a = await passUp(); console.log(a.s); }

await readNone(); await report("none");
await readOne(); await report("one");
await readTwo(); await report("two");
await readFresh(); await report("fresh");
await readNested(); await report("nested");
