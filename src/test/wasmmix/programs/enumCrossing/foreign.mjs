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

attempt("valid", () => m.name(2));
attempt("result", () => m.orRed(1) ?? 0);
attempt("range", () => m.name(3));
attempt("wide", () => m.flip(301));
attempt("field", () => m.level({ shade: -1, level: 0, tint: null }));
attempt("nullable field", () => m.level({ shade: 0, level: 0, tint: 9 }));
attempt("nullable", () => m.orRed(5));
attempt("callback result", () => m.relay(0, () => 4));
attempt("after", () => m.name(1));
