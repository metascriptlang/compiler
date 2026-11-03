// @mixed-error: escapes its view
// @columns: mixed
// @stdout: 4
import { Handle } from "std/ffi";
import { makeBuf } from "./refusedKeptViewFnWasm";

const h = makeBuf(4);
const kept: Span<int32>[] = [];
function keep(v: Span<int32>): void {
	kept.push(v);
}
h.view(keep);
h.release();
console.log("4");
