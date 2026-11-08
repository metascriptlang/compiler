// @stdout: 4 0.5,1.5,2.5,3.5 0 16
// @stdout: 9 0.5
// @stdout: 0,-1000,-2000
// @stdout: 0,100,200
// @stdout: 0,0.25,0.5
// @stdout: true -7,0
// @stdout: 3 8 28 2,3,4
// @stdout: 0 0
// @stdout: 6.5
// @stdout: 2,4,7
import { rampF, rampI, levels, wide, maybe, middle, empty, sumIn, scaleIn } from "./typedArrayResultsWasm";

function run(): void {
	const a = rampF(4);
	console.log(`${a.length} ${a.join(",")} ${a.byteOffset} ${a.buffer.byteLength}`);
	a[0] = 9;
	console.log(`${a[0]} ${rampF(4)[0]}`);
	console.log(rampI(3).join(","));
	console.log(levels(3).join(","));
	console.log(wide(3).join(","));
	const none = maybe(0);
	const two = maybe(2);
	console.log(`${none == null} ${two == null ? "null" : two.join(",")}`);
	const mid = middle(3);
	console.log(`${mid.length} ${mid.byteOffset} ${mid.buffer.byteLength} ${mid.join(",")}`);
	const e = empty();
	console.log(`${e.length} ${e.buffer.byteLength}`);
	const f = new Float32Array(3);
	f[0] = 1;
	f[1] = 2;
	f[2] = 3.5;
	console.log(`${sumIn(f)}`);
	scaleIn(f, 2);
	console.log(f.join(","));
}
run();
