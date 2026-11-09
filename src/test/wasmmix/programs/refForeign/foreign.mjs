import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const m = await import(pathToFileURL(resolve(process.argv[2])).href);

const surface = ["bump", "fill"];
const missing = surface.filter((name) => typeof m[name] !== "function");
console.log(missing.length == 0 ? "exports: ok" : `exports: missing ${missing.join(",")}`);
if (missing.length > 0) process.exit(1);

function attempt(label, call) {
	try {
		console.log(`${label}: ok ${String(call())}`);
	} catch (e) {
		console.log(`${label}: ${e.name}: ${e.message}`);
	}
}

const o = { n: 1 };
attempt("valid", () => `${m.bump([o, "n"])} ${o.n}`);
attempt("not a cell", () => m.bump(5));
attempt("short cell", () => m.bump([o]));
attempt("wrong value", () => m.bump([{ n: "x" }, "n"]));
attempt("range", () => m.bump([{ n: 2147483648 }, "n"]));
const c = { l: 0, s: "" };
attempt("out zero", () => { m.fill([c, "l"], [c, "s"]); return `${c.l} ${c.s}`; });
const d = { l: 9, s: "old" };
attempt("out other", () => { m.fill([d, "l"], [d, "s"]); return `${d.l} ${d.s}`; });
