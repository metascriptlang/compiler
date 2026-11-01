import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const m = await import(pathToFileURL(resolve(process.argv[2])).href);

function attempt(label, call) {
	try {
		console.log(`${label}: ok ${String(call())}`);
	} catch (e) {
		console.log(`${label}: ${e.name}: ${e.message}`);
	}
}

const bs = [true, false, false];
attempt("overlap", () => m.countAfter(bs, { base: bs, off: 1, len: 2 }));
attempt("apart", () => m.countAfter([true, false], { base: [false, false], off: 0, len: 1 }));
const cs = [true, false, false];
attempt("empty", () => m.countAfter(cs, { base: cs, off: 1, len: 0 }));
console.log(`unchanged: ${bs.join(",")}`);
