// @mixed-error: refusedSpanCallbackWasm.ms:2:17
// @mixed-error: refusedSpanCallbackWasm.ms:7:17
// @mixed-error: takes both a Span and a callback
// @stdout: 2,4,6
// @stdout: 6.5
import { mapInto, sumThen } from "./refusedSpanCallbackWasm";

let xs: Vec<int32> = [1, 2, 3];
mapInto(xs, (x: int32): int32 => x * 2);
console.log(xs.join(","));
const fs: Vec<float32> = [1.5, 2, 3];
sumThen(fs, (total: float32): void => {
	console.log(`${total}`);
});
