import { ExtensionRegistry, buildExportInfo, ExportedSymInfo, CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "../../test/handoff/helpers";
import { BoundaryCallback, BoundaryKind, BoundaryMode, Manifest, manifestFor } from "./manifest";
import { jsBindings } from "./jsSide";

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
	assert code.includes("function bundled_add64(a0, a1) {\n\treturn __msbMod._msb_calc_add64(a0, a1);\n}");
	assert code.includes("return BigInt.asUintN(64, __msbMod._msb_calc_mul64u(a0, a1));");
	assert code.includes("return __msbMod._msb_calc_isEven(a0) !== 0;");
	assert code.includes("return __msbMod._msb_calc_flip((a0 ? 1 : 0)) !== 0;");
	assert code.includes("return __msbMod._msb_calc_wide(a0) >>> 0;");
}

test "js side: a callback is pushed before the call, adapted per kind and popped in finally" {
	const code = bindingsFor(["evaluate", "visit", "pick"]).modules[0].code;
	assert code.includes("function bundled_evaluate(a0, a1) {\n\tconst id1 = __msb.push((x0) => a1(x0));\n\ttry {\n\t\treturn __msbMod._msb_calc_evaluate(a0, id1);\n\t} finally {\n\t\t__msb.pop(id1);\n\t}\n}");
	assert code.includes("const id1 = __msb.push((x0, x1) => { a1(x0, x1); });");
	assert code.includes("const id0 = __msb.push((x0, x1) => (a0(x0 !== 0, x1 >>> 0) ? 1 : 0));");
}

test "js side: one prelude awaits the wasm module once and a stale callback id throws" {
	const b = bindingsFor(["add64"]);
	assert b.modules.length == 1;
	assert b.modules[0].modulePath == "/p/calc.ms";
	assert b.prelude.includes('const __msbMod = await (await import("./app.wasm.mjs")).default();\n__msbMod._MsMain();\n');
	assert b.prelude.includes("globalThis.__msb = __msb;");
	assert b.prelude.includes('throw new Error("callback used after its call returned");');
	assert b.prelude.indexOf("globalThis.__msb") < b.prelude.indexOf("_MsMain");
}

test "js side: a string parameter is encoded, passed as pointer and length, and freed in finally" {
	const code = bindingsFor(["both"]).modules[0].code;
	assert code.includes("function bundled_both(a0, a1, a2) {\n\tlet e0, e2;\n\ttry {\n\t\te0 = __msbEnc(a0);\n\t\te2 = __msbEnc(a2);\n\t\treturn __msbMod._msb_calc_both(e0[0], e0[1], a1, e2[0], e2[1]);\n\t} finally {\n\t\tif (e0) __msbMod._free(e0[0]);\n\t\tif (e2) __msbMod._free(e2[0]);\n\t}\n}");
}

test "js side: a string result is decoded with the length read right after the call" {
	const code = bindingsFor(["twice"]).modules[0].code;
	assert code.includes("function bundled_twice(a0) {\n\tlet e0;\n\ttry {\n\t\te0 = __msbEnc(a0);\n\t\treturn __msbDec(__msbMod._msb_calc_twice(e0[0], e0[1]), __msbMod._msb_ret_len());\n\t} finally {\n\t\tif (e0) __msbMod._free(e0[0]);\n\t}\n}");
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

test "js side: a callback Span parameter arrives as a copied view, a writable one is copied back after the call" {
	const code = bindingsFor(["sumBy", "edit"]).modules[0].code;
	assert code.includes("const id1 = __msb.push((x0, x1) => { const s0 = { base: __msbVecOut(x0 >>> 0, x1, Float32Array, false), off: 0, len: x1 }; const r = a1(s0); return r; });");
	assert code.includes("const id0 = __msb.push((x0, x1, x2) => { const s0 = { base: __msbVecOut(x0 >>> 0, x1, Uint8Array, true), off: 0, len: x1 }; a0(s0, x2); __msbCopyTo(x0 >>> 0, s0.base, 0, x1, Uint8Array); });");
}

test "js side: the prelude carries the string glue once and reads the heap fresh" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.indexOf("function __msbEnc(s)") == p.lastIndexOf("function __msbEnc(s)");
	assert p.includes("function __msbDec(p, len)");
	assert p.includes("__msbMod.HEAPU8");
	assert !p.includes("wasmMemory");
}

test "js side: a failed wasm allocation throws instead of writing at address 0" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.includes("if (p === 0) throw new RangeError(");
	assert !p.includes("const p = __msbMod._malloc(n || 1);") && !p.includes("const p = __msbMod._malloc(n * 3);");
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
	assert write.includes("\t\tif (e0) __msbCopyBack(e0[0], a0.base, a0.off, a0.len, Uint8Array, true);\n\t\tif (e0) __msbMod._free(e0[0]);");
	assert bindingsFor(["fill"]).prelude.includes("function __msbCopyBack(p, a, off, n, T, bool) {");
}
