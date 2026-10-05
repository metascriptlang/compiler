import { compileToC, compileProjectToC, MapEntry } from "../helpers";

const LIB_PATH = "test/inlineFunctions/lib.ms";
const OTHER_PATH = "test/inlineFunctions/other.ms";
const MAIN_PATH = "test/inlineFunctions/main.ms";

const LIB = `export struct Span2 {
	low: int32;
	high: int32;
}

@inline
export function twice(n: int32): int32 {
	return n * 2;
}

export function plain(n: int32): int32 {
	return n + 7;
}

@inline
export function \`+\`(this a: Span2, b: Span2): Span2 {
	return { low: a.low + b.low, high: a.high + b.high };
}

@inline
export function width(this s: Span2): int32 {
	return s.high - s.low;
}
`;

const OTHER = `import { twice, Span2, width } from "./lib";

export function fromOther(n: int32): int32 {
	const s: Span2 = { low: n, high: twice(n) };
	return s.width();
}
`;

const MAIN = `import { twice, plain, Span2, width } from "./lib";
import { fromOther } from "./other";

const n: int32 = 20;
const a: Span2 = { low: 1, high: 5 };
const b: Span2 = { low: 2, high: 9 };
console.log(twice(n), plain(n), (a + b).width(), fromOther(n));
`;

function emitted(): string {
	const entries: MapEntry[] = [
		{ entryPath: LIB_PATH, entrySource: LIB },
		{ entryPath: OTHER_PATH, entrySource: OTHER },
		{ entryPath: MAIN_PATH, entrySource: MAIN },
	];
	return compileProjectToC(entries, MAIN_PATH);
}

function moduleC(cCode: string, stem: string): string {
	const units = cCode.split("#include <stdint.h>\n");
	for (const unit of units) {
		if (unit.contains(`Z${stem}Oms__Init000(void) {`)) return unit;
	}
	return "";
}

function defines(unit: string, routine: string): boolean {
	const lines = unit.split("\n");
	for (const line of lines) {
		if (line.contains(routine + "__") && line.endsWith(") {")) return true;
	}
	return false;
}

function definesStaticInline(unit: string, routine: string): boolean {
	const lines = unit.split("\n");
	for (const line of lines) {
		if (line.startsWith("static inline ") && line.contains(routine + "__") && line.endsWith(") {")) return true;
	}
	return false;
}

test "an @inline function is defined static inline in every module that calls it" {
	const cCode = emitted();
	assert !cCode.startsWith("ERROR"), cCode;
	const main = moduleC(cCode, "main");
	const other = moduleC(cCode, "other");
	assert main != "" && other != "";
	assert definesStaticInline(main, "twice");
	assert definesStaticInline(other, "twice");
	assert definesStaticInline(main, "plus");
	assert definesStaticInline(main, "width");
	assert definesStaticInline(other, "width");
}

test "a module that declares an @inline function but never calls it has no copy" {
	const lib = moduleC(emitted(), "lib");
	assert lib != "";
	assert !defines(lib, "twice");
	assert !defines(lib, "width");
	assert defines(lib, "plain");
}

test "a plain function stays one definition in its own module" {
	const main = moduleC(emitted(), "main");
	assert !defines(main, "plain");
}

function refusal(source: string): string {
	const c = compileToC(source);
	return c.ok ? "" : c.error;
}

const ADD_ONE = `@inline
function addOne(n: int32): int32 {
	return n + 1;
}
`;

test "@inline is refused on anything but a module-level function" {
	const rows = [
		`function outer(k: int32): int32 {\n\t@inline\n\tfunction inner(n: int32): int32 { return n + k; }\n\treturn inner(3);\n}\nconsole.log(outer(4));\n`,
		`class A {\n\t@inline\n\tm(n: int32): int32 { return n + 1; }\n}\nconsole.log(new A().m(4));\n`,
		`@inline\nconst k: int32 = 4;\nconsole.log(k);\n`,
	];
	for (const row of rows) assert refusal(row).contains("@inline applies to a module-level function"), row;
}

test "@inline needs a body, takes no arguments and exports no C symbol" {
	assert refusal(`@inline\nextern function abs(n: int32): int32 from "abs";\nconsole.log(abs(-4));\n`).contains("@inline needs a function with a body");
	assert refusal(`@inline("always")\nfunction f(n: int32): int32 { return n + 1; }\nconsole.log(f(4));\n`).contains("@inline takes no arguments");
	assert refusal(`@inline @exportName("ex_c")\nexport function ex(n: int32): int32 { return n + 1; }\nconsole.log(ex(4));\n`).contains("no single C symbol to export");
}

test "an @inline function does not convert to a function value" {
	const rows = [
		`function apply(f: (n: int32) => int32, x: int32): int32 { return f(x); }\nconsole.log(apply(addOne, 3));\n`,
		`const h = addOne;\nconsole.log(h(1));\n`,
		`function pick(f: ((n: int32) => int32) | null): int32 { return f !== null ? f(2) : 0; }\nconsole.log(pick(addOne));\n`,
		`const fs: ((n: int32) => int32)[] = [addOne];\nconsole.log(fs[0](3));\n`,
	];
	for (const row of rows) assert refusal(ADD_ONE + row).contains("@inline function"), row;
	assert refusal(ADD_ONE + `function apply(f: (n: int32) => int32, x: int32): int32 { return f(x); }\nconsole.log(apply((n: int32): int32 => addOne(n), 3));\n`) == "";
}

test "an @inline function cannot own a static slot" {
	const source = `@inline\nfunction once(): int32 {\n\tstatic const t: int32 = 4;\n\treturn t;\n}\nconsole.log(once());\n`;
	assert refusal(source).contains("cannot own a 'static' slot");
}
