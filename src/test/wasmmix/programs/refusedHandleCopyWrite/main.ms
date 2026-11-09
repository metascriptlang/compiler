// @mixed-error: is a copy of the field 'at' of wasm-owned Counter
// @columns: mixed
// @stdout: 5
import { Handle } from "std/ffi";
import { open } from "./refusedHandleCopyWriteWasm";

const h = open();
h.value().at.x = 5;
console.log(`${h.value().at.x}`);
h.release();
