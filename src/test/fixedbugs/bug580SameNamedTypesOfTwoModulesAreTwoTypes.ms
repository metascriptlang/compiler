// bug580 — a generic instance or an enum of one module was assignable to a same-named one of another
//
// Symptom:    `const m: Box<string> = mkA()`, where `mkA` returns another module's `Box<string>`
//             with other fields, compiled: C panicked on a null string, JS printed `undefined`.
//             An enum `K` of another module went into this module's `K` and matched no member.
// Root cause: the relation compared a generic instance's head and an enum by name.
// Fix:        both compare their declaration (the reference compares a generic instance by its
//             base and an enum by its id); two different generics fall to the structural relation
//             that same-named non-generic types already use, so an identical shape still fits.
//             A `T | null` carrier cached by an earlier compilation answers only when the enum
//             or generic inside its payload is the same declaration.

import { compileProjectToC, compileProjectToJS, compileToC } from "../helpers";
import { MapEntry } from "../../module/loader";

function entries(aSrc: string, mainSrc: string): MapEntry[] {
	return [
		{ entryPath: "test/bug580/a.ms", entrySource: aSrc },
		{ entryPath: "test/bug580/main.ms", entrySource: mainSrc },
	];
}

function isTypeError(out: string): boolean {
	return out.startsWith("ERROR") && (out.contains("not assignable") || out.contains("type mismatch"));
}

function refused(aSrc: string, mainSrc: string): boolean {
	return isTypeError(compileProjectToC(entries(aSrc, mainSrc), "test/bug580/main.ms"))
		&& isTypeError(compileProjectToJS(entries(aSrc, mainSrc), "test/bug580/main.ms"));
}

function accepted(aSrc: string, mainSrc: string): boolean {
	const c = compileProjectToC(entries(aSrc, mainSrc), "test/bug580/main.ms");
	const js = compileProjectToJS(entries(aSrc, mainSrc), "test/bug580/main.ms");
	return !c.startsWith("ERROR") && !js.startsWith("ERROR");
}

test "bug580: a generic class of another module with other fields is refused" {
	assert refused(`export class Box<T> { v: T; constructor(v: T) { this.v = v; } }\nexport function mkA(): Box<string> { return new Box<string>("a"); }\n`,
		`import { mkA } from "./a";\nclass Box<T> { n: int32; w: T; constructor(w: T) { this.n = 7; this.w = w; } }\nconst m: Box<string> = mkA();\nconsole.log(m.w);\n`);
}

test "bug580: a generic interface of another module with other fields is refused" {
	assert refused(`export interface Box<T> { v: T; }\nexport function mkA(): Box<string> { return { v: "a" }; }\n`,
		`import { mkA } from "./a";\ninterface Box<T> { n: int32; w: T; }\nconst m: Box<string> = mkA();\nconsole.log(m.w);\n`);
}

test "bug580: a generic alias of another module with other fields is refused as an argument" {
	assert refused(`export type Box<T> = { v: T };\nexport function mkA(): Box<string> { return { v: "a" }; }\n`,
		`import { mkA } from "./a";\ntype Box<T> = { n: int32, w: T };\nfunction show(b: Box<string>): string { return b.w; }\nconsole.log(show(mkA()));\n`);
}

test "bug580: an enum of another module is refused" {
	assert refused(`export enum K { A, B, C }\nexport function mkA(): K { return K.C; }\n`,
		`import { mkA } from "./a";\nenum K { X, Y }\nconst m: K = mkA();\nconsole.log(m == K.X);\n`);
}

test "bug580: a generic interface of another module with the same shape still fits" {
	assert accepted(`export interface Box<T> { v: T; }\nexport function mkA(): Box<string> { return { v: "a" }; }\n`,
		`import { mkA } from "./a";\ninterface Box<T> { v: T; }\nconst m: Box<string> = mkA();\nconsole.log(m.v);\n`);
}

test "bug580: the imported generic itself still fits" {
	assert accepted(`export class Box<T> { v: T; constructor(v: T) { this.v = v; } }\nexport function mkA(): Box<string> { return new Box<string>("a"); }\n`,
		`import { Box, mkA } from "./a";\nconst m: Box<string> = mkA();\nconst n: Box<string> = new Box<string>("b");\nconsole.log(m.v, n.v);\n`);
}

test "bug580: a second compilation gets its own nullable set and nullable instance" {
	const src = "enum E { A, B, C }\nstruct Pair<T> { a: T; b: T; }\nconst some: BitSet<E> = E.A | E.C;\nconst two: Pair<int32> = { a: 1, b: 2 };\nfunction pick(on: boolean): BitSet<E> | null { return on ? some : null; }\nfunction pair(on: boolean): Pair<int32> | null { return on ? two : null; }\nconsole.log(pick(true) != null, pair(true) != null);\n";
	assert compileToC(src).ok;
	assert compileToC(src).ok;
}
