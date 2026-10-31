// @stdout: 7
// @stdout: 1.5
// @stdout: 1,4,6,8,5
// @stdout: 2,8,12,16,10
// @stdout: 0
// @stdout: true,true,true
import { sum, doubled, toggle } from "./spansWasm";

const xs: Vec<float32> = [1.5, 2, -0.5, 4];
console.log(`${sum(xs)}`);
console.log(`${sum(xs[1..3])}`);
let ns: Vec<int32> = [1, 2, 3, 4, 5];
doubled(ns[1..4]);
console.log(ns.join(","));
doubled(ns);
console.log(ns.join(","));
let empty: Vec<int32> = [];
doubled(empty);
console.log(`${empty.length}`);
let bs: Vec<boolean> = [true, false, true];
toggle(bs, 1);
console.log(bs.join(","));
