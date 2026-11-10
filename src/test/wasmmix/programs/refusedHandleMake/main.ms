// @mixed-error: Handle.retain(…) of Counter, which lives in wasm
// @columns: mixed
// @stdout: 4
import { Handle } from "std/ffi";
import { Counter, total } from "./refusedHandleMakeWasm";

const c = new Counter();
c.n = 4;
const h = Handle.retain(c);
console.log(`${total(h)}`);
h.release();
