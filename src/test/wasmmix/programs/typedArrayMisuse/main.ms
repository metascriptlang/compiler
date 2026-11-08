// @columns: mixed
// @stdout: keeps: the Float32Array it returns is still held on the wasm side, so the copy JS receives would stop seeing its writes: return Float32Array.from(x), a copy nothing else holds
// @stdout: tagged: it returns an instance of a class that extends Float32Array, which has no JS/wasm boundary form: return Float32Array.from(x), a copy nothing else holds
// @stdout: shares: the Float32Array it returns views an ArrayBuffer that another view or object still holds, so the copy JS receives would stop sharing it: return Float32Array.from(x), a copy nothing else holds
// @stdout: 5
import { keeps, tagged, shares, fresh } from "./typedArrayMisuseWasm";

function attempt(f: () => void): void {
	try { f(); } catch (e) { console.log(e.message); }
}

attempt((): void => { keeps(2); });
attempt((): void => { tagged(2); });
attempt((): void => { shares(2); });
console.log(`${fresh(5).length}`);
