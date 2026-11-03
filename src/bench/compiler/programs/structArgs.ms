import { argv } from "std/process";

struct P { x: int32; y: int32; z: int32; w: int32; }
struct Outer { inner: P; k: int32; }

let g: P = { x: 1, y: 2, z: 3, w: 4 };

function bump(): void { g.x = g.x + 1; }
function take(p: P): int64 { bump(); return p.x + p.y + p.z + p.w; }
function plain(p: P): int64 { return p.x + p.y + p.z + p.w; }
function outer(o: Outer): int64 { bump(); return o.inner.x + o.k; }

function churn(rounds: int32): int64 {
	let sum: int64 = 0;
	const o: Outer = { inner: { x: 1, y: 1, z: 1, w: 1 }, k: 2 };
	for (let i: int32 = 0; i < rounds; i++) {
		sum += take(g);
		sum += plain(g);
		sum += outer(o);
	}
	return sum;
}

const rounds: int32 = argv.length > 1 ? argv[1].parseInt() as int32 : 2000000;
console.log(`structArgs ${churn(rounds)}`);
