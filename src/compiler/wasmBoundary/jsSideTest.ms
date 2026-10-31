import { ExtensionRegistry, buildExportInfo, ExportedSymInfo, CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "../../test/handoff/helpers";
import { BoundaryCallback, BoundaryFunction, BoundaryKind, BoundaryMode, Manifest, copiesArgsIn, manifestFor } from "./manifest";
import { jsBindings } from "./jsSide";
import { wasmEntrySource } from "./wasmSide";
import { ensureDir, writeFile } from "std/fs";
import { execFileResult } from "std/process";

const SOURCE = `
struct Point { x: float64; y: float64; }
struct Label { at: Point; text: string; count: int32; }
export function tag(l: Label): Label { return l; }
export function scale(xs: Vec<float32>, k: float32): Vec<uint16> { const out: Vec<uint16> = []; return out; }
export function total(xs: Readonly<Span<float32>>): float32 { return 0; }
export function fill(xs: Span<boolean>, at: int32): void {}
export function add64(a: int64, b: int64): int64 { return a + b; }
export function mul64u(a: uint64, b: uint64): uint64 { return a * b; }
export function evaluate(value: int32, cb: (x: int32) => int32): int32 { return cb(value) + 1; }
export function isEven(x: uint8): boolean { return x % 2 == 0; }
export function flip(b: boolean): boolean { return !b; }
export function wide(x: uint32): uint32 { return x; }
export function visit(n: int32, cb: (x: int32, y: float64) => void): void { cb(n, 1.5); }
export function pick(f: (a: boolean, b: uint32) => boolean): void { f(true, 1); }
export function twice(s: string): string { return s + s; }
export function banner(): string { return "banner"; }
export function mixed(s: string, xs: Vec<float32>): int32 { return s.length; }
export function both(a: string, n: int32, b: string): int32 { return a.length + n + b.length; }
export function sumBy(n: int32, cb: (xs: Readonly<Span<float32>>) => float32): float32 { return 0; }
export function edit(cb: (xs: Span<boolean>, at: int32) => void): void {}
export function drain(cb: (x: int64, y: float32) => int64): int64 { return cb(1, 2); }
export function noArg(cb: () => void): void { cb(); }
export function onByte(cb: (x: uint8, y: int32) => void): void { cb(1, 2); }
export function judge(cb: (x: int32) => boolean): void { cb(1); }
export function patch(cb: (xs: Span<int32>) => int32): int32 { return 0; }
export function stamp(s: string, xs: Span<int32>): int32 { return 0; }
export function cut(xs: Span<int32>): Vec<int32> { const out: Vec<int32> = []; return out; }
export function swap(a: Span<int32>, b: Span<int32>): void {}
export function bump(x: int32): int32 { return x + 1; }
export function bump(x: float64): float64 { return x + 0.5; }
`;

const NULLABLE = `
struct Pos { x: int32; y: int32 | null; }
struct Item { id: int32; note: string | null; score: float64 | null; ok: boolean | null; at: Pos; }
export function orMinus(a: int32 | null): int32 { return a ?? -1; }
export function sumBig(a: int64 | null, b?: int64): int64 { return 0; }
export function echoU32(n: uint32 | null): uint32 | null { return n; }
export function halve(x: float64): float64 | null { return x; }
export function parity(n: uint8): boolean | null { return null; }
export function greet(s: string | null): string | null { return s; }
export function headOr(xs: Vec<int32> | null): int32 { return 0; }
export function upTo(n: int32): Vec<float32> | null { return null; }
export function bump(i: Item | null): Item | null { return i; }
export function replay(cb: (n: int32 | null, s: string | null) => void): void {}
export function replayBig(cb: (f: boolean | null, b: int64 | null) => void): void {}
`;

function manifestFrom(source: string, names: string[]): Manifest {
	const ctx = checkSource(source);
	if (ctx == null) throw new Error("internal: test source did not check");
	const exps: ExportedSymInfo[] = [];
	for (const n of names) {
		const sym = lookupSymbol(ctx.table, n);
		if (sym == null) throw new Error("internal: test source lacks " + n);
		exps.push(buildExportInfo(sym!, null as unknown as ExtensionRegistry, "/p/calc.ms", null as unknown as CheckerContext));
	}
	const m = manifestFor("/p/calc.ms", "/p/app.ms", exps, names);
	if (m.errors.length > 0) throw new Error("internal: " + m.errors.map((e) => e.message).join("; "));
	return m;
}

function manifestOf(names: string[]): Manifest {
	return manifestFrom(SOURCE, names);
}

function bindingsWith(names: string[], bundleNameOf: (f: BoundaryFunction) => string, checked: boolean = false) {
	return jsBindings(manifestOf(names), "./app.wasm.mjs", bundleNameOf, { checked: checked });
}

function bindingsFor(names: string[], checked: boolean = false) {
	return bindingsWith(names, (f) => "bundled_" + f.name, checked);
}

function nullableBindings(names: string[]) {
	return jsBindings(manifestFrom(NULLABLE, names), "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false });
}

test "js side: 64-bit and bool and narrow results are coerced at the boundary" {
	const code = bindingsFor(["add64", "mul64u", "isEven", "flip", "wide"]).modules[0].code;
	assert code.includes("function bundled_add64(a0, a1) {\n\t__msb.enter();\n\treturn __msbMod._msb_calc_add64(a0, a1);\n}");
	assert code.includes("return BigInt.asUintN(64, __msbMod._msb_calc_mul64u(a0, a1));");
	assert code.includes("return __msbMod._msb_calc_isEven(a0) !== 0;");
	assert code.includes("return __msbMod._msb_calc_flip((a0 ? 1 : 0)) !== 0;");
	assert code.includes("return __msbMod._msb_calc_wide(a0) >>> 0;");
}

test "js side: a callback is pushed before the call, adapted per kind and popped in finally" {
	const code = bindingsFor(["evaluate", "visit", "pick"]).modules[0].code;
	assert code.includes("function bundled_evaluate(a0, a1) {\n\t__msb.enter();\n\tconst id1 = __msb.push(a1);\n\ttry {\n\t\treturn __msbMod._msb_calc_evaluate(a0, id1);\n\t} finally {\n\t\t__msb.pop(id1);\n\t}\n}");
	assert code.includes("const id1 = __msb.push(a1);\n\ttry {\n\t\t__msbMod._msb_calc_visit(a0, id1);");
	assert code.includes("const id0 = __msb.push((x0, x1) => (a0(x0 !== 0, x1 >>> 0) ? 1 : 0));");
}

test "js side: a callback whose adapter would only forward its arguments is pushed as the user function" {
	assert bindingsFor(["drain"]).modules[0].code.includes("const id0 = __msb.push(a0);");
	assert bindingsFor(["noArg"]).modules[0].code.includes("const id0 = __msb.push(a0);");
	assert !bindingsFor(["evaluate"]).modules[0].code.includes("=> a1(x0)");
}

test "js side: a callback that converts a parameter or a result keeps its adapter" {
	assert bindingsFor(["onByte"]).modules[0].code.includes("const id0 = __msb.push((x0, x1) => { a0(x0 & 255, x1); });");
	assert bindingsFor(["judge"]).modules[0].code.includes("const id0 = __msb.push((x0) => (a0(x0) ? 1 : 0));");
	for (const n of ["onByte", "judge", "pick", "sumBy", "edit"]) {
		assert !bindingsFor([n]).modules[0].code.includes("__msb.push(a");
	}
}

test "js side: one prelude awaits the wasm module once, hands it its own registry, and a stale callback id throws" {
	const b = bindingsFor(["add64"]);
	assert b.modules.length == 1;
	assert b.modules[0].modulePath == "/p/calc.ms";
	assert b.prelude.includes('const __msbMod = await (await import("./app.wasm.mjs")).default({ msb: __msb });\n__msbMod._MsMain();\n');
	assert !b.prelude.includes("globalThis.__msb");
	assert b.prelude.includes('throw new Error("callback used after its call returned");');
	assert b.prelude.indexOf("const __msb = ") < b.prelude.indexOf("default({ msb: __msb })");
}

test "js side: callback ids are generation-tagged slots of a dense table with a free list" {
	const p = bindingsFor(["add64"]).prelude;
	assert !p.includes("new Map()");
	assert !p.includes("...a");
	assert p.includes("\t\t\tlet s = free.pop();\n\t\t\tif (s === undefined) {\n\t\t\t\tif (vals.length >= 65536) throw new RangeError(\"boundary table full: 65536 live entries\");\n");
	assert p.includes("\t\t\tvals[s] = f;\n\t\t\treturn (gens[s] << 16) | s;\n");
	assert p.includes("\t\t\tgens[s] = (gens[s] + 1) & 32767;\n\t\t\tfree.push(s);\n");
	assert p.includes("\t\t\tif (vals[s] === undefined || gens[s] !== id >>> 16) throw new Error(\"boundary entry released twice\");\n");
	assert p.includes("\t\tcb(id) {\n\t\t\tconst s = id & 65535;\n\t\t\tif (vals[s] === undefined || gens[s] !== id >>> 16) throw new Error(\"callback used after its call returned\");\n\t\t\treturn vals[s];\n\t\t},\n");
}

test "js side: a string parameter is encoded as a payload that wasm adopts, and freed here only when the call was never made" {
	const code = bindingsFor(["both"]).modules[0].code;
	assert code.includes("function bundled_both(a0, a1, a2) {\n\t__msb.enter();\n\tlet e0, e2, sent = false;\n\tconst mark = __msbTop;\n\ttry {\n\t\te0 = __msbEncOwned(a0);\n\t\te2 = __msbEncOwned(a2);\n\t\tsent = true;\n\t\treturn __msbMod._msb_calc_both(e0[0], e0[1], a1, e2[0], e2[1]);\n\t} finally {\n\t\t__msbTop = mark;\n\t\tif (e0 && !sent) __msbMod._free(e0[0]);\n\t\tif (e2 && !sent) __msbMod._free(e2[0]);\n\t}\n}");
}

test "js side: a Vec beside a string is still released after the call, only the string block is wasm's" {
	const code = bindingsFor(["mixed"]).modules[0].code;
	assert code.includes("function bundled_mixed(a0, a1) {\n\t__msb.enter();\n\tlet e0, e1, sent = false;\n\tconst mark = __msbTop;\n\ttry {\n\t\te0 = __msbEncOwned(a0);\n\t\te1 = __msbCopyIn(a1, 0, a1.length, Float32Array);\n\t\tsent = true;\n\t\treturn __msbMod._msb_calc_mixed(e0[0], e0[1], e1[0], e1[1]);\n\t} finally {\n\t\t__msbTop = mark;\n\t\tif (e0 && !sent) __msbMod._free(e0[0]);\n\t\tif (e1) __msbFree(e1[0]);\n\t}\n}");
}

test "js side: copied arguments are bump-allocated from the scratch block, and only a heap pointer is freed" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.includes("function __msbAlloc(n) {\n\tconst room = __msbEnd - __msbTop;\n\tif (n <= room) {\n\t\tconst a = n + 15 & -16;\n\t\tif (a <= room) {\n\t\t\tconst q = __msbTop;\n\t\t\t__msbTop = q + a;\n\t\t\treturn q;\n\t\t}\n\t}\n\treturn __msbHeapAlloc(n);\n}");
	assert p.includes("function __msbHeapAlloc(n) {\n\tconst p = n > 4294967295 ? 0 : __msbMod._malloc(n);");
	assert p.includes("function __msbFree(p) {\n\tif (p < __msbBase || p >= __msbEnd) __msbMod._free(p);\n}");
	assert !bindingsFor(["scale", "fill"]).modules[0].code.includes("__msbMod._free");
}

test "js side: the scratch block is reserved once after _MsMain, and only when a wrapper copies arguments in" {
	const used = bindingsFor(["scale"]).prelude;
	assert used.includes("__msbMod._MsMain();\nconst __msbBase = __msbMod._malloc(16384);\nconst __msbEnd = __msbBase === 0 ? 0 : __msbBase + 16384;\nlet __msbTop = __msbBase;\n");
	assert used.split("__msbMod._malloc(16384)").length == 2;
	for (const name of ["both", "twice", "tag", "total", "fill"]) assert bindingsFor([name]).prelude.includes("__msbMod._malloc(16384)");
	const none = bindingsFor(["add64", "evaluate", "sumBy"]);
	assert none.prelude.includes("__msbMod._MsMain();\nconst __msbBase = 0;\nconst __msbEnd = 0;\nlet __msbTop = 0;\n");
	assert !none.prelude.includes("_malloc(16384)");
	assert !none.modules[0].code.includes("__msbTop");
}

test "js side: a wrapper marks the scratch top before its first encode and resets it first in finally, even when a copy-back throws" {
	const code = bindingsFor(["tag", "scale", "fill"]).modules[0].code;
	assert code.split("\tconst mark = __msbTop;\n\ttry {").length == 4;
	assert code.split("\t} finally {\n\t\t__msbTop = mark;\n").length == 4;
	assert code.includes("\tlet e0_2, sent = false;\n\tconst mark = __msbTop;\n\ttry {\n\t\te0_2 = __msbEncOwned(a0.text);");
}

const EVERY_FUNCTION = ["tag", "scale", "total", "fill", "add64", "mul64u", "evaluate", "isEven", "flip", "wide", "visit", "pick", "twice", "banner", "both", "sumBy", "edit", "patch", "stamp", "cut", "swap"];

test "js side: a wrapper takes a scratch mark exactly when its function copies an argument in, and the wasm half adopts a string block and never a Vec or Span block" {
	for (const name of EVERY_FUNCTION) {
		const m = manifestOf([name]);
		const wants = copiesArgsIn(m.functions[0]);
		const js = jsBindings(m, "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false });
		const code = js.modules[0].code;
		assert code.includes("const mark = __msbTop;") == wants;
		assert code.includes("__msbFree(") == code.includes("__msbCopyIn(");
		assert code.includes("__msbMod._free(") == code.includes("__msbEncOwned(");
		assert js.prelude.includes("__msbMod._malloc(16384)") == wants;
		if (wants) {
			const e = wasmEntrySource(m.functions, (p: string) => "./calc");
			assert e.exportedFunctions.includes("_malloc");
			assert e.exportedFunctions.includes("_free");
			assert e.runtimeMethods.includes("HEAPU8");
			assert e.source.includes("msStringAdoptMalloced") == code.includes("__msbEncOwned(");
		}
	}
}

test "js side: a string result is built by a taker pushed for the call, so a nested call keeps its own" {
	const b = bindingsFor(["twice"]);
	assert b.modules[0].code.includes("function bundled_twice(a0) {\n\t__msb.enter();\n\tlet r;\n\tconst d = __msb.takes.push((p, n) => { r = __msbDec(p >>> 0, n); }) - 1;\n\tlet e0, sent = false;\n\tconst mark = __msbTop;\n\ttry {\n\t\te0 = __msbEncOwned(a0);\n\t\tsent = true;\n\t\t__msbMod._msb_calc_twice(e0[0], e0[1]);\n\t\treturn r;\n\t} finally {\n\t\t__msbTop = mark;\n\t\tif (e0 && !sent) __msbMod._free(e0[0]);\n\t\t__msb.takes.length = d;\n\t}\n}");
	assert !b.modules[0].code.includes("msb_ret_len");
	assert !b.prelude.includes("msb_ret_len");
}

test "js side: a string result with no parameter still pushes its taker and pops it in finally" {
	const code = bindingsFor(["banner"]).modules[0].code;
	assert code.includes("function bundled_banner() {\n\t__msb.enter();\n\tlet r;\n\tconst d = __msb.takes.push((p, n) => { r = __msbDec(p >>> 0, n); }) - 1;\n\ttry {\n\t\t__msbMod._msb_calc_banner();\n\t\treturn r;\n\t} finally {\n\t\t__msb.takes.length = d;\n\t}\n}");
}

test "js side: the owned string encoder lays out a payload, cap then bytes then a NUL, from the heap allocator, and sends no block for an empty string" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.includes("function __msbSeal(h, p, n) {\n\th[p] = n; h[p + 1] = n >>> 8; h[p + 2] = n >>> 16; h[p + 3] = n >>> 24;\n\th[p + 4] = 0; h[p + 5] = 0; h[p + 6] = 0; h[p + 7] = 0;\n\th[p + 8 + n] = 0;\n\treturn [p, n];\n}");
	const enc = p.slice(p.indexOf("function __msbEncAt("), p.indexOf("function __msbDecLoop("));
	assert enc.includes("\tif (own && n === 0) return [0, 0];\n\tconst hd = own ? 8 : 0;\n");
	assert enc.includes("const p = __msbHeapAlloc(own ? n + 9 : n || 1);");
	assert enc.includes("h.subarray(p + hd, p + hd + n)");
	assert enc.includes("return own ? __msbSeal(h, p, n) : [p, n];");
	assert enc.includes("const p = __msbHeapAlloc(own ? cap + 9 : cap);\n\tconst h = __msbMod.HEAPU8;\n\tlet o = p + hd;");
	assert enc.includes("if (o - p - hd > cap) throw new Error(");
	assert enc.includes("return own ? __msbSeal(h, p, o - p - hd) : [p, o - p];");
	assert !enc.includes("__msbAlloc(");
	assert enc.includes("function __msbEnc(s) {\n\treturn __msbEncAt(s, false);\n}\nfunction __msbEncOwned(s) {\n\treturn __msbEncAt(s, true);\n}");
	assert p.includes("function __msbCopyIn(a, off, n, T) {\n\t__msbInRange(a, off, n);\n\tconst p = __msbAlloc(");
}

test "js side: a callback string parameter arrives as pointer and length and is decoded" {
	const cb: BoundaryCallback = { params: [BoundaryKind.String, BoundaryKind.I32], nullables: [false, false], elements: [BoundaryKind.Void, BoundaryKind.Void], modes: [BoundaryMode.Copied, BoundaryMode.Copied], result: BoundaryKind.I32, signature: "i_si" };
	const m: Manifest = {
		functions: [{
			modulePath: "/p/calc.ms", moduleKey: "calc", name: "note", overloadIndex: 0, exportSymbol: "msb_calc_note",
			params: [{ name: "cb", kind: BoundaryKind.Callback, nullable: false, mode: BoundaryMode.Borrowed, callback: cb, leaves: [], element: BoundaryKind.Void }],
			result: BoundaryKind.Void, resultNullable: false, resultLeaves: [], resultElement: BoundaryKind.Void,
		}],
		errors: [],
	};
	const code = jsBindings(m, "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false }).modules[0].code;
	assert code.includes("const id0 = __msb.push((x0, x1, x2) => a0(__msbDec(x0, x1), x2));");
}

test "js side: a callback Span parameter arrives as a copied view, a writable one is copied back after the call even when the callback throws" {
	const code = bindingsFor(["sumBy", "edit"]).modules[0].code;
	assert code.includes("const id1 = __msb.push((x0, x1) => { const s0 = { base: __msbVecOut(x0 >>> 0, x1, Float32Array, false), off: 0, len: x1 }; return a1(s0); });");
	assert code.includes("const id0 = __msb.push((x0, x1, x2) => { const s0 = { base: __msbVecOut(x0 >>> 0, x1, Uint8Array, true), off: 0, len: x1 }; try { a0(s0, x2); } finally { __msbCopyTo(x0 >>> 0, s0.base, 0, x1, Uint8Array); } });");
}

test "js side: the prelude carries the string glue once and reads the heap fresh" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.indexOf("function __msbEnc(s)") == p.lastIndexOf("function __msbEnc(s)");
	assert p.includes("function __msbDec(p, len)");
	assert p.includes("__msbMod.HEAPU8");
	assert !p.includes("wasmMemory");
}

test "js side: the string decoder is built with ignoreBOM" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.includes("const __msbTd = new TextDecoder('utf-8', { ignoreBOM: true });");
	assert p.indexOf("new TextDecoder(") == p.lastIndexOf("new TextDecoder(");
}

test "js side: a long string decodes natively first and is scanned for a surrogate only when the result holds U+FFFD" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.includes("const s = __msbTd.decode(h.subarray(p, e));");
	assert p.includes("if (s.indexOf(\"\\uFFFD\") < 0) return s;");
	assert p.includes("h[i] === 0xed");
	assert p.indexOf("const s = __msbTd.decode(h.subarray(p, e));") < p.indexOf("if (s.indexOf(\"\\uFFFD\") < 0) return s;");
	assert p.indexOf("if (s.indexOf(\"\\uFFFD\") < 0) return s;") < p.indexOf("h[i] === 0xed");
}

test "js side: a failed wasm allocation throws instead of writing at address 0" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.includes("if (p === 0) throw new RangeError(");
	assert !p.includes("const p = __msbMod._malloc(n || 1);") && !p.includes("const p = __msbMod._malloc(n * 3);");
}

const GLUE_STUB = `const __msbBase = 0;
const __msbEnd = 0;
let __msbTop = 0;
const calls = [];
const heap = new Uint8Array(1 << 22);
let top = 16;
const __msbMod = {
	HEAPU8: heap,
	_malloc(n) {
		calls.push(n);
		if (n > heap.length - top) return 0;
		const p = top;
		top += n;
		return p;
	},
};
`;

const GLUE_CHECKS = `
const ok = (c, m) => { if (!c) throw new Error(m); };
const u = (...c) => String.fromCharCode(...c);
const wtf8 = (s) => {
	let t = 0;
	for (const ch of s) { const c = ch.codePointAt(0); t += c < 128 ? 1 : c < 2048 ? 2 : c < 65536 ? 3 : 4; }
	return t;
};
const A = u(233), B = u(20013), C = u(0xd83d, 0xde00), HI = u(0xd83d), LO = u(0xde00);
const base = "a".repeat(5000);
const long = [A.repeat(5000), B.repeat(5000), C.repeat(5000), base + A, base + HI, base + C, base + LO + HI, (A + B + C + HI + "x" + LO).repeat(1000)];
for (const s of long) {
	const want = wtf8(s);
	calls.length = 0;
	const r = __msbEnc(s);
	ok(calls.length === 1, "one allocation expected, got " + calls.length);
	ok(calls[0] === want, "allocated " + calls[0] + " bytes for " + want + " bytes of " + s.length + " units");
	ok(r[1] === want, "length " + r[1] + " expected " + want);
	ok(__msbDec(r[0], r[1]) === s, "round trip of " + s.length + " units");
}
const short = [A.repeat(10), C.repeat(10), HI, LO + HI, u(97, 0xd83d, 98)];
for (const s of short) {
	calls.length = 0;
	const r = __msbEnc(s);
	ok(calls[0] <= 3 * s.length, "short string allocated " + calls[0] + " bytes for " + s.length + " units");
	ok(r[1] === wtf8(s), "short length " + r[1] + " expected " + wtf8(s));
	ok(__msbDec(r[0], r[1]) === s, "short round trip");
}
calls.length = 0;
ok(__msbEnc("abc")[1] === 3 && calls[0] === 3, "ascii allocates its length");
ok(__msbEnc("")[1] === 0 && calls[1] === 1, "empty ascii allocates one byte");
calls.length = 0;
for (const n of [4294967296, 4294967298]) {
	let e = null;
	try { __msbAlloc(n); } catch (x) { e = x; }
	ok(e instanceof RangeError, "a size of " + n + " must throw a RangeError");
}
ok(calls.length === 0, "_malloc was called with a size past 32 bits: " + calls);
ok(__msbAlloc(8) > 0, "a small allocation returns an address");
console.log("ok");
`;

test "js side: the string glue allocates the exact UTF-8 length of a long string and refuses a size past 32 bits" {
	const prelude = bindingsFor(["twice"]).prelude;
	const start = prelude.indexOf("const __msbTe");
	const end = prelude.indexOf("const __msbMod = await");
	assert start >= 0 && end > start;
	const dir = "out/jsSideGlue/";
	assert ensureDir(dir).ok;
	const file = dir + "glueAlloc.cjs";
	assert writeFile(file, GLUE_STUB + prelude.slice(start, end) + GLUE_CHECKS).ok;
	const r = execFileResult("node", [file]);
	if (!r.started) throw new Error("could not start node");
	if (r.exitCode != 0 || r.signal != 0) throw new Error("glue check failed: " + r.errorOutput + r.output);
	assert r.output.trim() == "ok";
}

test "js side: a struct is passed leaf by leaf and its result is built by a taker pushed for the call" {
	const js = bindingsFor(["tag"]).modules[0].code;
	assert js.includes("e0_2 = __msbEncOwned(a0.text);");
	assert js.includes("__msbMod._msb_calc_tag(a0.at.x, a0.at.y, e0_2[0], e0_2[1], a0.count);");
	assert js.includes("\tlet e0_2, sent = false;\n\tconst mark = __msbTop;\n\ttry {\n\t\te0_2 = __msbEncOwned(a0.text);\n\t\tsent = true;\n\t\t__msbMod._msb_calc_tag(a0.at.x, a0.at.y, e0_2[0], e0_2[1], a0.count);\n\t\treturn r;\n\t} finally {\n\t\t__msbTop = mark;\n\t\tif (e0_2 && !sent) __msbMod._free(e0_2[0]);\n\t\t__msb.takes.length = d;\n\t}\n}");
	assert js.includes("const d = __msb.takes.push((x0, x1, x2, x3, x4) => { r = { at: { x: x0, y: x1 }, text: __msbDec(x2, x3), count: x4 }; }) - 1;");
	assert js.includes("__msb.takes.length = d;");
	assert js.includes("return r;");
}

test "js side: a Vec is copied into wasm memory and its result copied out into an array" {
	const js = bindingsFor(["scale"]).modules[0].code;
	assert js.includes("e0 = __msbCopyIn(a0, 0, a0.length, Float32Array);");
	assert js.includes("__msbMod._msb_calc_scale(e0[0], e0[1], a1);");
	assert js.includes("(p, n) => { r = __msbVecOut(p >>> 0, n, Uint16Array, false); }");
	assert js.includes("if (e0) __msbFree(e0[0]);");
	assert js.includes("\tlet e0;\n\tconst mark = __msbTop;\n\ttry {\n\t\te0 = __msbCopyIn(a0, 0, a0.length, Float32Array);\n\t\t__msbMod._msb_calc_scale(e0[0], e0[1], a1);\n\t\treturn r;\n\t} finally {\n\t\t__msbTop = mark;\n\t\tif (e0) __msbFree(e0[0]);\n\t\t__msb.takes.length = d;\n\t}\n}");
	assert bindingsFor(["scale"]).prelude.includes("function __msbVecOut(p, n, T, bool) {");
}

test "js side: a Span is copied in for the call, and a writable one is copied back before the copy is freed" {
	const read = bindingsFor(["total"]).modules[0].code;
	assert read.includes("e0 = __msbCopyIn(a0.base, a0.off, a0.len, Float32Array);");
	assert read.includes("return __msbMod._msb_calc_total(e0[0], e0[1]);");
	assert !read.includes("__msbCopyBack");
	const write = bindingsFor(["fill"]).modules[0].code;
	assert write.includes("\tconst mark = __msbTop;\n\ttry {");
	assert write.includes("\t} finally {\n\t\t__msbTop = mark;\n");
	assert write.includes("__msbFree(e0[0]);");
	assert !write.includes("._free(");
	assert write.includes("\t\ttry {\n\t\t\t__msbMod._msb_calc_fill(e0[0], e0[1], a1);\n\t\t} finally {\n\t\t\t__msbCopyBack(e0[0], a0.base, a0.off, a0.len, Uint8Array, true);\n\t\t}\n\t} finally {\n\t\t__msbTop = mark;\n\t\tif (e0) __msbFree(e0[0]);");
	assert bindingsFor(["fill"]).prelude.includes("function __msbCopyBack(p, a, off, n, T, bool) {");
}

test "js side: a callback that returns a value still copies a writable Span back after the call, also when it throws" {
	const code = bindingsFor(["patch"]).modules[0].code;
	assert code.includes("try { return a0(s0); } finally { __msbCopyTo(x0 >>> 0, s0.base, 0, x1, Int32Array); }");
}

test "js side: the copy-back of a Span runs only once every argument is encoded, so a failed encode writes nothing back" {
	const code = bindingsFor(["stamp"]).modules[0].code;
	assert code.includes("\t\te1 = __msbCopyIn(a1.base, a1.off, a1.len, Int32Array);\n\t\tsent = true;\n\t\ttry {\n\t\t\treturn __msbMod._msb_calc_stamp(e0[0], e0[1], e1[0], e1[1]);\n\t\t} finally {\n\t\t\t__msbCopyBack(e1[0], a1.base, a1.off, a1.len, Int32Array, false);\n\t\t}\n\t} finally {\n\t\t__msbTop = mark;\n\t\tif (e0 && !sent) __msbMod._free(e0[0]);\n\t\tif (e1) __msbFree(e1[0]);");
}

test "js side: a Vec result with a writable Span copies back inside the call's finally and restores the takers after it" {
	const code = bindingsFor(["cut"]).modules[0].code;
	assert code.includes("\t\t\t__msbMod._msb_calc_cut(e0[0], e0[1]);\n\t\t\treturn r;\n\t\t} finally {\n\t\t\t__msbCopyBack(e0[0], a0.base, a0.off, a0.len, Int32Array, false);\n\t\t}\n\t} finally {\n\t\t__msbTop = mark;\n\t\tif (e0) __msbFree(e0[0]);\n\t\t__msb.takes.length = d;");
}

test "js side: each writable Span has its own copy-back, so one that throws cannot skip the next, and the frees still run last" {
	const code = bindingsFor(["swap"]).modules[0].code;
	assert code.includes("\t\ttry {\n\t\t\ttry {\n\t\t\t\t__msbMod._msb_calc_swap(e0[0], e0[1], e1[0], e1[1]);\n\t\t\t} finally {\n\t\t\t\t__msbCopyBack(e1[0], a1.base, a1.off, a1.len, Int32Array, false);\n\t\t\t}\n\t\t} finally {\n\t\t\t__msbCopyBack(e0[0], a0.base, a0.off, a0.len, Int32Array, false);\n\t\t}\n\t} finally {\n\t\t__msbTop = mark;\n\t\tif (e0) __msbFree(e0[0]);\n\t\tif (e1) __msbFree(e1[0]);");
}

function glueBody(prelude: string, name: string): string {
	const from = prelude.indexOf("function " + name + "(");
	if (from < 0) throw new Error("internal: prelude lacks " + name);
	const to = prelude.indexOf("\n}\n", from);
	if (to < 0) throw new Error("internal: " + name + " has no closing brace at column zero");
	return prelude.slice(from, to);
}

test "js side: copying a Span back into its array or out to wasm memory throws when the array no longer holds it" {
	const p = bindingsFor(["fill"]).prelude;
	assert p.includes("function __msbInRange(a, off, n) {\n\tif (!(off >= 0 && (n === 0 || n >= 0 && off + n <= a.length))) throw new RangeError(");
	assert glueBody(p, "__msbCopyBack").startsWith("function __msbCopyBack(p, a, off, n, T, bool) {\n\t__msbInRange(a, off, n);\n");
	assert glueBody(p, "__msbCopyTo").startsWith("function __msbCopyTo(p, a, off, n, T) {\n\t__msbInRange(a, off, n);\n");
	assert !glueBody(p, "__msbVecOut").includes("__msbInRange");
}

test "js side: a Span is range-checked before its copy is allocated, so a throw leaves no wasm memory to free" {
	const body = glueBody(bindingsFor(["fill"]).prelude, "__msbCopyIn");
	assert body.startsWith("function __msbCopyIn(a, off, n, T) {\n\t__msbInRange(a, off, n);\n");
	assert body.indexOf("__msbInRange(") < body.indexOf("__msbAlloc(");
}

test "js side: the registry poisons itself on the first exception that crossed the wasm frames and every later wrapper call refuses" {
	const p = bindingsFor(["add64"]).prelude;
	assert p.includes("\tlet dead = false;\n\tlet cause;\n");
	assert p.includes("\t\tenter() { if (dead) throw new Error(\"the wasm half cannot run again: a JS exception crossed its frames\", { cause }); },\n");
	assert p.includes("\t\tdie(e) { if (!dead) { dead = true; cause = e; } return e; },\n");
}

test "js side: every wrapper enters before it pushes, encodes or allocates anything" {
	const code = bindingsFor(["add64", "twice", "tag", "visit", "scale", "total"]).modules[0].code;
	assert code.split("\t__msb.enter();\n").length == 7;
	assert code.includes("function bundled_visit(a0, a1) {\n\t__msb.enter();\n\tconst id1 = __msb.push(");
	assert code.includes("function bundled_tag(a0) {\n\t__msb.enter();\n\tlet r;\n");
	assert code.includes("function bundled_scale(a0, a1) {\n\t__msb.enter();\n\tlet r;\n");
	assert code.includes("function bundled_total(a0) {\n\t__msb.enter();\n\tlet e0;\n");
}

function checkGlueBody(prelude: string, name: string): string {
	const from = prelude.indexOf("function " + name + "(");
	if (from < 0) throw new Error("internal: prelude lacks " + name);
	const to = prelude.indexOf("\n}\n", from);
	if (to < 0) throw new Error("internal: " + name + " has no closing brace at column zero");
	return prelude.slice(from, to);
}

test "js side: a build without argument checks emits no check and no check glue" {
	const b = bindingsFor(["add64", "tag", "scale", "total", "evaluate"]);
	for (const name of ["__msbInt", "__msbType", "__msbList", "__msbSpan", "__msbElems", "__msbBad"]) {
		assert !b.modules[0].code.includes(name + "(");
		assert !b.prelude.includes("function " + name + "(");
	}
}

test "js side: a checked build carries the check glue once" {
	const p = bindingsFor(["add64"], true).prelude;
	for (const name of ["__msbBad", "__msbType", "__msbInt", "__msbList", "__msbSpan", "__msbElems"]) {
		assert p.includes("function " + name + "(");
		assert p.indexOf("function " + name + "(") == p.lastIndexOf("function " + name + "(");
	}
}

test "js side: a checked scalar parameter is tested for its JS type and range before the call" {
	const code = bindingsFor(["add64", "isEven", "flip", "wide"], true).modules[0].code;
	assert code.includes("function bundled_add64(a0, a1) {\n\t__msbInt(a0, \"bigint\", -9223372036854775808n, 9223372036854775807n, \"int64\", \"add64\", \"parameter 'a'\");\n\t__msbInt(a1, \"bigint\", -9223372036854775808n, 9223372036854775807n, \"int64\", \"add64\", \"parameter 'b'\");\n\t__msb.enter();
	return __msbMod._msb_calc_add64(a0, a1);\n}");
	assert code.includes("\t__msbInt(a0, \"number\", 0, 255, \"uint8\", \"isEven\", \"parameter 'x'\");\n");
	assert code.includes("\t__msbType(a0, \"boolean\", \"boolean\", \"flip\", \"parameter 'b'\");\n\t__msb.enter();
	return __msbMod._msb_calc_flip((a0 ? 1 : 0)) !== 0;");
	assert code.includes("\t__msbInt(a0, \"number\", 0, 4294967295, \"uint32\", \"wide\", \"parameter 'x'\");\n");
}

test "js side: a checked string parameter is tested before anything is allocated" {
	const code = bindingsFor(["twice"], true).modules[0].code;
	assert code.includes("function bundled_twice(a0) {\n\t__msbType(a0, \"string\", \"string\", \"twice\", \"parameter 's'\");\n\t__msb.enter();
	let r;
	const d = __msb.takes.push((p, n) => { r = __msbDec(p >>> 0, n); }) - 1;
	let e0, sent = false;
	const mark = __msbTop;
	try {");
}

test "js side: a checked struct is tested object by object, then field by field, in leaf order, before its taker is pushed" {
	const code = bindingsFor(["tag"], true).modules[0].code;
	assert code.includes("\t__msbType(a0, \"object\", \"object\", \"tag\", \"parameter 'l'\");\n\t__msbType(a0.at, \"object\", \"object\", \"tag\", \"parameter 'l' field 'at'\");\n");
	assert code.includes("\t__msbType(a0.at.x, \"number\", \"float64\", \"tag\", \"parameter 'l' field 'at.x'\");\n\t__msbType(a0.at.y, \"number\", \"float64\", \"tag\", \"parameter 'l' field 'at.y'\");\n\t__msbType(a0.text, \"string\", \"string\", \"tag\", \"parameter 'l' field 'text'\");\n\t__msbInt(a0.count, \"number\", -2147483648, 2147483647, \"int32\", \"tag\", \"parameter 'l' field 'count'\");\n");
	assert code.indexOf("__msbType(a0.at, ") == code.lastIndexOf("__msbType(a0.at, ");
	assert code.indexOf("__msbInt(a0.count") < code.indexOf("__msb.takes.push(");
	assert code.indexOf("__msbInt(a0.count") < code.indexOf("try {");
}

test "js side: a checked Vec or Span is tested as a list, then element by element over the window the call copies" {
	const vec = bindingsFor(["scale"], true).modules[0].code;
	assert vec.includes("\t__msbElems(__msbList(a0, \"Vec<float32>\", \"scale\", \"parameter 'xs'\"), 0, a0.length, \"number\", null, null, \"float32\", \"scale\", \"parameter 'xs'\");\n\t__msbType(a1, \"number\", \"float32\", \"scale\", \"parameter 'k'\");\n");
	const span = bindingsFor(["total", "fill"], true).modules[0].code;
	assert span.includes("\t__msbElems(__msbSpan(a0, \"Span<float32>\", \"total\", \"parameter 'xs'\").base, a0.off, a0.len, \"number\", null, null, \"float32\", \"total\", \"parameter 'xs'\");\n");
	assert span.includes("\t__msbElems(__msbSpan(a0, \"Span<boolean>\", \"fill\", \"parameter 'xs'\").base, a0.off, a0.len, \"boolean\", null, null, \"boolean\", \"fill\", \"parameter 'xs'\");\n");
}

test "js side: a checked Span is tested for its shape only, so an empty one past the end of its array passes and the range stays with the copy" {
	const p = bindingsFor(["total"], true).prelude;
	const span = checkGlueBody(p, "__msbSpan");
	assert span.includes("!Number.isInteger(v.off) || !Number.isInteger(v.len)");
	assert !span.includes("base.length");
	assert checkGlueBody(p, "__msbElems").startsWith("function __msbElems(v, off, n, k, lo, hi, t, f, p) {\n\tif (k === \"boolean\" && ArrayBuffer.isView(v)) return v;\n\tconst end = Math.min(off + n, v.length);\n\tfor (let i = Math.max(off, 0); i < end; i++) {\n");
}

test "js side: a checked callback is tested before it is pushed and its result is tested on its way into wasm" {
	const code = bindingsFor(["evaluate", "visit", "pick", "sumBy"], true).modules[0].code;
	const guard = "\t__msbType(a1, \"function\", \"function\", \"evaluate\", \"parameter 'cb'\");\n";
	assert code.includes(guard);
	assert code.indexOf(guard) < code.indexOf("const id1 = __msb.push((x0) =>");
	assert code.includes("const id1 = __msb.push((x0) => __msbInt(a1(x0), \"number\", -2147483648, 2147483647, \"int32\", \"evaluate\", \"result of callback 'cb'\"));");
	assert !bindingsFor(["evaluate"], true).modules[0].code.includes("__msb.push(a");
	assert code.includes("const id1 = __msb.push(a1);");
	assert code.includes("const id0 = __msb.push((x0, x1) => (__msbType(a0(x0 !== 0, x1 >>> 0), \"boolean\", \"boolean\", \"pick\", \"result of callback 'f'\") ? 1 : 0));");
	assert code.includes("return __msbType(a1(s0), \"number\", \"float32\", \"sumBy\", \"result of callback 'cb'\"); }");
}

test "js side: copying into wasm memory uses TypedArray.set for a typed source, and copying back uses it for a typed non-bool target" {
	const p = bindingsFor(["total"]).prelude;
	assert p.includes("if (ArrayBuffer.isView(a)) v.set(a.subarray(off, off + n));");
	assert p.includes("if (!bool && n !== 0 && ArrayBuffer.isView(a)) a.set(v, off);");
}

test "js side: each overload gets its own wrapper named for its symbol and calls its own export" {
	const code = bindingsWith(["bump"], (f) => "bundled_bump_" + f.overloadIndex).modules[0].code;
	assert code.includes("bundled_bump_0") && code.includes("bundled_bump_1");
	assert code.includes("_msb_calc_bump_u0") && code.includes("_msb_calc_bump_u1");
}

test "js side: a nullable scalar parameter is a presence flag and a value, 0 or 0n when absent, and an omitted one counts as null" {
	const code = nullableBindings(["orMinus", "sumBig"]).modules[0].code;
	assert code.includes("function bundled_orMinus(a0) {\n\t__msb.enter();\n\treturn __msbMod._msb_calc_orMinus(a0 == null ? 0 : 1, a0 == null ? 0 : a0);\n}");
	assert code.includes("return __msbMod._msb_calc_sumBig(a0 == null ? 0 : 1, a0 == null ? 0n : a0, a1 == null ? 0 : 1, a1 == null ? 0n : a1);");
}

test "js side: a nullable scalar result is read after the call, gated by the presence flag, and absent is null" {
	const code = nullableBindings(["halve", "parity", "echoU32"]).modules[0].code;
	assert code.includes("function bundled_halve(a0) {\n\t__msb.enter();\n\tconst v = __msbMod._msb_calc_halve(a0);\n\treturn __msbMod._msb_ret_some() !== 0 ? v : null;\n}");
	assert code.includes("return __msbMod._msb_ret_some() !== 0 ? v !== 0 : null;");
	assert code.includes("function bundled_echoU32(a0) {\n\t__msb.enter();\n\tconst v = __msbMod._msb_calc_echoU32(a0 == null ? 0 : 1, a0 == null ? 0 : a0);\n\treturn __msbMod._msb_ret_some() !== 0 ? v >>> 0 : null;\n}");
}

test "js side: a nullable string is encoded only when present, and an absent string result stays null because the result take never runs" {
	const code = nullableBindings(["greet"]).modules[0].code;
	assert code.includes("e0 = a0 == null ? null : __msbEncOwned(a0);");
	assert code.includes("\tlet r = null;\n\tconst d = __msb.takes.push((p, n) => { r = __msbDec(p >>> 0, n); }) - 1;");
	assert code.includes("__msbMod._msb_calc_greet(a0 == null ? 0 : 1, e0 ? e0[0] : 0, e0 ? e0[1] : 0);\n\t\treturn r;");
	assert code.includes("\t\tif (e0 && !sent) __msbMod._free(e0[0]);\n\t\t__msb.takes.length = d;");
	assert !code.includes("_msb_ret_some");
	assert !code.includes("_msb_ret_len");
}

test "js side: a nullable Vec is copied in only when present, and a nullable Vec result starts as null" {
	const code = nullableBindings(["headOr", "upTo"]).modules[0].code;
	assert code.includes("e0 = a0 == null ? null : __msbCopyIn(a0, 0, a0.length, Int32Array);");
	assert code.includes("__msbMod._msb_calc_headOr(a0 == null ? 0 : 1, e0 ? e0[0] : 0, e0 ? e0[1] : 0);");
	assert code.includes("function bundled_upTo(a0) {\n\t__msb.enter();\n\tlet r = null;\n\tconst d = __msb.takes.push((p, n) => { r = __msbVecOut(p >>> 0, n, Float32Array, false); }) - 1;");
	assert code.includes("\t\t__msbMod._msb_calc_upTo(a0);\n\t\treturn r;");
	assert !code.includes("_msb_ret_some");
}

test "js side: a nullable struct and its nullable fields each carry a flag in leaf order, and its taker builds null fields" {
	const code = nullableBindings(["bump"]).modules[0].code;
	assert code.includes("e0_1 = a0 == null || a0.note == null ? null : __msbEncOwned(a0.note);");
	assert code.includes("__msbMod._msb_calc_bump(a0 == null ? 0 : 1, a0 == null ? 0 : a0.id, a0 == null || a0.note == null ? 0 : 1, e0_1 ? e0_1[0] : 0, e0_1 ? e0_1[1] : 0, a0 == null || a0.score == null ? 0 : 1, a0 == null || a0.score == null ? 0 : a0.score, a0 == null || a0.ok == null ? 0 : 1, a0 == null || a0.ok == null ? 0 : (a0.ok ? 1 : 0), a0 == null ? 0 : a0.at.x, a0 == null || a0.at.y == null ? 0 : 1, a0 == null || a0.at.y == null ? 0 : a0.at.y);");
	assert code.includes("(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10) => { r = { id: x0, note: x1 !== 0 ? __msbDec(x2, x3) : null, score: x4 !== 0 ? x5 : null, ok: x6 !== 0 ? x7 !== 0 : null, at: { x: x8, y: x9 !== 0 ? x10 : null } }; }");
	assert code.includes("\tlet r = null;");
	assert !code.includes("_msb_ret_some");
}

test "js side: a nullable callback parameter arrives as a flag and a value, is passed as null when the flag is 0, and keeps its adapter" {
	const code = nullableBindings(["replay", "replayBig"]).modules[0].code;
	assert code.includes("const id0 = __msb.push((x0, x1, x2, x3, x4) => { a0(x0 !== 0 ? x1 : null, x2 !== 0 ? __msbDec(x3, x4) : null); });");
	assert code.includes("const id0 = __msb.push((x0, x1, x2, x3) => { a0(x0 !== 0 ? x1 !== 0 : null, x2 !== 0 ? x3 : null); });");
	assert !code.includes("__msb.push(a0)");
}
