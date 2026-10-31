import { ExtensionRegistry, buildExportInfo, ExportedSymInfo, CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "../../test/handoff/helpers";
import { Manifest, manifestFor } from "./manifest";
import { jsBindings } from "./jsSide";
import { wasmEntrySource } from "./wasmSide";

const SOURCE = `
struct Point { x: float64; y: float64; }
struct Label { at: Point; text: string; count: int32; }
export function tag(l: Label): Label { return l; }
export function scale(xs: Vec<float32>, k: float32): Vec<uint16> { const out: Vec<uint16> = []; return out; }
export function total(xs: Readonly<Span<float32>>): float32 { return 0; }
export function fill(xs: Span<boolean>, at: int32): void {}
export function add64(a: int64, b: int64): int64 { return a + b; }
export function evaluate(value: int32, cb: (x: int32) => int32): int32 { return cb(value) + 1; }
export function tick(cb: () => int32): int32 { return cb() + 1; }
export function isEven(x: uint8): boolean { return x % 2 == 0; }
export function visit(n: int32, cb: (x: int32, y: float64) => void): void { cb(n, 1.5); }
export function twice(s: string): string { return s + s; }
export function banner(): string { return "banner"; }
export function report(cb: (s: string) => int32): int32 { return cb("x"); }
export function sumBy(cb: (xs: Readonly<Span<float32>>) => float32): float32 { return 0; }
export function edit(cb: (xs: Span<int32>, at: int32) => void): void {}
export function label(n: int32): string { return ""; }
export function make(n: int32): Label { return { at: { x: 0, y: 0 }, text: "", count: n }; }
export function bytes(s: string): int32 { return s.length; }
export function ramp(n: int32): Vec<int32> { const out: Vec<int32> = []; return out; }
`;

function manifestOf(names: string[]): Manifest {
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
	return m;
}

function entryFor(names: string[]) {
	return wasmEntrySource(manifestOf(names).functions, (p: string) => "./calc");
}

test "wasm entry: one exportName wrapper per function and one import per callback signature" {
	const e = entryFor(["add64", "evaluate", "isEven", "visit"]);
	const s = e.source;
	assert s.includes('import { add64 as msbm0_add64, evaluate as msbm0_evaluate, isEven as msbm0_isEven, visit as msbm0_visit } from "./calc";');
	assert s.includes('@exportName("msb_calc_add64")\nexport function msb_calc_add64(a: int64, b: int64): int64 {\n\treturn msbm0_add64(a, b);');
	assert s.includes("export function msb_calc_evaluate(value: int32, cb: int32): int32 {");
	assert s.includes("msbm0_evaluate(value, (a0: int32): int32 => msb_cb_i_i(cb, a0))");
	assert s.includes("export function msb_calc_isEven(x: uint8): boolean {");
	assert s.includes("(a0: int32, a1: float64): void => { msb_cb_v_id(cb, a0, a1); }");
	assert s.includes('extern function msb_cb_i_i(id: int32, a0: int32): int32 from "msb_cb_i_i";');
	assert s.includes('int32_t msb_cb_i_i(int32_t id, int32_t a0);');
	assert s.includes('import_name(\\"msb_cb_v_id\\")');
}

test "wasm entry: a shared callback signature is declared once; exports and library follow the functions" {
	const e = entryFor(["evaluate", "add64"]);
	assert e.source.split("extern function msb_cb_i_i").length == 2;
	assert e.exportedFunctions.join(",") == "_msb_calc_evaluate,_msb_calc_add64,_MsMain";
	assert e.jsLibrary == "addToLibrary({\n\tmsb_cb_i_i: (id, a0) => { try { return Module['msb'].cb(id)(a0); } catch (e) { throw Module['msb'].die(e); } },\n\tmsb_cb_i_i__postset: \"if (!Module['msb']) throw new Error('msb registry missing: pass { msb } to the wasm module factory');\",\n});\n";
	assert entryFor(["add64"]).jsLibrary == "";
}

test "wasm entry: a string parameter arrives as ptr and len and is adopted without a copy, a result is handed over by msb_rs_s while it is alive" {
	const e = entryFor(["twice"]);
	const s = e.source;
	assert s.includes("function msbStrFrom(ptr: uint32, len: int32): string {\n\treturn msStringNew(ptr as uint64 as Ptr<uint8> as cstring, len as int64);\n}");
	assert s.includes("extern function msStringAdoptMalloced(block: uint64, length: int64): string;");
	assert s.includes("function msbStrAdopt(ptr: uint32, len: int32): string {\n\treturn msStringAdoptMalloced(ptr as uint64, len as int64);\n}");
	assert s.includes('@exportName("msb_calc_twice")\nexport function msb_calc_twice(sPtr: uint32, sLen: int32): void {\n\tconst r = msbm0_twice(msbStrAdopt(sPtr, sLen));\n\tmsb_rs_s(msbStrPtr(r), r.asBytes().length);\n}');
	assert s.includes('extern function msb_rs_s(a0p: uint32, a0l: int32): void from "msb_rs_s";');
	assert s.includes("void msb_rs_s(uint32_t a0p, int32_t a0l);");
	assert s.includes("msbRet") == false && s.includes("msb_ret_len") == false;
	assert e.jsLibrary.includes("\tmsb_rs_s: (...a) => { try { return Module['msb'].takes.pop()(...a); } catch (e) { throw Module['msb'].die(e); } },");
	assert e.exportedFunctions.join(",") == "_msb_calc_twice,_malloc,_free,_MsMain";
	assert e.runtimeMethods.join(",") == "HEAPU8";
	const plain = entryFor(["add64"]);
	assert plain.source.includes("msStringNew") == false;
	assert plain.source.includes("msStringAdoptMalloced") == false;
	assert plain.runtimeMethods.length == 0;
}

test "wasm entry: string results, with or without a parameter, and a struct string leaf each get one result import" {
	const e = entryFor(["twice", "banner", "tag"]);
	assert e.source.includes('@exportName("msb_calc_banner")\nexport function msb_calc_banner(): void {\n\tconst r = msbm0_banner();\n\tmsb_rs_s(msbStrPtr(r), r.asBytes().length);\n}');
	assert e.source.split("extern function msb_rs_s(").length == 2;
	assert e.source.split("extern function msb_rs_ddsi(").length == 2;
	assert e.jsLibrary.split("\n\tmsb_rs_s: ").length == 2 && e.jsLibrary.split("\n\tmsb_rs_ddsi: ").length == 2;
	assert e.exportedFunctions.join(",") == "_msb_calc_twice,_msb_calc_banner,_msb_calc_tag,_malloc,_free,_MsMain";
}

test "wasm entry: a callback string parameter passes ptr and len of a value alive for the call" {
	const e = entryFor(["report"]);
	const s = e.source;
	assert s.includes("msbm0_report((a0: string): int32 => msb_cb_i_s(cb, msbStrPtr(a0), a0.asBytes().length))");
	assert s.includes('extern function msb_cb_i_s(id: int32, a0p: uint32, a0l: int32): int32 from "msb_cb_i_s";');
	assert s.includes("int32_t msb_cb_i_s(int32_t id, uint32_t a0p, int32_t a0l);");
	assert s.includes("msbRet") == false;
	assert e.exportedFunctions.join(",") == "_msb_calc_report,_MsMain";
	assert e.runtimeMethods.join(",") == "HEAPU8";
}

test "wasm entry: a callback Span parameter passes ptr and len of the view, 0 for an empty one" {
	const e = entryFor(["sumBy", "edit"]);
	const s = e.source;
	assert s.includes("msbm0_sumBy((a0: Readonly<Span<float32>>): float32 => msb_cb_f_p(cb, (a0.length == 0 ? 0 : a0 as Readonly<Ptr<float32>> as uint64 as uint32), a0.length as int32))");
	assert s.includes("msbm0_edit((a0: Span<int32>, a1: int32): void => { msb_cb_v_pi(cb, (a0.length == 0 ? 0 : a0 as Ptr<int32> as uint64 as uint32), a0.length as int32, a1); })");
	assert s.includes('extern function msb_cb_v_pi(id: int32, a0p: uint32, a0l: int32, a1: int32): void from "msb_cb_v_pi";');
	assert e.exportedFunctions.join(",") == "_msb_calc_sumBy,_msb_calc_edit,_MsMain";
	assert e.runtimeMethods.join(",") == "HEAPU8";
}

test "wasm entry: a struct crosses as leaf parameters and returns through one result import" {
	const e = entryFor(["tag"]);
	const s = e.source;
	assert s.includes("export function msb_calc_tag(l_0: float64, l_1: float64, l_2Ptr: uint32, l_2Len: int32, l_3: int32): void {");
	assert s.includes("\tconst r = msbm0_tag({ at: { x: l_0, y: l_1 }, text: msbStrAdopt(l_2Ptr, l_2Len), count: l_3 });");
	assert s.includes("\tmsb_rs_ddsi(r.at.x, r.at.y, msbStrPtr(r.text), r.text.asBytes().length, r.count);");
	assert s.split("extern function msb_rs_ddsi").length == 2;
	assert e.jsLibrary.includes("\tmsb_rs_ddsi: (...a) => { try { return Module['msb'].takes.pop()(...a); } catch (e) { throw Module['msb'].die(e); } },");
	assert e.exportedFunctions.join(",") == "_msb_calc_tag,_malloc,_free,_MsMain";
}

test "wasm entry: a Vec parameter is rebuilt from ptr and len, a Vec result is handed over by msb_rv" {
	const e = entryFor(["scale"]);
	const s = e.source;
	assert s.includes("function msbVecFrom_float32(ptr: uint32, len: int32): Vec<float32> {");
	assert s.includes("export function msb_calc_scale(xsPtr: uint32, xsLen: int32, k: float32): void {");
	assert s.includes("\tconst r = msbm0_scale(msbVecFrom_float32(xsPtr, xsLen), k);");
	assert s.includes("\tmsb_rv((r as Span<uint16>) as Ptr<void> as uint64 as int32, r.length as int32);");
	assert e.jsLibrary.includes("\tmsb_rv: (...a) => { try { return Module['msb'].takes.pop()(...a); } catch (e) { throw Module['msb'].die(e); } },");
	assert e.exportedFunctions.join(",") == "_msb_calc_scale,_malloc,_free,_MsMain";
	assert e.runtimeMethods.join(",") == "HEAPU8";
}

test "wasm entry: a Span parameter is a view over the copied ptr and len, with no Vec rebuilt" {
	const e = entryFor(["total", "fill"]);
	const s = e.source;
	assert s.includes("export function msb_calc_total(xsPtr: uint32, xsLen: int32): float32 {\n\treturn msbm0_total((xsPtr as uint64 as Ptr<float32>)[0..xsLen]);");
	assert s.includes("export function msb_calc_fill(xsPtr: uint32, xsLen: int32, at: int32): void {\n\tmsbm0_fill((xsPtr as uint64 as Ptr<boolean>)[0..xsLen], at);");
	assert !s.includes("msbVecFrom_");
	assert e.exportedFunctions.join(",") == "_msb_calc_total,_msb_calc_fill,_malloc,_free,_MsMain";
	assert e.runtimeMethods.join(",") == "HEAPU8";
}

test "wasm entry: data that only flows out of wasm needs the heap view and no allocator" {
	const text = entryFor(["label"]);
	assert text.exportedFunctions.join(",") == "_msb_calc_label,_MsMain";
	assert text.runtimeMethods.join(",") == "HEAPU8";
	const record = entryFor(["make"]);
	assert record.exportedFunctions.join(",") == "_msb_calc_make,_MsMain";
	assert record.runtimeMethods.join(",") == "HEAPU8";
	const vec = entryFor(["ramp"]);
	assert vec.exportedFunctions.join(",") == "_msb_calc_ramp,_MsMain";
	assert vec.runtimeMethods.join(",") == "HEAPU8";
}

test "wasm entry: a string parameter alone needs the allocator" {
	const e = entryFor(["bytes"]);
	assert e.exportedFunctions.join(",") == "_msb_calc_bytes,_malloc,_free,_MsMain";
	assert e.runtimeMethods.join(",") == "HEAPU8";
}

const EVERY_FUNCTION = ["tag", "scale", "total", "fill", "add64", "evaluate", "isEven", "visit", "twice", "report", "sumBy", "edit", "label", "make", "bytes", "ramp"];

test "wasm entry: each runtime export is used by the js glue of that function and each use is exported" {
	for (const name of EVERY_FUNCTION) {
		const m = manifestOf([name]);
		const code = jsBindings(m, "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false }).modules[0].code;
		const e = wasmEntrySource(m.functions, (p: string) => "./calc");
		const allocates = code.includes("__msbEncOwned(") || code.includes("__msbCopyIn(");
		const readsHeap = allocates || code.includes("__msbDec(") || code.includes("__msbVecOut(");
		let want = "_" + m.functions[0].exportSymbol;
		if (allocates) want += ",_malloc,_free";
		want += ",_MsMain";
		assert e.exportedFunctions.join(",") == want;
		assert e.runtimeMethods.join(",") == (readsHeap ? "HEAPU8" : "");
		assert (code.includes("_free(") || code.includes("__msbFree(")) == allocates;
	}
}

test "wasm entry: every callback and result import hands an exception to the registry before it leaves the import" {
	const e = entryFor(["evaluate", "visit", "report", "sumBy", "edit", "tag", "scale"]);
	assert e.jsLibrary.split("catch (e) { throw Module['msb'].die(e); } },").length == 8;
	assert e.jsLibrary.split("\n\tmsb_").length == 9;
}

test "wasm entry: a callback import has the fixed arity of its signature, no rest or spread, a string or span taking two parameters" {
	const e = entryFor(["tick", "visit", "report", "sumBy", "edit"]);
	const lib = e.jsLibrary;
	const tail = " } catch (e) { throw Module['msb'].die(e); } },\n";
	assert lib.includes("\tmsb_cb_i_: (id) => { try { return Module['msb'].cb(id)();" + tail);
	assert lib.includes("\tmsb_cb_v_id: (id, a0, a1) => { try { return Module['msb'].cb(id)(a0, a1);" + tail);
	assert lib.includes("\tmsb_cb_i_s: (id, a0p, a0l) => { try { return Module['msb'].cb(id)(a0p, a0l);" + tail);
	assert lib.includes("\tmsb_cb_f_p: (id, a0p, a0l) => { try { return Module['msb'].cb(id)(a0p, a0l);" + tail);
	assert lib.includes("\tmsb_cb_v_pi: (id, a0p, a0l, a1) => { try { return Module['msb'].cb(id)(a0p, a0l, a1);" + tail);
	assert !lib.includes("...");
	assert e.source.includes('extern function msb_cb_v_pi(id: int32, a0p: uint32, a0l: int32, a1: int32): void from "msb_cb_v_pi";');
}

test "wasm entry: every library entry reads the registry from the instance's Module, and one check per library names a missing one" {
	const e = entryFor(["evaluate", "visit", "report", "sumBy", "edit", "tag", "scale"]);
	assert !e.jsLibrary.includes("globalThis");
	assert e.jsLibrary.split("registry missing").length == 2;
	assert entryFor(["tag"]).jsLibrary.includes("\n\tmsb_rs_ddsi__postset: \"if (!Module['msb']) throw");
}
