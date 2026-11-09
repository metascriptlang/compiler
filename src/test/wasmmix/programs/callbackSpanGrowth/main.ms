// @columns: mixed
// @stdout: ballast 10
// @stdout: 9
// @stdout: ballast 20000000
// @stdout: threw wasm memory grew while a Span view was open, so the view stopped seeing it: a Handle release inside the callback or view ran a destroy that allocated; release it after the callback or view returns
// @stdout: 1
import { Handle } from "std/ffi";
import { ballast, visit } from "./callbackSpanGrowthWasm";

function attempt(run: () => int32): string {
	try {
		return `${run()}`;
	} catch (e) {
		return "threw " + e.message;
	}
}

const small = ballast(10);
console.log(attempt((): int32 => visit((xs: Span<int32>): void => {
	small.release();
	xs[0] = 9;
})));
const big = ballast(20000000);
console.log(attempt((): int32 => visit((xs: Span<int32>): void => {
	big.release();
	xs[0] = 9;
})));
console.log(attempt((): int32 => visit((xs: Span<int32>): void => {})));
