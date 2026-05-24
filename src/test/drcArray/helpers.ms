// DRC Array-Destroy Test Helpers
//
// Each test compiles a snippet that creates an Array<T> for some T, then
// asserts that the emitted C code uses the CORRECT destroy function name
// for that element type — proving classify.ms routes correctly.
//
// Code-level assertion (not runtime). Runtime crashes are surfaced via
// fixedbugs/bug033..bug035 (which actually execute the repros).

import { compileToC } from "../helpers";

export function compilesCleanly(source: string): boolean {
	return compileToC(source).ok;
}

// Runtime-helper names use the prefix form `msArrayXxxDestroy` (no "Array"
// immediately before "Destroy") — must be matched by full-name lookup.
// Per-T lifted hooks use the suffix form `FooArrayDestroy` — matched by
// walking back from an "ArrayDestroy(" occurrence to the identifier start.
// Returns the earliest hit, or "" if no destroy call found.
export function firstArrayDestroyEmitted(source: string): string {
	const result = compileToC(source);
	if (!result.ok) return "";
	const code = result.value;
	let earliestIdx = -1;
	let earliestName = "";

	const runtimeNames: string[] = [
		"msArrayDestroy(",
		"msArrayStringDestroy(",
		"msArrayRefDestroy(",
		"msArrayUint8Destroy(",
		"msArrayClosureDestroy(",
	];
	for (const name of runtimeNames) {
		const idx = code.indexOf(name);
		if (idx >= 0 && (earliestIdx < 0 || idx < earliestIdx)) {
			earliestIdx = idx;
			earliestName = name;
		}
	}

	let p = 0;
	while (p < code.length) {
		const idx = code.indexOf("ArrayDestroy(", p);
		if (idx < 0) break;
		let start = idx;
		while (start > 0) {
			const ch = code.charAt(start - 1);
			const isIdent = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
				|| (ch >= "0" && ch <= "9") || ch === "_";
			if (!isIdent) break;
			start = start - 1;
		}
		if (start < idx && (earliestIdx < 0 || start < earliestIdx)) {
			earliestIdx = start;
			earliestName = code.slice(start, idx + "ArrayDestroy(".length);
		}
		p = idx + 1;
	}
	return earliestName;
}
