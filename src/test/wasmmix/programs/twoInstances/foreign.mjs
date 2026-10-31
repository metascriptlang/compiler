import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const url = pathToFileURL(resolve(process.argv[2])).href;
const wasmUrl = new URL("./app.wasm.mjs", url).href;

async function attempt(label, call) {
	try {
		console.log(`${label}: ok ${String(await call())}`);
	} catch (e) {
		console.log(`${label}: ${e.name}: ${e.message}`);
	}
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

await attempt("a apply", () => a.apply(20, (x) => x * 2));
await attempt("a measure", () => a.measure((s) => s.length));
await attempt("a pair", () => { const p = a.pair(3, "hi"); return `${p.left} ${p.name}`; });
await attempt("a ramp", () => Array.from(a.ramp(3)).join(","));
await attempt("b apply", () => b.apply(20, (x) => x + 100));
await attempt("b measure", () => b.measure((s) => s.length + 1));
await attempt("b pair", () => { const p = b.pair(7, "yo"); return `${p.left} ${p.name}`; });
await attempt("b ramp", () => Array.from(b.ramp(2)).join(","));
await attempt("cross", () => a.apply(1, (x) => b.apply(x, (y) => y - 6)));
await attempt("a after b", () => a.apply(20, (x) => x * 2));
await attempt("no registry", async () => (await import(wasmUrl)).default());
