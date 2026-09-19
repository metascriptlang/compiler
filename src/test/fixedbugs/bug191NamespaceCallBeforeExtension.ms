// bug191 — `ns.f(args)` resolved to a same-named local `this` function
//
// Symptom:    `hdrs.setHeader(res.headers, name, value)` inside a local
//             `setHeader(this res: Res, …)` failed with "Too many arguments to
//             'setHeader': expected at most 2, got 3"; every program importing
//             `std/http/server` stopped with 18 errors of that shape.
// Cause:      `checkCallExpr` ran extension-method dispatch on any `a.f(…)`
//             callee, and a namespace object (typed none) passed the receiver
//             filter, so the local `this` function won over the namespace
//             member `checkMemberExpr` had already resolved.
// Reference:  the dot handler looks the right side up in the module first when
//             the left side is a module (`semexprs.nim` `qualifiedLookUp`
//             before any field access or method-call syntax) and returns.
import { compileProjectToCWithStd, MapEntry } from "../helpers";

const HEADERS = `export interface Headers { names: string[]; values: string[]; }
export function setHeader(h: Headers, name: string, value: string): void {
	h.names.push(name);
	h.values.push(value);
}
`;

function withHeaders(shimSource: string, mainSource: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/headers.ms", entrySource: HEADERS },
		{ entryPath: "test/shim.ms", entrySource: shimSource },
		{ entryPath: "test/main.ms", entrySource: mainSource },
	];
	return compileProjectToCWithStd(entries, "test/main.ms");
}

const LOCAL_THIS_FN = `
interface Res { headers: Headers; }

export function setHeader(this res: Res, name: string, value: string): void {
	hdrs.setHeader(res.headers, name, value);
}

function main(): void {
	const r: Res = { headers: { names: [], values: [] } };
	r.setHeader("a", "b");
	console.log(r.headers.names.length.toString());
}
`;

test "bug191: a namespace call resolves in the namespace, not to a local this function" {
	const out = withHeaders(`export const unused = 0;\n`,
		`import * as hdrs from "./headers";\nimport { Headers } from "./headers";\n` + LOCAL_THIS_FN);
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
}

test "bug191: the same holds through a re-export shim" {
	const out = withHeaders(`export { Headers, setHeader } from "./headers";\n`,
		`import * as hdrs from "./shim";\nimport { Headers } from "./shim";\n` + LOCAL_THIS_FN);
	assert out.indexOf("ERROR", 0) < 0, out.slice(0, 400);
}
