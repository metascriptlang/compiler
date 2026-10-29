import { ExtensionRegistry, buildExportInfo, ExportedSymInfo, CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "../../test/handoff/helpers";
import { manifestFor } from "./manifest";
import { wasmEntrySource } from "./wasmSide";

const SOURCE = `
export function add64(a: int64, b: int64): int64 { return a + b; }
export function evaluate(value: int32, cb: (x: int32) => int32): int32 { return cb(value) + 1; }
export function isEven(x: uint8): boolean { return x % 2 == 0; }
export function visit(n: int32, cb: (x: int32, y: float64) => void): void { cb(n, 1.5); }
`;

function entryFor(names: string[]) {
	const ctx = checkSource(SOURCE);
	if (ctx == null) throw new Error("internal: test source did not check");
	const exps: ExportedSymInfo[] = [];
	for (const n of names) {
		const sym = lookupSymbol(ctx.table, n);
		if (sym == null) throw new Error("internal: test source lacks " + n);
		exps.push(buildExportInfo(sym!, null as unknown as ExtensionRegistry, "/p/calc.ms", null as unknown as CheckerContext));
	}
	const m = manifestFor("/p/calc.ms", "/p/app.ms", exps);
	if (m.errors.length > 0) throw new Error("internal: " + m.errors.join("; "));
	return wasmEntrySource(m.functions, (p: string) => "./calc");
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
	assert e.jsLibrary == "addToLibrary({\n\tmsb_cb_i_i: (id, ...a) => globalThis.__msb.cb(id, ...a),\n});\n";
	assert entryFor(["add64"]).jsLibrary == "";
}
