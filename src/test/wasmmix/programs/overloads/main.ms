// @stdout: 42
// @stdout: 144
// @stdout: 2.5
// @stdout: abab
// @stdout: 30
// @stdout: 6
// @stdout: 10
// @stdout: 1.75
// @stdout: 43
// @stdout: 2.75
// @stdout: 65
import { twice, total, sum, apply } from "./overloadsWasm";

const i: int32 = 21;
const u: uint8 = 200;
const f: float64 = 1.25;
console.log(`${twice(i)}`);
console.log(`${twice(u)}`);
console.log(`${twice(f)}`);
console.log(`${twice("ab")}`);
console.log(`${total(10, 20)}`);
console.log(`${total(1, 2, 3)}`);
const xs: Vec<int32> = [1, 2, 3, 4];
const ys: Vec<float64> = [0.5, 0.25, 1];
console.log(`${sum(xs)}`);
console.log(`${sum(ys)}`);
console.log(`${apply(i, (x: int32): int32 => x * 2)}`);
console.log(`${apply(f, (x: float64): float64 => x * 2)}`);
console.log(`${apply(i, (x: int32): int32 => twice(x) + total(x, 1))}`);
