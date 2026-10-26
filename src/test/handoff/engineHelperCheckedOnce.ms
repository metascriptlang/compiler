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
export function popped(xs: string[]): string { return xs.pop(); }
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
		{ entryPath: "enginePlain/main.ms", entrySource: plainMain(call, `import { shout, joined, tally, numbers, popped } from "./lib";`) },
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

test "a build-world helper that reaches an unserved extern is checked again and reports the extern" {
	const before = engineRecheckCount();
	const c = plainBuild(`popped(["p", "o"])`, false);
	assert !c.startsWith("ERROR:"), c;
	assert c.includes("o"), "the expansion is missing";
	assert engineRecheckCount() > before, "the pop helper was lowered without a host function";
	let named = false;
	for (const r of engineRecheckReasons()) if (r.startsWith("extern &msStringArrayPop")) named = true;
	assert named, engineRecheckReasons().join(", ");
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
