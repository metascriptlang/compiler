import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const m = await import(pathToFileURL(resolve(process.argv[2])).href);

function thrown(call) {
	try {
		call();
	} catch (e) {
		return e;
	}
	return null;
}

const d = m.open(3);
d.ptr[Symbol.dispose]();
console.log(`dispose releases: ${d.ptr.released}`);
const h = m.open(1);
const k = m.open(2);
const trap = thrown(() => m.bumpWild(h, () => h.ptr.release(), 5));
console.log(`trap reaches the caller: ${trap?.name}: ${trap?.message}`);
const late = thrown(() => k.ptr.release());
console.log(`release after trap: ${late === null ? "ok" : late.message} ${k.ptr.released}`);
process.exitCode = 0;
