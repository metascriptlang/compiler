// @columns: mixed
// @stdout: 9
// @foreign-stdout: leaks tolerated: exit 0
// @foreign-stdout: MSB_LEAKS=error: exit 1
// @mixed-stderr: msb leak: Handle<Counter> created at handleLeakWasm.ms:8 never released
import { Handle } from "std/ffi";
import { open, read } from "./handleLeakWasm";

const leaked = open(9);
console.log(`${read(leaked)}`);
