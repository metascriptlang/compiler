// @xfail(raiser): runs but stdout misses its @stdout line (exit=0)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: destroyed g4 f3 i2 b1 | r6 r5
import { Remote, remoteDestroyed } from "./box";

let trail = "";

class Box<T> {
	v: T;
	h: string;
	constructor(v: T, h: string) { this.v = v; this.h = h; }
	onDestroy(): void { trail = trail + " " + this.h; }
}

function make<T>(v: T, h: string): Box<T> {
	return new Box<T>(v, h);
}

function run(): void {
	const a = new Box<string>("s", "b1");
	const b = new Box<int32>(5, "i2");
	const c = make<float64>(1.5, "f3");
	const d = make<string>("t", "g4");
	const r = new Remote<string>("x", 5);
	const q = new Remote<int32>(1, 6);
	console.log(a.h + " " + b.h + " " + c.h + " " + d.h + " " + r.h.toString() + " " + q.h.toString());
}

run();
console.log("destroyed" + trail + " |" + remoteDestroyed());
