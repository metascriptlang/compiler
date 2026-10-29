import { ExtensionRegistry, buildExportInfo, ExportedSymInfo, CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "../../test/handoff/helpers";
import { BoundaryCallback, BoundaryKind, BoundaryMode, Manifest, manifestFor } from "./manifest";
import { jsBindings } from "./jsSide";

const SOURCE = `
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
	const m = manifestFor("/p/calc.ms", "/p/app.ms", exps);
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
	assert code.includes("function bundled_both(a0, a1, a2) {
	const e0 = __msbEnc(a0);
	const e2 = __msbEnc(a2);
	try {
		return __msbMod._msb_calc_both(e0[0], e0[1], a1, e2[0], e2[1]);
	} finally {
		__msbMod._free(e0[0]);
		__msbMod._free(e2[0]);
	}
}");
}

test "js side: a string result is decoded with the length read right after the call" {
	const code = bindingsFor(["twice"]).modules[0].code;
	assert code.includes("function bundled_twice(a0) {
	const e0 = __msbEnc(a0);
	try {
		return __msbDec(__msbMod._msb_calc_twice(e0[0], e0[1]), __msbMod._msb_ret_len());
	} finally {
		__msbMod._free(e0[0]);
	}
}");
}

test "js side: a callback string parameter arrives as pointer and length and is decoded" {
	const cb: BoundaryCallback = { params: [BoundaryKind.String, BoundaryKind.I32], result: BoundaryKind.I32, signature: "i_si" };
	const m: Manifest = {
		functions: [{
			modulePath: "/p/calc.ms", moduleKey: "calc", name: "note", exportSymbol: "msb_calc_note",
			params: [{ name: "cb", kind: BoundaryKind.Callback, mode: BoundaryMode.Borrowed, callback: cb }],
			result: BoundaryKind.Void,
		}],
		errors: [],
	};
	const code = jsBindings(m, "./app.wasm.mjs", (f) => "bundled_" + f.name).modules[0].code;
	assert code.includes("const id0 = __msb.push((x0, x1, x2) => a0(__msbDec(x0, x1), x2));");
}

test "js side: the prelude carries the string glue once and reads the heap fresh" {
	const p = bindingsFor(["twice"]).prelude;
	assert p.indexOf("function __msbEnc(s)") == p.lastIndexOf("function __msbEnc(s)");
	assert p.includes("function __msbDec(p, len)");
	assert p.includes("__msbMod.HEAPU8");
	assert !p.includes("wasmMemory");
}
