import { Node, Symbol, SymbolKind, SymbolFlag, Type, TypeKind, TypeFlag } from "../../ast/node";
import { hasFlag, makeSymbol } from "../../checker/symbol";
import { createStruct } from "../../checker/types";
import { CheckerContext, buildExportInfo, errorCount, ExtensionMethod } from "../../checker/context";
import { combine as mix, hS as mixString, hI as mixInt, hB as mixBool, taHashNode, transAmHashSurface } from "./hash";
import { createTransAmDb, dbSetFileText, dbParse, dbTypeCheck, TransAmDb } from "./index";
import { recordModuleImport } from "./moduleDeps";
import { getFileId } from "./fileInput";

enum TypeShape { Plain, Param, Instance }

class DigestState {
	modulePath: string;
	memo: HashMap<Type, int64>;
	open: HashSet<Type>;
}

function symbolKey(sym: Symbol): string {
	if (hasFlag(sym, SymbolFlag.Anon)) throw new Error(`internal: digest: anonymous symbol ${sym.name} has no key`);
	if (sym.instantiatedFrom != null) return `${sym.name}.0.${sym.modulePath}`;
	return match (sym.symbolKind) {
		SymbolKind.Variable | SymbolKind.Function | SymbolKind.Class | SymbolKind.Interface | SymbolKind.TypeAlias | SymbolKind.Enum | SymbolKind.Struct | SymbolKind.Actor | SymbolKind.Macro => `${sym.name}.${sym.disamb}.${sym.modulePath}`,
		_ => keyless(sym),
	};
}

function keyless(sym: Symbol): string {
	throw new Error(`internal: digest: ${sym.symbolKind.toString()} symbol ${sym.name} has no key`);
}

function shapeOf(kind: TypeKind): TypeShape {
	return match (kind) {
		TypeKind.GenericParam => TypeShape.Param,
		TypeKind.GenericInstance => TypeShape.Instance,
		TypeKind.Number | TypeKind.String | TypeKind.Boolean | TypeKind.Void | TypeKind.Char | TypeKind.Null | TypeKind.Pending | TypeKind.Never
			| TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 | TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 | TypeKind.Float32 | TypeKind.Float64
			| TypeKind.Struct | TypeKind.Array | TypeKind.SizedArray | TypeKind.Span | TypeKind.Function | TypeKind.Tuple | TypeKind.CString
			| TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow | TypeKind.Sink | TypeKind.Lent | TypeKind.Var
			| TypeKind.TypeReference | TypeKind.Union | TypeKind.Enum | TypeKind.Result | TypeKind.Distinct | TypeKind.Error
			| TypeKind.StringLiteral | TypeKind.EnumLiteral | TypeKind.Conditional | TypeKind.Alias | TypeKind.BooleanLiteral | TypeKind.Varargs | TypeKind.Cursor
			| TypeKind.Unknown | TypeKind.None | TypeKind.Inferred | TypeKind.BigInt | TypeKind.Set | TypeKind.Module | TypeKind.IndexedAccess | TypeKind.KeyOf
			| TypeKind.NumberLiteral | TypeKind.NonPrimitive | TypeKind.Mapped => TypeShape.Plain,
		_ => unhandledKind(kind),
	};
}

function unhandledKind(kind: TypeKind): TypeShape {
	throw new Error(`internal: digest: unhandled ${kind.toString()}`);
}

function mixFlags<E>(h: int64, flags: BitSet<E>): int64 {
	if (flags.isEmpty()) return mix(h, 0);
	for (const flag of flags.toItems()) h = mixInt(h, flag as int32);
	return h;
}

function mixStrings(h: int64, strings: string[] | null): int64 {
	if (strings == null) return mix(h, 0);
	h = mixInt(h, strings.length);
	for (const s of strings) h = mixString(h, s);
	return h;
}

function mixNodes(h: int64, nodes: Node[] | null): int64 {
	if (nodes == null) return mix(h, 0);
	h = mixInt(h, nodes.length);
	for (const node of nodes) h = mix(h, taHashNode(node));
	return h;
}

function typeDigest(st: DigestState, t: Type | null): int64 {
	if (t == null) return 0;
	const known = st.memo.get(t);
	if (known != null) return known;
	const shape = shapeOf(t.kind);
	let h: int64 = mixString(mixInt(0, t.kind as int32), t.typeName);
	if (shape != TypeShape.Param && t.sym != null && t.sym.modulePath != st.modulePath) {
		h = mixString(h, symbolKey(t.sym));
		if (shape == TypeShape.Instance) h = mixTypes(st, h, t.typeChildren);
		st.memo.set(t, h);
		return h;
	}
	if (st.open.has(t)) return h;
	st.open.add(t);
	h = mixStrings(h, t.typeNames);
	h = mixTypes(st, h, t.typeChildren);
	if (shape != TypeShape.Instance) h = mix(h, typeDigest(st, t.typeReturn));
	h = mix(h, typeDigest(st, t.typeExtra));
	h = mixFlags(h, t.typeFlags.excl(TypeFlag.OpenClass));
	h = mixInt(h, t.typeValue);
	h = mixInt(h, t.callConv as int32);
	for (let i = 0; i < t.attachedOps.length; i += 1) {
		const hook = t.attachedOps[i];
		if (hook != null) h = mixString(mixInt(h, i), symbolKey(hook));
	}
	h = mixStrings(h, t.optionalFields);
	h = mix(h, typeDigest(st, t.typeInst));
	st.open.delete(t);
	st.memo.set(t, h);
	return h;
}

function mixTypes(st: DigestState, h: int64, types: Type[] | null): int64 {
	if (types == null) return mix(h, 0);
	h = mixInt(h, types.length);
	for (const t of types) h = mix(h, typeDigest(st, t));
	return h;
}

function mixExtension(h: int64, ext: ExtensionMethod | null): int64 {
	if (ext == null) return mix(h, 0);
	h = mixString(h, ext.methodName);
	h = mixBool(h, ext.isStatic);
	return mixString(h, ext.sourcePath);
}

function routineDigest(st: DigestState, sym: Symbol): int64 {
	let h: int64 = mixInt(0, sym.symbolKind as int32);
	h = mixInt(h, sym.disamb);
	h = mixInt(h, sym.overloadIdx);
	h = mixFlags(h, sym.symFlags.excl(SymbolFlag.Used).excl(SymbolFlag.Consumed).excl(SymbolFlag.OverloadValidated));
	h = mixString(h, sym.nativeName);
	h = mixString(h, sym.exportName);
	h = mixString(h, sym.builtinKind);
	h = mixString(h, sym.headerPath);
	h = mixString(h, sym.jsModulePath);
	h = mixInt(h, sym.mutatedParams);
	h = mixNodes(h, sym.defaultParams);
	h = mixTypes(st, h, sym.typeParams);
	h = mixStrings(h, sym.fieldDecoratorNames);
	h = mixInt(h, sym.fieldDecorators.length);
	for (const row of sym.fieldDecorators) h = mixNodes(h, row);
	h = mixStrings(h, sym.metaKeys);
	h = mixNodes(h, sym.metaValues);
	h = mixStrings(h, sym.nonisolatedFields);
	h = mixInt(h, sym.duVariantSlot);
	for (const field of sym.staticFields) {
		h = mixString(h, field.name);
		h = mix(h, typeDigest(st, field.symbolType));
		h = mixFlags(h, field.symFlags.excl(SymbolFlag.Used));
	}
	if (sym.ctorRoutine != null) h = mix(h, typeDigest(st, sym.ctorRoutine.symbolType));
	h = mix(h, typeDigest(st, sym.symbolType));
	if (sym.declNode != null) h = mixInt(h, transAmHashSurface(sym.declNode) as int64);
	return h;
}

function exportDigest(st: DigestState, ctx: CheckerContext, sym: Symbol): int64 {
	const names = ctx.interfNames.get(sym) ?? [sym.name];
	let h: int64 = mixStrings(0, names);
	if (sym.modulePath != ctx.modulePath) return mixString(h, symbolKey(sym));
	h = mix(h, routineDigest(st, sym));
	h = mixInt(h, sym.overloads.length);
	for (const ov of sym.overloads) h = mix(h, routineDigest(st, ov));
	for (const name of names) {
		const info = buildExportInfo(sym, ctx.extensionRegistry, ctx.modulePath, ctx, name);
		h = mixExtension(h, info.ext);
		for (const ext of info.overloadExts) h = mixExtension(h, ext);
		h = mix(h, typeDigest(st, info.converterTargetType));
	}
	return h;
}

export function ifaceDigest(ctx: CheckerContext, depDigests: int64[]): int64 {
	const st: DigestState = { modulePath: ctx.modulePath, memo: new HashMap<Type, int64>(), open: new HashSet<Type>() };
	let h: int64 = mixInt(0, ctx.interf.length);
	for (const sym of ctx.interf) h = mix(h, exportDigest(st, ctx, sym));
	h = mixString(h, ctx.includeDirectives);
	h = mixString(h, ctx.compilerFlags);
	h = mixString(h, ctx.compileDirectives);
	h = mixInt(h, ctx.jsImportRegistry.length);
	for (const entry of ctx.jsImportRegistry) h = mixStrings(mixString(h, entry.modulePath), entry.names);
	h = mixInt(h, errorCount(ctx));
	for (const dep of depDigests) h = mix(h, dep);
	return h;
}

export function implDigest(parse: Node, iface: int64): int64 {
	return mix(taHashNode(parse), iface);
}

const DEP = "/dg/dep.ms";
const USE = "/dg/use.ms";
const USE_TEXT = 'import { f } from "./dep";\nexport function g(): int32 { return f(1); }';

function measure(db: TransAmDb): int64[] {
	const dep = ifaceDigest(dbTypeCheck(db, DEP), []);
	const use = ifaceDigest(dbTypeCheck(db, USE), [dep]);
	return [dep, use, implDigest(dbParse(db, DEP), dep), implDigest(dbParse(db, USE), use)];
}

function digests(depText: string, useText: string = USE_TEXT): int64[] {
	const db = createTransAmDb(100);
	dbSetFileText(db, DEP, depText);
	dbSetFileText(db, USE, useText);
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, USE), getFileId(db.fileInput, DEP));
	return measure(db);
}

const BASE_DEP = "export function f(a: int32): int32 { return a + 1; }";

test "a repeated check gives the same digests" {
	const a = digests(BASE_DEP);
	const b = digests(BASE_DEP);
	for (let i = 0; i < 4; i += 1) assert a[i] == b[i];
}

test "a comment leaves both digests unchanged" {
	const base = digests(BASE_DEP);
	const edited = digests("// head\nexport function f(a: int32): int32 { /* inner */ return a + 1; } // tail");
	for (let i = 0; i < 4; i += 1) assert base[i] == edited[i];
}

test "line shifts and whitespace leave both digests unchanged" {
	const base = digests(BASE_DEP);
	const edited = digests("\n\n\nexport   function f(a: int32): int32\n{\n\treturn a + 1;\n}\n");
	for (let i = 0; i < 4; i += 1) assert base[i] == edited[i];
}

test "a private body edit moves the impl digest and not the interface digest" {
	const base = digests("function helper(): int32 { return 1; }\nexport function f(a: int32): int32 { return a + helper(); }");
	const edited = digests("function helper(): int32 { return 2; }\nexport function f(a: int32): int32 { return a + helper(); }");
	assert base[0] == edited[0];
	assert base[1] == edited[1];
	assert base[2] != edited[2];
}

test "an exported body edit moves the impl digest and not the interface digest" {
	const base = digests(BASE_DEP);
	const edited = digests("export function f(a: int32): int32 { return a * 2; }");
	assert base[0] == edited[0];
	assert base[1] == edited[1];
	assert base[2] != edited[2];
	assert base[3] == edited[3];
}

test "a method body edit leaves the interface digest unchanged" {
	const base = digests("export class C { x: int32 = 1; get(): int32 { return this.x; } }");
	const edited = digests("export class C { x: int32 = 1; get(): int32 { return this.x + 1; } }");
	assert base[0] == edited[0];
	assert base[2] != edited[2];
}

test "an exported signature change moves the interface digest" {
	const base = digests(BASE_DEP);
	assert base[0] != digests("export function f(a: int64): int32 { return 1; }")[0];
	assert base[0] != digests("export function f(a: int32): int64 { return 1; }")[0];
	assert base[0] != digests("export function f(a: int32, b: int32 = 2): int32 { return a + 1; }")[0];
}

test "a body edit that writes a parameter moves the interface digest" {
	assert digests("export function f(a: int32): int32 { return a; }")[0] != digests("export function f(a: int32): int32 { a = 2; return a; }")[0];
	const read = "export class P { x: int32 = 1; }\nexport function f(p: P): int32 { return p.x; }";
	const written = "export class P { x: int32 = 1; }\nexport function f(p: P): int32 { p.x = 2; return 1; }";
	assert digests(read)[0] != digests(written)[0];
}

test "an inferred return type change moves the interface digest" {
	const ints = digests("export function f(a: int32) { return 1; }");
	assert ints[0] != digests("export function f(a: int32) { return true; }")[0];
}

test "an overload order change moves the interface digest" {
	const first = "export function f(a: int32): int32 { return 1; }\n";
	const second = "export function f(a: boolean): int32 { return 2; }\n";
	const third = "export function f(a: int64): int32 { return 3; }\n";
	assert digests(first + second)[0] != digests(second + first)[0];
	assert digests(first + second + third)[0] != digests(first + third + second)[0];
}

test "a class field change moves the interface digest" {
	const base = digests("export class C { x: int32 = 1; }");
	assert base[0] != digests("export class C { x: int32 = 1; y: int32 = 2; }")[0];
	assert base[0] != digests("export class C { x: int64 = 1; }")[0];
	assert base[0] != digests("export class C { x: int32 = 2; }")[0];
}

test "an exported constant change moves the interface digest" {
	assert digests("export const k = 1;")[0] != digests("export const k = 2;")[0];
}

test "an unrelated private declaration leaves the interface digest unchanged" {
	const base = digests(BASE_DEP);
	assert base[0] == digests("const hidden = 5;\n" + BASE_DEP)[0];
	assert base[0] == digests("class Hidden { v: int32 = 1; }\n" + BASE_DEP)[0];
	assert base[0] == digests("function other(): int32 { return 9; }\n" + BASE_DEP)[0];
	assert base[2] != digests("const hidden = 5;\n" + BASE_DEP)[2];
}

test "a dependency digest reaches every importer in the chain" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/ch/logic.ms", "export function v(): int32 { return 1; }");
	dbSetFileText(db, "/ch/mid.ms", 'import { v } from "./logic";\nexport function m(): int32 { return v(); }');
	dbSetFileText(db, "/ch/far.ms", 'import { m } from "./mid";\nexport function z(): int32 { return m(); }');
	const edges = [["/ch/mid.ms", "/ch/logic.ms"], ["/ch/far.ms", "/ch/mid.ms"]];
	for (const e of edges) recordModuleImport(db.moduleDeps, getFileId(db.fileInput, e[0]), getFileId(db.fileInput, e[1]));
	const a = chain(db);
	dbSetFileText(db, "/ch/logic.ms", "export function v(): int32 { return 2; }");
	const body = chain(db);
	assert body[0] == a[0] && body[1] == a[1] && body[2] == a[2];
	dbSetFileText(db, "/ch/logic.ms", "export function v(): int64 { return 1; }");
	const sig = chain(db);
	assert sig[0] != a[0];
	assert sig[1] != a[1];
	assert sig[2] != a[2];
	dbSetFileText(db, "/ch/logic.ms", "export function v(): int32 { return 1; }");
	const undone = chain(db);
	assert undone[0] == a[0] && undone[1] == a[1] && undone[2] == a[2];
}

function chain(db: TransAmDb): int64[] {
	const logic = ifaceDigest(dbTypeCheck(db, "/ch/logic.ms"), []);
	const mid = ifaceDigest(dbTypeCheck(db, "/ch/mid.ms"), [logic]);
	const far = ifaceDigest(dbTypeCheck(db, "/ch/far.ms"), [mid]);
	return [logic, mid, far];
}

test "the digest folds each dependency digest in order" {
	const db = createTransAmDb(100);
	dbSetFileText(db, DEP, BASE_DEP);
	const ctx = dbTypeCheck(db, DEP);
	assert ifaceDigest(ctx, [1, 2]) != ifaceDigest(ctx, [2, 1]);
	assert ifaceDigest(ctx, [1]) != ifaceDigest(ctx, [1, 1]);
	assert ifaceDigest(ctx, [1]) == ifaceDigest(ctx, [1]);
}

test "an errored module still has a digest that moves with its errors" {
	const clean = digests(BASE_DEP);
	const broken = digests("export function f(a: int32): int32 { return nope; }");
	assert clean[0] != broken[0];
}

test "checking importers leaves the exporter digest unchanged" {
	const dep = "export class Base { x: int32 = 1; get(): int32 { return this.x; } }\n"
		+ "export class Box<T> { v: T; constructor(v: T) { this.v = v; } }\n"
		+ "export function f(a: int32): int32 { return a; }\n"
		+ "export function f(a: boolean): int32 { return 1; }\n"
		+ "export function twice<T>(a: T): T { return a; }";
	const use = 'import { Base, Box, f, twice } from "./dep";\n'
		+ "class Derived extends Base { y: int32 = 2; }\n"
		+ "const d = new Derived();\n"
		+ "const b = new Box<int32>(3);\n"
		+ "const r = f(d.get()) + f(true) + twice(1);\n"
		+ "export function f2(a: int32): int32 { return f(a); }";
	const db = createTransAmDb(100);
	dbSetFileText(db, DEP, dep);
	dbSetFileText(db, USE, use);
	recordModuleImport(db.moduleDeps, getFileId(db.fileInput, USE), getFileId(db.fileInput, DEP));
	const depCtx = dbTypeCheck(db, DEP);
	const before = ifaceDigest(depCtx, []);
	const beforeImpl = implDigest(dbParse(db, DEP), before);
	assert errorCount(dbTypeCheck(db, USE)) == 0;
	assert ifaceDigest(depCtx, []) == before;
	assert implDigest(dbParse(db, DEP), before) == beforeImpl;
}

test "a foreign type reference is keyed by its symbol" {
	const owner = createStruct("Far", [], [], true);
	const sym = makeSymbol("Far", SymbolKind.Class, owner, false);
	sym.modulePath = "/elsewhere.ms";
	owner.sym = sym;
	const db = createTransAmDb(100);
	dbSetFileText(db, DEP, "export class Near { x: int32 = 1; }");
	const ctx = dbTypeCheck(db, DEP);
	const here = ifaceDigest(ctx, []);
	const near = ctx.interf[0];
	near.symbolType.typeChildren.push(owner);
	near.symbolType.typeNames.push("far");
	const withKey = ifaceDigest(ctx, []);
	assert withKey != here;
	sym.disamb = 7;
	assert ifaceDigest(ctx, []) != withKey;
}

test "an anonymous foreign symbol has no key" {
	const owner = createStruct("Far", [], [], true);
	const sym = makeSymbol("Far", SymbolKind.Class, owner, false);
	sym.modulePath = "/elsewhere.ms";
	sym.symFlags = sym.symFlags.incl(SymbolFlag.Anon);
	owner.sym = sym;
	const db = createTransAmDb(100);
	dbSetFileText(db, DEP, "export class Near { x: int32 = 1; }");
	const ctx = dbTypeCheck(db, DEP);
	ctx.interf[0].symbolType.typeChildren.push(owner);
	ctx.interf[0].symbolType.typeNames.push("far");
	let message = "";
	try { ifaceDigest(ctx, []); } catch (e) { message = (e as Error).message; }
	assert message == "internal: digest: anonymous symbol Far has no key";
}
