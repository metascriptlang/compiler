import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const url = pathToFileURL(resolve(process.argv[2])).href;

function attempt(label, call) {
	try {
		console.log(`${label}: ok ${String(call())}`);
	} catch (e) {
		console.log(`${label}: ${e.name}: ${e.message}`);
	}
}

function thrown(call) {
	try {
		call();
	} catch (e) {
		return e;
	}
	return null;
}

const a = await import(`${url}?instance=1`);
const log = console.log;
console.log = () => {};
let b;
try {
	b = await import(`${url}?instance=2`);
} finally {
	console.log = log;
}

const marker = new Error("marker");
const raise = () => { throw marker; };
console.log(`original error: ${thrown(() => a.guarded(1, raise)) === marker}`);
attempt("after", () => a.guarded(1, (x) => x * 2));
console.log(`same text kept the original: ${thrown(() => a.rethrow("", raise)) === marker}`);
const rewritten = thrown(() => a.rethrow("seen: ", raise));
console.log(`rewritten text: ${rewritten.name}: ${rewritten.message}, original: ${rewritten === marker}`);
attempt("wasm throw", () => a.blow(5));
attempt("after wasm throw", () => a.guarded(1, (x) => x * 3));
const trap = thrown(() => a.wild(5));
console.log(`trap threw: ${trap !== null}`);
attempt("after trap", () => a.guarded(1, (x) => x * 2));
console.log(`cause is the trap: ${thrown(() => a.guarded(1, (x) => x))?.cause === trap}`);
attempt("other instance", () => b.guarded(1, (x) => x * 5));
let inner;
const outer = thrown(() => b.guarded(1, () => { inner = thrown(() => b.wild(5)); throw inner; }));
console.log(`nested trap reaches the outer caller: ${inner !== null && outer === inner}`);
attempt("after nested trap", () => b.guarded(1, (x) => x * 5));
process.exitCode = 0;
