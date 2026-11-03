// @columns: mixed
// @stdout: 6
// @stdout: use of Handle<Counter> created at handleRetainWasm.ms:8 after release
import { Handle } from "std/ffi";
import { open, bump } from "./handleRetainWasm";

const a = open(5);
a.retain();
a.release();
console.log(`${bump(a, 1)}`);
a.release();
try {
	bump(a, 1);
} catch (e) {
	console.log(e.message);
}
