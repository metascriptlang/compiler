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
	const m = manifestFor(MODULE, ENTRY, exportsOf(CALC, ["add64", "evaluate", "half", "isEven", "ping", "name"]), ["add64", "evaluate", "half", "isEven", "ping", "name"]);
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
export function cbString(cb: (n: int32) => string): int32 { return 0; }
`;
	const m = manifestFor(MODULE, ENTRY, exportsOf(src, ["takesArray", "takesBox", "maybe", "wide", "cbString"]), ["takesArray", "takesBox", "maybe", "wide", "cbString"]);
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

test "manifest: a struct crosses as its flattened leaves and a Vec of numbers by its element" {
	const src = `
struct Point { x: float64; y: float64; }
struct Label { at: Point; text: string; count: int32; }
export function tag(l: Label): Label { return l; }
export function sum(xs: Vec<float32>): Vec<int32> { const out: Vec<int32> = []; return out; }
`;
	const m = manifestFor(MODULE, ENTRY, exportsOf(src, ["tag", "sum"]), ["tag", "sum"]);
	assert m.errors.length == 0, m.errors.join("; ");
	const tag = m.functions[0];
	assert tag.params[0].kind == BoundaryKind.Struct && tag.params[0].mode == BoundaryMode.Copied;
	const paths: string[] = [];
	for (const leaf of tag.params[0].leaves) paths.push(leaf.path.join("."));
	assert paths.join(",") == "at.x,at.y,text,count";
	assert tag.params[0].leaves[2].kind == BoundaryKind.String && tag.params[0].leaves[3].kind == BoundaryKind.I32;
	assert tag.result == BoundaryKind.Struct && tag.resultLeaves.length == 4;
	const sum = m.functions[1];
	assert sum.params[0].kind == BoundaryKind.Vec && sum.params[0].element == BoundaryKind.F32;
	assert sum.result == BoundaryKind.Vec && sum.resultElement == BoundaryKind.I32;
}

test "manifest: a struct with a hook, a nullable field or a Vec of strings fails naming the field" {
	const src = `
struct Owned { n: int32; }
function onDestroy(this o: Owned): void {}
struct Loose { n: int32 | null; }
export function own(o: Owned): int32 { return 0; }
export function loose(l: Loose): int32 { return 0; }
export function words(ws: Vec<string>): int32 { return 0; }
`;
	const m = manifestFor(MODULE, ENTRY, exportsOf(src, ["own", "loose", "words"]), ["own", "loose", "words"]);
	assert m.functions.length == 0;
	assert m.errors.length == 3, m.errors.join("; ");
	assert m.errors[0].includes("'own'") && m.errors[0].includes("lifecycle hook");
	assert m.errors[1].includes("'loose'") && m.errors[1].includes("field 'n'");
	assert m.errors[2].includes("'words'") && m.errors[2].includes("Vec");
}

test "manifest: a Span parameter is borrowed when read-only and shared when writable, and a Span result is refused" {
	const src = `
export function total(xs: Readonly<Span<float32>>): float32 { return 0; }
export function fill(xs: Span<int32>): void {}
export function names(xs: Span<string>): void {}
export function view(xs: Readonly<Span<int32>>): Readonly<Span<int32>> { return xs; }
`;
	const m = manifestFor(MODULE, ENTRY, exportsOf(src, ["total", "fill", "names", "view"]), ["total", "fill", "names", "view"]);
	assert m.functions.length == 2;
	assert m.functions[0].params[0].kind == BoundaryKind.Span && m.functions[0].params[0].mode == BoundaryMode.Borrowed && m.functions[0].params[0].element == BoundaryKind.F32;
	assert m.functions[1].params[0].mode == BoundaryMode.Shared && m.functions[1].params[0].element == BoundaryKind.I32;
	assert m.errors.length == 2, m.errors.join("; ");
	assert m.errors[0].includes("'names'") && m.errors[0].includes("Span");
	assert m.errors[1].includes("'view'") && m.errors[1].includes("the result") && m.errors[1].includes("return a Vec");
}
