import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const url = pathToFileURL(resolve(process.argv[2])).href;

async function attempt(label, call) {
	try {
		console.log(`${label}: ok ${String(await call())}`);
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
console.log(`original error: ${thrown(() => a.guarded(1, () => { throw marker; })) === marker}`);
await attempt("after", () => a.guarded(1, (x) => x * 2));
await attempt("after, another export", () => a.recover("x", () => 1));
console.log(`cause: ${thrown(() => a.recover("x", () => 1))?.cause === marker}`);
await attempt("other instance", () => b.guarded(1, (x) => x * 3));
const inner = new Error("inner");
console.log(`nested original: ${thrown(() => b.guarded(1, () => b.recover("x", () => { throw inner; }))) === inner}`);
await attempt("after nested", () => b.guarded(1, (x) => x * 3));
