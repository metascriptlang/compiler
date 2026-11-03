// @columns: mixed
// @stdout: release of Handle<Counter> created at handleMisuseWasm.ms:8: already released
// @stdout: use of Handle<Counter> created at handleMisuseWasm.ms:8 after release
// @stdout: 3
// @stdout: use of Handle<Counter> created at handleMisuseWasm.ms:8 after release
import { Handle } from "std/ffi";
import { open, bump, bumpThen } from "./handleMisuseWasm";

function attempt(f: () => void): void {
	try { f(); } catch (e) { console.log(e.message); }
}

const a = open(1);
a.release();
attempt(() => a.release());
attempt(() => { bump(a, 1); });

const b = open(3);
attempt(() => { console.log(`${bumpThen(b, () => b.release())}`); });
attempt(() => { bump(b, 0); });
