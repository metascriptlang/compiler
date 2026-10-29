import { ExtensionRegistry, buildExportInfo, ExportedSymInfo } from "../../checker/context";
import { CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "../../test/handoff/helpers";
import { BoundaryKind, BoundaryMode, manifestFor, moduleKeyOf } from "./manifest";

const ENTRY = "/proj/app/main.ms";
const MODULE = "/proj/app/calc/core.ms";

function exportsOf(source: string, names: string[]): ExportedSymInfo[] {
	const ctx = checkSource(source);
	if (ctx == null) throw new Error("internal: test source did not check");
	const out: ExportedSymInfo[] = [];
	for (const n of names) {
		const sym = lookupSymbol(ctx.table, n);
		if (sym == null) throw new Error("internal: test source lacks " + n);
		out.push(buildExportInfo(sym!, null as unknown as ExtensionRegistry, MODULE, null as unknown as CheckerContext));
	}
	return out;
}

const CALC = `
export function add64(a: int64, b: int64): int64 { return a + b; }
export function evaluate(value: int32, cb: (x: int32) => int32): int32 { return cb(value) + 1; }
export function half(x: float64): float64 { return x / 2; }
export function isEven(x: uint8): boolean { return x % 2 == 0; }
export function ping(): void {}
export function name(s: string): string { return s; }
`;

test "manifest: scalar, callback and string exports map to boundary kinds" {
	const m = manifestFor(MODULE, ENTRY, exportsOf(CALC, ["add64", "evaluate", "half", "isEven", "ping", "name"]));
	assert m.errors.length == 0, m.errors.join("; ");
	assert m.functions.length == 6;
	const add = m.functions[0];
	assert add.exportSymbol == "msb_calc_score_add64";
	assert add.moduleKey == "calc_score";
	assert add.result == BoundaryKind.I64;
	assert add.params.length == 2 && add.params[0].kind == BoundaryKind.I64 && add.params[0].mode == BoundaryMode.Copied;
	const ev = m.functions[1];
	assert ev.params[1].kind == BoundaryKind.Callback && ev.params[1].mode == BoundaryMode.Borrowed;
	assert ev.params[1].callback!.signature == "i_i";
	assert m.functions[2].params[0].kind == BoundaryKind.F64 && m.functions[2].result == BoundaryKind.F64;
	assert m.functions[3].params[0].kind == BoundaryKind.U8 && m.functions[3].result == BoundaryKind.Bool;
	assert m.functions[4].result == BoundaryKind.Void;
	assert m.functions[5].params[0].kind == BoundaryKind.String && m.functions[5].result == BoundaryKind.String;
}

test "manifest: an array, a class and a nullable parameter fail naming function, parameter and type" {
	const src = `
class Box { v: int32 = 0; }
export function takesArray(xs: int32[]): int32 { return 0; }
export function takesBox(b: Box): int32 { return 0; }
export function maybe(x: int32 | null): int32 { return 0; }
export function wide(): Box { return new Box(); }
export function cbString(cb: (s: string) => int32): int32 { return 0; }
`;
	const m = manifestFor(MODULE, ENTRY, exportsOf(src, ["takesArray", "takesBox", "maybe", "wide", "cbString"]));
	assert m.functions.length == 0;
	assert m.errors.length == 5, m.errors.join("; ");
	assert m.errors[0].includes("'takesArray'") && m.errors[0].includes("parameter 'xs'");
	assert m.errors[1].includes("'takesBox'") && m.errors[1].includes("parameter 'b'") && m.errors[1].includes("'Box'");
	assert m.errors[2].includes("'maybe'") && m.errors[2].includes("nullable");
	assert m.errors[3].includes("'wide'") && m.errors[3].includes("the result");
	assert m.errors[4].includes("'cbString'") && m.errors[4].includes("callback");
}

test "manifest: moduleKeyOf is relative to the entry and injective on separators and underscores" {
	assert moduleKeyOf(MODULE, ENTRY) == "calc_score";
	assert moduleKeyOf("/proj/app/a_b.ms", ENTRY) == "a__b";
	assert moduleKeyOf("/proj/app/a/b.ms", ENTRY) == "a_sb";
	assert moduleKeyOf("/proj/app/a-b.ms", ENTRY) == "a_x2db";
	assert moduleKeyOf("/proj/lib/x.ms", ENTRY) == "_x2e_x2e_slib_sx";
}
