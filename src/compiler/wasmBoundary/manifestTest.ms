import { ExtensionRegistry, buildExportInfo, ExportedSymInfo } from "../../checker/context";
import { CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "../../test/handoff/helpers";
import { BoundaryKind, BoundaryMode, BoundaryRefusal, manifestFor, moduleKeyOf } from "./manifest";

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
	assert m.errors.length == 0, m.errors.map((e) => e.message).join("; ");
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
	assert m.errors.length == 5, m.errors.map((e) => e.message).join("; ");
	assert m.errors[0].message.includes("'takesArray'") && m.errors[0].message.includes("parameter 'xs'");
	assert m.errors[1].message.includes("'takesBox'") && m.errors[1].message.includes("parameter 'b'") && m.errors[1].message.includes("'Box'");
	assert m.errors[2].message.includes("'maybe'") && m.errors[2].message.includes("nullable");
	assert m.errors[3].message.includes("'wide'") && m.errors[3].message.includes("the result");
	assert m.errors[4].message.includes("'cbString'") && m.errors[4].message.includes("callback");
}

function errorFor(errors: BoundaryRefusal[], fn: string): string {
	let found = "";
	let count = 0;
	for (const e of errors) {
		if (e.message.includes(`'${fn}' in`)) { found = e.message; count += 1; }
	}
	if (count != 1) { throw new Error(`${fn}: expected one error, got ${count} in ${errors.map((e) => e.message).join("; ")}`); }
	return found;
}

const NO_FORM_TYPES = `
enum Color { Red, Green }
class Box { v: int32 = 0; }
struct Pixel { shade: Color; n: int32; }
struct Op { run: (x: int32) => int32; n: int32; }
struct Table { m: Map<string, int32>; n: int32; }
struct Holder { b: Box; n: int32; }
struct Rows { xs: int32[]; n: int32; }
struct Tagged { u: int32 | string; n: int32; }
`;

test "manifest: an enum, a union and a function refuse with the way out of their own position" {
	const src = NO_FORM_TYPES + `
export function paramEnum(c: Color): int32 { return 0; }
export function resultEnum(): Color { return Color.Red; }
export function fieldEnum(p: Pixel): int32 { return 0; }
export function literalEnum(c: Color.Red): int32 { return 0; }
export function paramUnion(v: int32 | string): int32 { return 0; }
export function resultUnion(): int32 | string { return 1; }
export function fieldUnion(t: Tagged): int32 { return 0; }
export function resultFn(n: int32): (x: int32) => int32 { return (x: int32): int32 => x + n; }
export function fieldFn(o: Op): int32 { return 0; }
`;
	const names = ["paramEnum", "resultEnum", "fieldEnum", "literalEnum", "paramUnion", "resultUnion", "fieldUnion", "resultFn", "fieldFn"];
	const m = manifestFor(MODULE, ENTRY, exportsOf(src, names), names);
	assert m.functions.length == 0;
	assert m.errors.length == names.length, m.errors.map((e) => e.message).join("; ");
	const enumLead = "and an enum has no boundary form yet: cross its integer instead, ";
	const enumBack = ", and converting back with 'n as Color', which checks the range";
	assert errorFor(m.errors, "paramEnum").includes("parameter 'c' has type") && errorFor(m.errors, "paramEnum").includes(enumLead + "passing 'x as int32'" + enumBack);
	assert errorFor(m.errors, "resultEnum").includes("the result has type") && errorFor(m.errors, "resultEnum").includes(enumLead + "returning 'x as int32'" + enumBack);
	assert errorFor(m.errors, "fieldEnum").includes("field 'shade' of parameter 'p' has type") && errorFor(m.errors, "fieldEnum").includes(enumLead + "declaring the field as int32 and writing 'x as int32'" + enumBack);
	assert errorFor(m.errors, "literalEnum").includes(enumLead + "passing 'x as int32'" + enumBack);
	const unionLead = "and a union has no single boundary form: ";
	assert errorFor(m.errors, "paramUnion").includes("parameter 'v' has type") && errorFor(m.errors, "paramUnion").includes(unionLead + "pass a tag integer and the payload as separate parameters, or give each variant its own @wasm function");
	assert errorFor(m.errors, "resultUnion").includes("the result has type") && errorFor(m.errors, "resultUnion").includes(unionLead + "return a struct with a tag integer and one field per variant, or give each variant its own @wasm function");
	assert errorFor(m.errors, "fieldUnion").includes("field 'u' of parameter 't' has type") && errorFor(m.errors, "fieldUnion").includes(unionLead + "flatten it into a tag integer field and one field per variant");
	const fnLead = "and a function crosses the boundary only as a parameter, borrowed for the call, so it cannot be ";
	assert errorFor(m.errors, "resultFn").includes("the result has type") && errorFor(m.errors, "resultFn").includes(fnLead + "a result: return the value it computes");
	assert errorFor(m.errors, "fieldFn").includes("field 'run' of parameter 'o' has type") && errorFor(m.errors, "fieldFn").includes(fnLead + "a struct field: pass it as a separate parameter");
}

test "manifest: a Map, a Set, an array and a class refuse with the way out of their own position" {
	const src = NO_FORM_TYPES + `
export function paramMap(m: Map<string, int32>): int32 { return 0; }
export function resultSet(): Set<int32> { return new Set<int32>(); }
export function fieldMap(t: Table): int32 { return 0; }
export function paramArray(xs: int32[]): int32 { return 0; }
export function resultArray(): float64[] { return []; }
export function fieldArray(r: Rows): int32 { return 0; }
export function paramClass(b: Box): int32 { return 0; }
export function resultClass(): Box { return new Box(); }
export function fieldClass(h: Holder): int32 { return 0; }
export function paramNullable(b: Box | null): int32 { return 0; }
`;
	const names = ["paramMap", "resultSet", "fieldMap", "paramArray", "resultArray", "fieldArray", "paramClass", "resultClass", "fieldClass", "paramNullable"];
	const m = manifestFor(MODULE, ENTRY, exportsOf(src, names), names);
	assert m.functions.length == 0;
	assert m.errors.length == names.length, m.errors.map((e) => e.message).join("; ");
	const table = "and a Map or Set is a hash table that lives on one heap and ";
	assert errorFor(m.errors, "paramMap").includes("parameter 'm' has type") && errorFor(m.errors, "paramMap").includes(table + "does not cross: pass its keys and values as separate Vec parameters of numbers and rebuild it on the other side (string keys have no Vec form yet)");
	assert errorFor(m.errors, "resultSet").includes("the result has type") && errorFor(m.errors, "resultSet").includes(table + "does not cross: return a Vec of numbers and rebuild it on the other side, a Map's keys from one @wasm function and its values from another");
	assert errorFor(m.errors, "fieldMap").includes("field 'm' of parameter 't' has type") && errorFor(m.errors, "fieldMap").includes(table + "cannot be a struct field: pass its keys and values as separate Vec parameters of numbers instead");
	const array = "and an array reference lives on one heap and does not cross";
	assert errorFor(m.errors, "paramArray").includes("parameter 'xs' has type") && errorFor(m.errors, "paramArray").includes(array + ": use a Vec of bool, integer or float elements, which crosses as a copy");
	assert errorFor(m.errors, "resultArray").includes("the result has type") && errorFor(m.errors, "resultArray").includes(array + ": return a Vec of bool, integer or float elements, which crosses as a copy");
	assert errorFor(m.errors, "fieldArray").includes("field 'xs' of parameter 'r' has type") && errorFor(m.errors, "fieldArray").includes(array + ", and a struct holds no Vec: pass the elements as a separate Vec parameter");
	const identity = "class instance has an identity on one heap and does not cross as a copy: ";
	const later = "; sharing the instance itself waits for Handle<T>, which is planned";
	assert errorFor(m.errors, "paramClass").includes("parameter 'b' has type 'Box', and a " + identity + "pass the values it holds as parameters or as a struct, which crosses as a copy" + later);
	assert errorFor(m.errors, "resultClass").includes("the result has type 'Box', and a " + identity + "return the values it holds as a struct, which crosses as a copy" + later);
	assert errorFor(m.errors, "fieldClass").includes("field 'b' of parameter 'h' has type 'Box', and a " + identity + "copy the values it holds into fields of the struct" + later);
	assert errorFor(m.errors, "paramNullable").includes("parameter 'b' has type") && errorFor(m.errors, "paramNullable").includes("and a nullable " + identity + "pass the values it holds as parameters");
}

test "manifest: a type with no targeted reason keeps the generic refusal that lists what crosses" {
	const src = `
export function takes(x: bigint): int32 { return 0; }
export function gives(): bigint { return 0n; }
export function waits(p: Promise<int32>): int32 { return 0; }
`;
	const m = manifestFor(MODULE, ENTRY, exportsOf(src, ["takes", "gives", "waits"]), ["takes", "gives", "waits"]);
	assert m.errors.length == 3, m.errors.map((e) => e.message).join("; ");
	assert errorFor(m.errors, "takes").includes("which has no JS/wasm boundary form: use bool");
	assert errorFor(m.errors, "gives").includes("which has no JS/wasm boundary form: return void");
	assert errorFor(m.errors, "waits").includes("parameter 'p' has type") && errorFor(m.errors, "waits").includes("which has no JS/wasm boundary form: use bool");
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
	assert m.errors.length == 0, m.errors.map((e) => e.message).join("; ");
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
	assert m.errors.length == 3, m.errors.map((e) => e.message).join("; ");
	assert m.errors[0].message.includes("'own'") && m.errors[0].message.includes("lifecycle hook");
	assert m.errors[1].message.includes("'loose'") && m.errors[1].message.includes("field 'n'");
	assert m.errors[2].message.includes("'words'") && m.errors[2].message.includes("Vec");
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
	assert m.errors.length == 2, m.errors.map((e) => e.message).join("; ");
	assert m.errors[0].message.includes("'names'") && m.errors[0].message.includes("Span");
	assert m.errors[1].message.includes("'view'") && m.errors[1].message.includes("the result") && m.errors[1].message.includes("return a Vec");
}
