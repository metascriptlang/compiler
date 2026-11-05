import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const m = await import(pathToFileURL(resolve(process.argv[2])).href);

function caught(f) {
	try {
		f();
	} catch (e) {
		return e;
	}
	return null;
}

const trap = caught(() => m.trapNow());
const blocked = caught(() => m.ping());
console.log(`runtime trap: ${trap instanceof WebAssembly.RuntimeError}`);
console.log(`blocked: ${
	blocked?.message.includes("the wasm half cannot run again") === true
}`);
console.log(`cause: ${blocked?.cause === trap}`);
