// @columns: mixed
// @stdout: boundary call while a view of Handle<VecBox<float32>> created at handleViewOpenWasm.ms:4 is open: the call could grow wasm memory
// @stdout: 6
import { Handle } from "std/ffi";
import { makeBuf, sumBuf } from "./handleViewOpenWasm";

const h = makeBuf(4);
try {
	h.view((v: Span<float32>): void => {
		v[0] = sumBuf(h) as float32;
	});
} catch (e) {
	console.log(e.message);
}
console.log(`${sumBuf(h)}`);
h.release();
