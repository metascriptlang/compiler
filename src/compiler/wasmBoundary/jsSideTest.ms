import { ExtensionRegistry, buildExportInfo, ExportedSymInfo, CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "../../test/handoff/helpers";
import { BoundaryCallback, BoundaryKind, BoundaryMode, Manifest, manifestFor } from "./manifest";
import { jsBindings } from "./jsSide";
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
export function both(a: string, n: int32, b: string): int32 { return a.length + n + b.length; }
export function sumBy(n: int32, cb: (xs: Readonly<Span<float32>>) => float32): float32 { return 0; }
export function edit(cb: (xs: Span<boolean>, at: int32) => void): void {}
export function patch(cb: (xs: Span<int32>) => int32): int32 { return 0; }
export function stamp(s: string, xs: Span<int32>): int32 { return 0; }
export function cut(xs: Span<int32>): Vec<int32> { const out: Vec<int32> = []; return out; }
export function swap(a: Span<int32>, b: Span<int32>): void {}
`;

function bindingsFor(names: string[]) {
	const ctx = checkSource(SOURCE);
	if (ctx == null) throw new Error("internal: test source did not check");
	const exps: ExportedSymInfo[] = [];
	for (const n of names) {
		const sym = lookupSymbol(ctx.table, n);
		if (sym == null) throw new Error("internal: test source lacks " + n);
		exps.push(buildExportInfo(sym!, null as unknown as ExtensionRegistry, "/p/calc.ms", null as unknown as CheckerContext));
	}
	const m = manifestFor("/p/calc.ms", "/p/app.ms", exps, names);
	if (m.errors.length > 0) throw new Error("internal: " + m.errors.join("; "));
	return jsBindings(m, "./app.wasm.mjs", (f) => "bundled_" + f.name);
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
	assert code.includes("function bundled_evaluate(a0, a1) {\n\t__msb.enter();\n\tconst id1 = __msb.push((x0) => a1(x0));\n\ttry {\n\t\treturn __msbMod._msb_calc_evaluate(a0, id1);\n\t} finally {\n\t\t__msb.pop(id1);\n\t}\n}");
	assert code.includes("const id1 = __msb.push((x0, x1) => { a1(x0, x1); });");
	assert code.includes("const id0 = __msb.push((x0, x1) => (a0(x0 !== 0, x1 >>> 0) ? 1 : 0));");
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

test "js side: a string parameter is encoded, passed as pointer and length, and freed in finally" {
	const code = bindingsFor(["both"]).modules[0].code;
	assert code.includes("function bundled_both(a0, a1, a2) {\n\t__msb.enter();\n\tlet e0, e2;\n\ttry {\n\t\te0 = __msbEnc(a0);\n\t\te2 = __msbEnc(a2);\n\t\treturn __msbMod._msb_calc_both(e0[0], e0[1], a1, e2[0], e2[1]);\n\t} finally {\n\t\tif (e0) __msbMod._free(e0[0]);\n\t\tif (e2) __msbMod._free(e2[0]);\n\t}\n}");
}

test "js side: a string result is decoded with the length read right after the call" {
	const code = bindingsFor(["twice"]).modules[0].code;
	assert code.includes("function bundled_twice(a0) {\n\t__msb.enter();\n\tlet e0;\n\ttry {\n\t\te0 = __msbEnc(a0);\n\t\treturn __msbDec(__msbMod._msb_calc_twice(e0[0], e0[1]), __msbMod._msb_ret_len());\n\t} finally {\n\t\tif (e0) __msbMod._free(e0[0]);\n\t}\n}");
}

test "js side: a callback string parameter arrives as pointer and length and is decoded" {
	const cb: BoundaryCallback = { params: [BoundaryKind.String, BoundaryKind.I32], elements: [BoundaryKind.Void, BoundaryKind.Void], modes: [BoundaryMode.Copied, BoundaryMode.Copied], result: BoundaryKind.I32, signature: "i_si" };
	const m: Manifest = {
		functions: [{
			modulePath: "/p/calc.ms", moduleKey: "calc", name: "note", exportSymbol: "msb_calc_note",
			params: [{ name: "cb", kind: BoundaryKind.Callback, mode: BoundaryMode.Borrowed, callback: cb, leaves: [], element: BoundaryKind.Void }],
			result: BoundaryKind.Void, resultLeaves: [], resultElement: BoundaryKind.Void,
		}],
		errors: [],
	};
	const code = jsBindings(m, "./app.wasm.mjs", (f) => "bundled_" + f.name).modules[0].code;
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

test "js side: a failed wasm allocation throws instead of writing at address 0" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.includes("if (p === 0) throw new RangeError(");
	assert !p.includes("const p = __msbMod._malloc(n || 1);") && !p.includes("const p = __msbMod._malloc(n * 3);");
}

const GLUE_STUB = `const calls = [];
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
	assert js.includes("e0_2 = __msbEnc(a0.text);");
	assert js.includes("__msbMod._msb_calc_tag(a0.at.x, a0.at.y, e0_2[0], e0_2[1], a0.count);");
	assert js.includes("const d = __msb.takes.push((x0, x1, x2, x3, x4) => { r = { at: { x: x0, y: x1 }, text: __msbDec(x2, x3), count: x4 }; }) - 1;");
	assert js.includes("__msb.takes.length = d;");
	assert js.includes("return r;");
}

test "js side: a Vec is copied into wasm memory and its result copied out into an array" {
	const js = bindingsFor(["scale"]).modules[0].code;
	assert js.includes("e0 = __msbCopyIn(a0, 0, a0.length, Float32Array);");
	assert js.includes("__msbMod._msb_calc_scale(e0[0], e0[1], a1);");
	assert js.includes("(p, n) => { r = __msbVecOut(p >>> 0, n, Uint16Array, false); }");
	assert js.includes("if (e0) __msbMod._free(e0[0]);");
	assert bindingsFor(["scale"]).prelude.includes("function __msbVecOut(p, n, T, bool) {");
}

test "js side: a Span is copied in for the call, and a writable one is copied back before the copy is freed" {
	const read = bindingsFor(["total"]).modules[0].code;
	assert read.includes("e0 = __msbCopyIn(a0.base, a0.off, a0.len, Float32Array);");
	assert read.includes("return __msbMod._msb_calc_total(e0[0], e0[1]);");
	assert !read.includes("__msbCopyBack");
	const write = bindingsFor(["fill"]).modules[0].code;
	assert write.includes("\t\ttry {\n\t\t\t__msbMod._msb_calc_fill(e0[0], e0[1], a1);\n\t\t} finally {\n\t\t\t__msbCopyBack(e0[0], a0.base, a0.off, a0.len, Uint8Array, true);\n\t\t}\n\t} finally {\n\t\tif (e0) __msbMod._free(e0[0]);");
	assert bindingsFor(["fill"]).prelude.includes("function __msbCopyBack(p, a, off, n, T, bool) {");
}

test "js side: a callback that returns a value still copies a writable Span back after the call, also when it throws" {
	const code = bindingsFor(["patch"]).modules[0].code;
	assert code.includes("try { return a0(s0); } finally { __msbCopyTo(x0 >>> 0, s0.base, 0, x1, Int32Array); }");
}

test "js side: the copy-back of a Span runs only once every argument is encoded, so a failed encode writes nothing back" {
	const code = bindingsFor(["stamp"]).modules[0].code;
	assert code.includes("\t\te1 = __msbCopyIn(a1.base, a1.off, a1.len, Int32Array);\n\t\ttry {\n\t\t\treturn __msbMod._msb_calc_stamp(e0[0], e0[1], e1[0], e1[1]);\n\t\t} finally {\n\t\t\t__msbCopyBack(e1[0], a1.base, a1.off, a1.len, Int32Array, false);\n\t\t}\n\t} finally {\n\t\tif (e0) __msbMod._free(e0[0]);");
}

test "js side: a Vec result with a writable Span copies back inside the call's finally and restores the takers after it" {
	const code = bindingsFor(["cut"]).modules[0].code;
	assert code.includes("\t\t\t__msbMod._msb_calc_cut(e0[0], e0[1]);\n\t\t\treturn r;\n\t\t} finally {\n\t\t\t__msbCopyBack(e0[0], a0.base, a0.off, a0.len, Int32Array, false);\n\t\t}\n\t} finally {\n\t\tif (e0) __msbMod._free(e0[0]);\n\t\t__msb.takes.length = d;");
}

test "js side: each writable Span has its own copy-back, so one that throws cannot skip the next, and the frees still run last" {
	const code = bindingsFor(["swap"]).modules[0].code;
	assert code.includes("\t\ttry {\n\t\t\ttry {\n\t\t\t\t__msbMod._msb_calc_swap(e0[0], e0[1], e1[0], e1[1]);\n\t\t\t} finally {\n\t\t\t\t__msbCopyBack(e1[0], a1.base, a1.off, a1.len, Int32Array, false);\n\t\t\t}\n\t\t} finally {\n\t\t\t__msbCopyBack(e0[0], a0.base, a0.off, a0.len, Int32Array, false);\n\t\t}\n\t} finally {\n\t\tif (e0) __msbMod._free(e0[0]);\n\t\tif (e1) __msbMod._free(e1[0]);");
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
	assert p.includes("function __msbInRange(a, off, n) {\n\tif (!(off >= 0 && n >= 0 && off + n <= a.length)) throw new RangeError(");
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
