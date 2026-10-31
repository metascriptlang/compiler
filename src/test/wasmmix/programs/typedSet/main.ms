// @stdout: 7
// @stdout: 1.5
// @stdout: 1 6 9 12 5
// @stdout: 10,20,3,4
// @stdout: 20,40,6,8
// @stdout: 110
// @stdout: 995 1000 31000
// @stdout: 5.5
// @stdout: -15
import { sumF, scaleI, flipB, liftH, quarterThrough, shiftThrough } from "./typedSetWasm";

const fx: float32[4] = [1.5, 2, -0.5, 4];
console.log(`${sumF(fx)}`);
console.log(`${sumF(fx[1..3])}`);

let nx: int32[5] = [1, 2, 3, 4, 5];
scaleI(nx[1..4], 3);
console.log(`${nx[0]} ${nx[1]} ${nx[2]} ${nx[3]} ${nx[4]}`);

let vs: Vec<int32> = [1, 2, 3, 4];
scaleI(vs[0..2], 10);
console.log(vs.join(","));
scaleI(vs, 2);
console.log(vs.join(","));

let flags: boolean[3] = [true, false, true];
flipB(flags[1..3]);
console.log(`${flags[0] ? 1 : 0}${flags[1] ? 1 : 0}${flags[2] ? 1 : 0}`);

let hs: int16[3] = [-5, 0, 30000];
liftH(hs);
console.log(`${hs[0]} ${hs[1]} ${hs[2]}`);

console.log(`${quarterThrough((xs: Span<float32>): void => {
	for (let i = 0; i < xs.length; i += 1) xs[i] = (xs[i] * 0.25) as float32;
})}`);
console.log(`${shiftThrough((xs: Span<int16>): void => {
	for (let i = 0; i < xs.length; i += 1) {
		const t: int32 = (xs[i] as int32) - 25;
		xs[i] = t as int16;
	}
})}`);
