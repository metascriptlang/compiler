// @stdout: 6
// @stdout: 16
// @stdout: 4
import { Handle } from "std/ffi";
import { makeBuf, sumBuf } from "./handleViewWasm";

const h = makeBuf(4);
console.log(`${sumBuf(h)}`);
h.view((v: Span<float32>): void => {
	v[0] = 10;
});
console.log(`${sumBuf(h)}`);
let n = 0;
h.view((v: Span<float32>): void => {
	n = v.length;
});
console.log(`${n}`);
h.release();
