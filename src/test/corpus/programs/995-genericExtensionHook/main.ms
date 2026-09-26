// @xfail(raiser): runs but stdout misses its @stdout line (exit=0)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: destroyed t b4 s5 | r3 r2 r1
import { Res, res, resDestroyed } from "./res";

let trail = "";

interface Slot<T> {
	item: T;
	h: int32;
}

function onDestroy<T>(this self: Slot<T>): void {
	trail = trail + " s" + self.h.toString();
}

interface Outer<T> {
	inner: Slot<T>;
	tag: string;
}

class Bag<T> {
	n: T;
	h: int32;
	constructor(n: T, h: int32) { this.n = n; this.h = h; }
}

function onDestroy<T>(this self: Bag<T>): void {
	trail = trail + " b" + self.h.toString();
}

class Tally<T> {
	seen: T[];
	onDestroy(): void { trail = trail + " t"; }
}

function slot<T>(item: T, h: int32): Slot<T> {
	return { item: item, h: h };
}

function weigh(r: Res<boolean>): int32 {
	return r.v ? r.h : 0;
}

function run(): void {
	const a: Res<string> = { v: "a".repeat(2), h: 1 };
	const b = res<int32>(7, 2);
	const w = weigh({ v: true, h: 3 });
	const o: Outer<string> = { inner: slot<string>("x".repeat(2), 5), tag: "o" };
	const g = new Bag<float64>(0.5, 4);
	const t = new Tally<string>();
	console.log(a.v + " " + b.v.toString() + " " + w.toString() + " " + o.inner.item + o.tag + " " + g.h.toString());
}

run();
console.log("destroyed" + trail + " |" + resDestroyed());
