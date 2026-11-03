// @stdout: 6
// @stdout: 106
// @stdout: 28
import { Handle } from "std/ffi";
import { makeBuf, sumBuf } from "./handleViewIntWasm";

const h = makeBuf(4);
console.log(`${sumBuf(h)}`);
h.view((v: Span<int32>): void => {
	for (let i = 0; i < v.length; i += 1) v[i] = v[i] + 25;
});
console.log(`${sumBuf(h)}`);
let last = 0;
h.view((v: Span<int32>): void => {
	last = v[v.length - 1];
});
console.log(`${last}`);
h.release();
