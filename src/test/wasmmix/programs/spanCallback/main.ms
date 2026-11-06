// @stdout: 9.5
// @stdout: 0
// @stdout: 11
// @stdout: 2
// @stdout: 5.25
// @stdout: 0
import { sumThrough, editThrough, flipThrough, editReals } from "./spanCallbackWasm";

console.log(`${sumThrough(4, (xs: Readonly<Span<float32>>): float32 => {
	let s: float32 = 0;
	for (const x of xs) s += x;
	return s;
})}`);
console.log(`${sumThrough(0, (xs: Readonly<Span<float32>>): float32 => xs.length as float32)}`);
console.log(`${editThrough((xs: Span<int32>, at: int32): void => {
	xs[at] = xs[at] + 10;
})}`);
console.log(`${flipThrough((bs: Span<boolean>): void => {
	for (let i = 0; i < bs.length; i += 1) bs[i] = !bs[i];
})}`);
console.log(`${editReals(3, (xs: Span<float32>): void => {
	for (let i = 0; i < xs.length; i += 1) xs[i] += 0.25;
})}`);
console.log(`${editReals(0, (xs: Span<float32>): void => {})}`);
