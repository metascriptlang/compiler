// @mixed-error: reads a wasm-owned handle
// @columns: mixed
// @stdout: 1
import { Handle, value, release } from "std/ffi";
import { open } from "./refusedHandleReadWasm";

const a = open(1);
console.log(`${a.value().n}`);
a.release();
