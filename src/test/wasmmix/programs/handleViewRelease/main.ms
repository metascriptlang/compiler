// @columns: mixed
// @ledger-balanced: VecBox
// @stdout: 6
// @stdout: 7
// @stdout: use of Handle<VecBox<float32>> created at handleViewReleaseWasm.ms:4 after release
import { Handle } from "std/ffi";
import { makeBuf, sumBuf } from "./handleViewReleaseWasm";

const h = makeBuf(4);
console.log(`${sumBuf(h)}`);
h.view((v: Span<float32>): void => {
	h.release();
	v[0] = 7;
	console.log(`${v[0]}`);
});
try {
	sumBuf(h);
} catch (e) {
	console.log(e.message);
}
