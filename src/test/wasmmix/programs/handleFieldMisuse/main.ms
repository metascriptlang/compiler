// @columns: mixed
// @stdout: 4
// @stdout: use of Handle<Counter> created at handleFieldMisuseWasm.ms:8 after release
// @stdout: use of Handle<Counter> created at handleFieldMisuseWasm.ms:8 after release
import { Handle } from "std/ffi";
import { open } from "./handleFieldMisuseWasm";

function attempt(f: () => void): void {
	try { f(); } catch (e) { console.log(e.message); }
}

const a = open(4);
console.log(`${a.value().n}`);
a.release();
attempt(() => { console.log(`${a.value().n}`); });
attempt(() => { a.value().n = 1; });
