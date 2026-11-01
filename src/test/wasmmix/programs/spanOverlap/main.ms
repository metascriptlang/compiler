// @stdout: 1,1,1,1,1
// @stdout: 1,7,3,4,5
// @stdout: 1,7,9,4,5
// @stdout: 17
// @stdout: 0,5,0,6,7
// @stdout: 2
// @stdout: true,true,false
// @stdout: 13
import { copyUp, stamp, pairHead, chain, flipAfter, smear } from "./spanOverlapWasm";

let k = 1;
let xs: Vec<int32> = [1, 2, 3, 4, 5];
copyUp(xs[k..5], xs[0..4]);
console.log(xs.join(","));

let j = 3;
let ys: Vec<int32> = [1, 2, 3, 4, 5];
stamp(ys[0..j], ys[1..4]);
console.log(ys.join(","));

let zs: Vec<int32> = [1, 2, 3, 4, 5];
stamp(zs[0..2], zs[2..5]);
console.log(zs.join(","));
console.log(`${pairHead(zs[0..3], zs[1..4])}`);

let cs: Vec<int32> = [0, 0, 0, 0, 0];
chain(cs[0..2], cs[k..4], cs[3..5]);
console.log(cs.join(","));

let bs: Vec<boolean> = [true, false, false];
console.log(`${flipAfter(bs, bs[k..3])}`);
console.log(bs.join(","));

console.log(`${smear((dst: Span<float64>, src: Readonly<Span<float64>>): void => {
	for (let i = 0; i < dst.length; i += 1) dst[i] = src[i] + 1;
})}`);
