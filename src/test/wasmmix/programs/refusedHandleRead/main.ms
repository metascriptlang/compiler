// @mixed-error: Handle<Counter>.value() reads a wasm-owned object
// @columns: mixed
// @stdout: 1
import { Handle, value, release } from "std/ffi";
import { open } from "./refusedHandleReadWasm";

const a = open(1);
const c = a.value();
console.log(`${c.n}`);
a.release();
