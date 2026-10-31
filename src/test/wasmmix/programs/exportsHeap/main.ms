// @stdout: 0,1,4,9
// @stdout: 0
// @stdout: 250,249,248
// @stdout: 4.75
// @stdout: 18
import { ramp, bytes, visit, bump } from "./exportsHeapWasm";

console.log(ramp(4).join(","));
console.log(`${ramp(0).length}`);
console.log(bytes(3).join(","));
console.log(`${visit((xs: Readonly<Span<float64>>): float64 => {
	let s: float64 = 0;
	for (const x of xs) s += x;
	return s;
})}`);
console.log(`${bump((xs: Span<uint16>): void => {
	for (let i = 0; i < xs.length; i += 1) xs[i] = (xs[i] * 3) as uint16;
})}`);
