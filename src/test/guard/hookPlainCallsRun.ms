// GUARD-JS
// ULTRALOCK T7 accepted neighbours: the hook effect refuses only a spawn, an
// await or a lend a hook can reach. A hook that calls a plain helper, a method
// of another value, or an inline callback through a std routine compiles and
// runs; a NON-hook function of the same type may spawn and await; a hook-named
// function without a receiver is a plain function. Hooks of generic owners (a
// class method and a generic receiver function) that call plain helpers compile.
// RED MEANS: the hook effect over-reaches (counts a plain callee, a std
// callback taking an inline arrow, or a non-hook routine) — fix effects.ms.

function work(n: int32): int32 { return n + 1; }
async function asy(n: int32): Promise<int32> { return n * 2; }

class Counter { n: int32 = 0; bump(k: int32): void { this.n = this.n + k; } }
const counter = new Counter();

class Res {
	v: int32;
	constructor(v: int32) { this.v = v; }
	async fetch(): Promise<int32> { return await spawn(() => work(this.v)); }
}
function plainHelper(n: int32): int32 { return work(n) * 2; }
function onDestroy(this x: Res): void {
	counter.bump(plainHelper(x.v));
	const xs: int32[] = [1, 2, 3];
	const ys = xs.map((k: int32): int32 => k * 2);
	for (const k of ys) counter.bump(k);
}

class MethodRes {
	v: int32 = 2;
	onDestroy(): void { counter.bump(this.v); }
}

function onMove(n: int32): int32 { return n + 1; }

async function main(): Promise<void> {
	const r = new Res(3);
	const s = await asy(r.v) + await r.fetch();
	const m = new MethodRes();
	console.log(`${s + m.v + onMove(1)}`);
}

class Gen<T> { v: T; constructor(v: T) { this.v = v; } onDestroy(): void { counter.bump(work(1)); } }
function onDestroy<T>(this x: Wrap<T>): void { counter.bump(plainHelper(1)); }
class Wrap<T> { v: T; constructor(v: T) { this.v = v; } }
function generic(): void { const g = new Gen<int32>(1); const w = new Wrap<int32>(2); console.log(`${g.v + w.v}`); }
generic();
await main();
console.log("GUARD-OK");
