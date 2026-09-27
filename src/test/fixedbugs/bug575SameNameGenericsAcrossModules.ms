// bug575 — two modules declaring one generic name shared its params and its C struct
//
// Symptom:    `type Box<U>` in a.ms and `type Box<T>` in main.ms made a.ms's `Box<string>` bind
//             main's parameter names (a checker error inside a.ms); with equal type arguments the
//             two `Box<string>` became one C struct (`no member named 'w'`). JS was right.
// Root cause: generic params lived in a parser store keyed by name (first match wins), instance
//             struct names were `Box__string` with no declaring module, and the C type cache keyed
//             a generic instance by its name.
// Fix:        params come from the declaring symbol (declaration node), and every instance name and
//             cache key carries the declaring module (monoInstanceName), as the reference keys
//             instances by the generic body's symbol.

import { compileProjectToC } from "../helpers";
import { MapEntry } from "../../module/loader";

function project(aSrc: string, mainSrc: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/bug575/a.ms", entrySource: aSrc },
		{ entryPath: "test/bug575/main.ms", entrySource: mainSrc },
	];
	return compileProjectToC(entries, "test/bug575/main.ms");
}

function instanceNamesFor(out: string, base: string, suffix: string): string[] {
	const names: string[] = [];
	const marker = "struct " + base + "_";
	let at = out.indexOf(marker, 0);
	while (at >= 0) {
		const end = out.indexOf(" ", at + 7);
		const name = out.slice(at + 7, end);
		if (name.endsWith(suffix) && names.indexOf(name) < 0) names.push(name);
		at = out.indexOf(marker, at + 1);
	}
	return names;
}

const MAIN = `
import { mkA } from "./a";
type Box<T> = { n: int32, w: T };
const m: Box<string> = { n: 7, w: "m" };
console.log(m.w, mkA().v);
`;

test "bug575: two same-named generics with equal arguments get two C structs" {
	const out = project(`export type Box<T> = { v: T };\nexport function mkA(): Box<string> { return { v: "a" }; }\n`, MAIN);
	assert !out.startsWith("ERROR");
	assert instanceNamesFor(out, "Box", "__string").length == 2;
}

test "bug575: each declaration binds its own parameter names" {
	const out = project(`export type Box<U> = { v: U };\nexport function mkA(): Box<string> { return { v: "a" }; }\n`, MAIN);
	assert !out.startsWith("ERROR");
	assert instanceNamesFor(out, "Box", "__string").length == 2;
}

test "bug575: same-named generic interfaces keep their own layouts" {
	const out = project(`export interface Box<U> { v: U; }\nexport function mkA(): Box<string> { return { v: "a" }; }\n`,
		`import { mkA } from "./a";\ninterface Box<T> { n: int32; w: T; }\nconst m: Box<string> = { n: 7, w: "m" };\nconsole.log(m.w, mkA().v);\n`);
	assert !out.startsWith("ERROR");
	assert instanceNamesFor(out, "Box", "__string").length == 2;
}
