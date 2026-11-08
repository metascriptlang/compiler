import { compileProjectToCWithStd, compileProjectToJSWithStd, MapEntry } from "../helpers";
import { engineRecheckCount, engineRecheckReasons } from "../../codegen/raiser/eval";

const HELPERS = `
export function firstOf<T>(xs: T[]): T { return xs[0]; }
export function lastOf<T>(xs: T[]): T { return xs[xs.length - 1]; }
export function pairUp<T>(a: T, b: T): T[] { const out: T[] = [a, b]; return out; }
export function tagged<T>(x: T, tag: string): string { return tag + ":" + firstOf([x]); }
`;

const EXPECTED = "A:c|y";
const CALLS = `tagged("c", "A") + "|" + lastOf(pairUp("x", "y"))`;
const IMPORTS = `import { firstOf, lastOf, pairUp, tagged } from "./lib";`;

const MACRO_MAIN = IMPORTS + `
import { Node, NodeKind } from "std/meta";

macro described(): Node {
	const t = getTypeArg();
	const v = ${CALLS} + (t.kind === NodeKind.TypeObject ? "" : "?");
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: v };
}

interface Shape { w: int32; }
console.log(described<Shape>());
`;

const COMPTIME_MAIN = IMPORTS + `
const V: string = @comptime { ${CALLS} };
console.log(V);
`;

function checkedOnce(main: string, js: boolean): string {
	const entries: MapEntry[] = [
		{ entryPath: "engineOnce/lib.ms", entrySource: HELPERS },
		{ entryPath: "engineOnce/main.ms", entrySource: main },
	];
	const before = engineRecheckCount();
	const code = js ? compileProjectToJSWithStd(entries, "engineOnce/main.ms") : compileProjectToCWithStd(entries, "engineOnce/main.ms");
	if (code.startsWith("ERROR:")) return code;
	if (!code.includes(EXPECTED)) return "the expansion is missing";
	const again = engineRecheckCount() - before;
	return again == 0 ? "" : `${again} instance bodies checked again for the engine`;
}

test "the generic instances a generic macro calls are lowered from their engine-checked bodies on C and JS" {
	const c = checkedOnce(MACRO_MAIN, false);
	assert c == "", "C: " + c;
	const js = checkedOnce(MACRO_MAIN, true);
	assert js == "", "JS: " + js;
}

test "the generic instances a comptime block calls are lowered from their engine-checked bodies on C and JS" {
	const c = checkedOnce(COMPTIME_MAIN, false);
	assert c == "", "C: " + c;
	const js = checkedOnce(COMPTIME_MAIN, true);
	assert js == "", "JS: " + js;
}

const PLAIN_HELPERS = `
export function shout(s: string): string { return s.toUpperCase() + "!"; }
export function joined(xs: string[]): string { return xs.join("-"); }
export function tally(xs: string[], v: string): number { return xs.indexOf(v) + (xs.includes(v) ? 10 : 0); }
export function numbers(xs: number[]): string { return xs.join("+") + "|" + xs.at(-1) + "|" + xs.indexOf(3); }
`;

const UNSERVED_HELPERS = `
struct Pair<T> { first: T; second: string; }
class Box { pairs: Pair<int32>[] = []; names: string[] = []; }
export function roomAndCopy(): string {
	const b = new Box();
	b.pairs.push({ first: 1, second: "p" });
	b.names.push("a");
	b.names.push("b");
	const copy = b.pairs[0];
	return copy.second + b.names.capacity().toString();
}
export function copyOnly(): string {
	const b = new Box();
	b.pairs.push({ first: 2, second: "q" });
	const copy = b.pairs[0];
	b.pairs[0].second = "changed";
	return copy.second;
}
`;

const BIG_HELPERS = `
export function big(): string { const x: bigint = 2n; return (x ** 70n).toString(); }
`;

const PLAIN_EXPECTED = "A!x-y10:1+2+3|3|2";

function plainMain(call: string, imports: string): string {
	return `
${imports}
import { Node, NodeKind } from "std/meta";

macro plainHelpers(): Node {
	const v = ${call};
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: v };
}

console.log(plainHelpers());
`;
}

const PLAIN_CALLS = `shout("a") + joined(["x", "y"]) + tally(["q", "r", "q"], "q") + ":" + numbers([1, 2, 3])`;

function plainBuild(call: string, js: boolean): string {
	const entries: MapEntry[] = [
		{ entryPath: "enginePlain/lib.ms", entrySource: PLAIN_HELPERS },
		{ entryPath: "enginePlain/main.ms", entrySource: plainMain(call, `import { shout, joined, tally, numbers } from "./lib";`) },
	];
	return js ? compileProjectToJSWithStd(entries, "enginePlain/main.ms") : compileProjectToCWithStd(entries, "enginePlain/main.ms");
}

test "build-world helpers over strings and arrays run on the VM from their build-checked bodies" {
	const before = engineRecheckCount();
	const c = plainBuild(PLAIN_CALLS, false);
	assert !c.startsWith("ERROR:"), c;
	assert c.includes(PLAIN_EXPECTED), "the C expansion is missing";
	assert engineRecheckCount() == before, `${engineRecheckCount() - before} helpers checked again: ${engineRecheckReasons().join(", ")}`;
	const js = plainBuild(PLAIN_CALLS, true);
	assert !js.startsWith("ERROR:"), js;
	assert js.includes(PLAIN_EXPECTED), "the JS expansion is missing";
}

test "a build-world helper that reaches an unserved extern is checked again and reports the extern, and the copy hooks its refused lowering lifted serve the next helper" {
	const entries: MapEntry[] = [
		{ entryPath: "engineUnserved/lib.ms", entrySource: UNSERVED_HELPERS },
		{ entryPath: "engineUnserved/main.ms", entrySource: plainMain(`roomAndCopy() + "|" + copyOnly()`, `import { roomAndCopy, copyOnly } from "./lib";`) },
	];
	const before = engineRecheckCount();
	const c = compileProjectToCWithStd(entries, "engineUnserved/main.ms");
	assert !c.startsWith("ERROR:"), c;
	assert c.includes("p2|q"), "the expansion is missing";
	assert engineRecheckCount() > before, "the capacity helper was lowered without a host function";
	let named = false;
	for (const r of engineRecheckReasons()) if (r.startsWith("extern &msStringArrayCapacity")) named = true;
	assert named, engineRecheckReasons().join(", ");
}

const ARRAY_KERNEL_HELPERS = `
interface Cell { n: number; }
export function numberKernels(): string {
	const xs: number[] = [5, 3, 9, 1, 7];
	const last = xs.pop();
	const first = xs.shift();
	xs.splice(1, 1);
	xs.splice(-1, 0, 4);
	const sorted = xs.slice(0);
	sorted.sort();
	xs.reverse();
	const joined = sorted.concat([8, 2]);
	const filled: number[] = [0, 0];
	filled.fill(6);
	return [last, first, xs.join(","), sorted.join(","), joined.slice(1, -1).join(","), filled.join(",")].join(" ");
}
export function stringKernels(): string {
	const xs: string[] = ["e", "c", "i", "a", "g"];
	const last = xs.pop();
	const first = xs.shift();
	xs.splice(-2, 1);
	xs.splice(9, 0, "d");
	const sorted = xs.slice(0);
	sorted.sort();
	xs.reverse();
	const joined = sorted.concat(["h", "b"]);
	const filled: string[] = ["", ""];
	filled.fill("z");
	const empty: string[] = [];
	return [last, first, xs.join(","), sorted.join(","), joined.slice(-3).join(","), filled.join(","), "<" + empty.shift() + ">"].join(" ");
}
export function scalarKernels(): string {
	const bs: uint8[] = [1, 2, 3];
	bs.splice(1, 1, 9);
	const flags: boolean[] = [true, false];
	flags.splice(0, 1, false);
	const cells: Cell[] = [{ n: 1 }, { n: 2 }];
	const top = cells.pop();
	const ints: int32[] = [4, 5, 6];
	return [bs.join(","), flags.join(","), top.n, cells.length, ints.pop(), ints.length].join(" ");
}
`;

test "a build-world helper calling the C tier's array kernels runs on the VM from its build-checked body and returns what the C kernels return" {
	const xs: number[] = [5, 3, 9, 1, 7];
	const last = xs.pop();
	const first = xs.shift();
	xs.splice(1, 1);
	xs.splice(-1, 0, 4);
	const sorted = xs.slice(0);
	sorted.sort();
	xs.reverse();
	const joinedNumbers = sorted.concat([8, 2]);
	const filledNumbers: number[] = [0, 0];
	filledNumbers.fill(6);
	const ys: string[] = ["e", "c", "i", "a", "g"];
	const lastText = ys.pop();
	const firstText = ys.shift();
	ys.splice(-2, 1);
	ys.splice(9, 0, "d");
	const sortedText = ys.slice(0);
	sortedText.sort();
	ys.reverse();
	const joinedText = sortedText.concat(["h", "b"]);
	const expected = [
		[last, first, xs.join(","), sorted.join(","), joinedNumbers.slice(1, -1).join(","), filledNumbers.join(",")].join(" "),
		[lastText, firstText, ys.join(","), sortedText.join(","), joinedText.slice(-3).join(","), "z,z", "<>"].join(" "),
		"1,9,3 false,false 2 1 6 2",
	].join("|");
	const entries: MapEntry[] = [
		{ entryPath: "engineArrayKernel/lib.ms", entrySource: ARRAY_KERNEL_HELPERS },
		{ entryPath: "engineArrayKernel/main.ms", entrySource: plainMain(`numberKernels() + "|" + stringKernels() + "|" + scalarKernels()`, `import { numberKernels, stringKernels, scalarKernels } from "./lib";`) },
	];
	const before = engineRecheckCount();
	const c = compileProjectToCWithStd(entries, "engineArrayKernel/main.ms");
	assert !c.startsWith("ERROR:"), c;
	assert c.includes(expected), `the expansion differs from the C kernels: ${expected}`;
	assert engineRecheckCount() == before, `${engineRecheckCount() - before} helpers checked again: ${engineRecheckReasons().join(", ")}`;
}

const KERNEL_HELPERS = `
export function lastAt(s: string, sub: string, start: int32): int32 { return s.lastIndexOf(sub, start); }
export function floatRadix(n: number, r: int32): string { return n.toString(r); }
export function intRadix(n: int64, r: int32): string { return n.toString(r); }
export function unsignedRadix(n: uint64, r: int32): string { return n.toString(r); }
export function counted(xs: string[], v: string): number { return xs.count(v) + xs.lastIndexOf(v); }
export function atOf(xs: number[], i: number): number { return xs.at(i); }
`;

test "a build-world helper returns what the C kernels return where the VM prelude body differs" {
	const text = "héllo wörld";
	const expected = [
		text.lastIndexOf("o", 8).toString(),
		(255.5).toString(16),
		(-10.0).toString(2),
		(123456789012 as int64).toString(36),
		(4000000000 as uint64).toString(7),
		(["a", "b", "a"].count("a") + ["a", "b", "a"].lastIndexOf("a")).toString(),
		([4, 5, 6].at(-2)).toString(),
	].join("|");
	const call = `lastAt("h\\u00e9llo w\\u00f6rld", "o", 8).toString() + "|" + floatRadix(255.5, 16) + "|" + floatRadix(-10.0, 2) + "|" + intRadix(123456789012, 36) + "|" + unsignedRadix(4000000000, 7) + "|" + counted(["a", "b", "a"], "a").toString() + "|" + atOf([4, 5, 6], -2).toString()`;
	const entries: MapEntry[] = [
		{ entryPath: "engineKernel/lib.ms", entrySource: KERNEL_HELPERS },
		{ entryPath: "engineKernel/main.ms", entrySource: plainMain(call, `import { lastAt, floatRadix, intRadix, unsignedRadix, counted, atOf } from "./lib";`) },
	];
	const c = compileProjectToCWithStd(entries, "engineKernel/main.ms");
	assert !c.startsWith("ERROR:"), c;
	assert c.includes(expected), `the expansion differs from the C kernels: ${expected}`;
}

test "a build-world helper holding a bigint runs on the VM with every digit" {
	const entries: MapEntry[] = [
		{ entryPath: "engineBig/lib.ms", entrySource: BIG_HELPERS },
		{ entryPath: "engineBig/main.ms", entrySource: plainMain(`big()`, `import { big } from "./lib";`) },
	];
	const c = compileProjectToCWithStd(entries, "engineBig/main.ms");
	assert !c.startsWith("ERROR:"), c;
	assert c.includes("1180591620717411303424"), "the bigint expansion is missing";
}

const MAP_HELPER = `function storedThree(k: string): int32 { const m = new Map<string, int32>(); m.set(k, 3); return m.get(k) ?? -1; }`;

function mapOnC(entries: MapEntry[]): string {
	const before = engineRecheckCount();
	const c = compileProjectToCWithStd(entries, "engineMapC/main.ms");
	if (c.startsWith("ERROR:")) return c;
	if (!c.includes("33")) return "the expansion is missing";
	const again = engineRecheckCount() - before;
	return again == 0 ? "" : `${again} helpers checked again: ${engineRecheckReasons().join(", ")}`;
}

test "a comptime block runs a Map helper of another module on C from the build-checked class and helper" {
	const failure = mapOnC([
		{ entryPath: "engineMapC/lib.ms", entrySource: `import { Map } from "std/core/struct";\nexport ${MAP_HELPER}\n` },
		{ entryPath: "engineMapC/main.ms", entrySource: `import { storedThree } from "./lib";\nconst V: int32 = @comptime { return storedThree("a") + 30; };\nconsole.log(V);\n` },
	]);
	assert failure == "", failure;
}

test "a comptime block runs a Map helper of the module still in check on C from its checked body" {
	const failure = mapOnC([
		{ entryPath: "engineMapC/main.ms", entrySource: `import { Map } from "std/core/struct";\n${MAP_HELPER}\nconst V: int32 = @comptime { return storedThree("a") + 30; };\nconsole.log(V);\n` },
	]);
	assert failure == "", failure;
}

const MAP_HELPERS = `
import { Map } from "std/core/struct";
export function storedThree(k: string): int32 { const m = new Map<string, int32>(); m.set(k, 3); return m.get(k) ?? -1; }
`;

function mapBuild(main: string, js: boolean): string {
	const entries: MapEntry[] = [
		{ entryPath: "engineMap/lib.ms", entrySource: MAP_HELPERS },
		{ entryPath: "engineMap/main.ms", entrySource: main },
	];
	return js ? compileProjectToJSWithStd(entries, "engineMap/main.ms") : compileProjectToCWithStd(entries, "engineMap/main.ms");
}

function mapRuns(main: string): string {
	const c = mapBuild(main, false);
	if (c.startsWith("ERROR:") || !c.includes("33")) return `C: ${c.slice(0, 300)} | rechecks: ${engineRecheckReasons().join(", ")}`;
	const js = mapBuild(main, true);
	if (js.startsWith("ERROR:") || !js.includes("33")) return `JS: ${js.slice(0, 300)} | rechecks: ${engineRecheckReasons().join(", ")}`;
	return "";
}

test "a comptime block runs an imported helper that calls Map extensions on C and JS" {
	const failure = mapRuns(`import { storedThree } from "./lib";\nconst V: int32 = @comptime { return storedThree("a") + 30; };\nconsole.log(V);\n`);
	assert failure == "", failure;
}

test "a comptime block runs a Map helper declared in its own module on C and JS" {
	const failure = mapRuns(`import { Map } from "std/core/struct";\nfunction storedThree(k: string): int32 { const m = new Map<string, int32>(); m.set(k, 3); return m.get(k) ?? -1; }\nconst V: int32 = @comptime { return storedThree("a") + 30; };\nconsole.log(V);\n`);
	assert failure == "", failure;
}

const GENERIC_BASE_LIB = `
export class GBase<T> {
	n: number;
	constructor(n: number) { this.n = n; }
}
export class GSub extends GBase<int32> {
	constructor(n: number) { super(n + 2); }
}
`;

const GENERIC_BASE_MAIN = `import { GSub } from "./lib";
import { Node, NodeKind } from "std/meta";

macro built(): Node {
	const v = "generic=" + new GSub(1).n.toString() + " bytes=" + new Uint8Array(4).length.toString();
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: v };
}

console.log(built());
`;

test "a macro builds a class through a generic base and a typed array from their build-checked bodies" {
	const entries: MapEntry[] = [
		{ entryPath: "engineGenericBase/lib.ms", entrySource: GENERIC_BASE_LIB },
		{ entryPath: "engineGenericBase/main.ms", entrySource: GENERIC_BASE_MAIN },
	];
	const before = engineRecheckCount();
	const c = compileProjectToCWithStd(entries, "engineGenericBase/main.ms");
	assert !c.startsWith("ERROR:"), c;
	assert c.includes("generic=3 bytes=4"), "the expansion is missing";
	assert engineRecheckCount() == before, `${engineRecheckCount() - before} helpers checked again: ${engineRecheckReasons().join(", ")}`;
}
