// @mixed-error: escapes its view
// @columns: mixed
// @stdout: 4
import { Handle } from "std/ffi";
import { makeBuf } from "./refusedKeptViewWasm";

const h = makeBuf(4);
let kept: Span<float32> | null = null;
h.view((v: Span<float32>): void => {
	kept = v;
});
h.release();
console.log("4");
