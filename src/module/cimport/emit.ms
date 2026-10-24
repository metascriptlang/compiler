// C Header Parser — proper tokenize → preprocess → parse pipeline
//
// Walks the parsed Obj[] from the cparse library and emits MetaScript
// extern declarations.

import { Obj, ObjKind } from "../cparse/obj";
import { CType, CTypeKind } from "../cparse/type";
import { TargetInfo, hostTarget, targetFor } from "../cparse/target";
import { Diagnostic } from "../cparse/error";
import { parseHeader } from "./index";
import { writeFile, ensureDir, readFile } from "std/fs";

// ===== C Type → MetaScript Type Mapping =====

// Map known C runtime typedef names to MetaScript types
function mapRuntimeType(name: string): string {
	return match (name) {
		"msString" => "string",
		"msBuffer" => "Buffer",
		"msBool" | "MS_BOOL" => "boolean",
		"int8_t" => "int8",
		"int16_t" => "int16",
		"int32_t" => "int32",
		"int64_t" => "int64",
		"uint8_t" => "uint8",
		"uint16_t" => "uint16",
		"uint32_t" => "uint32",
		"uint64_t" => "uint64",
		"size_t" | "uintptr_t" => "uint64",
		"ssize_t" | "intptr_t" => "int64",
		_ => "",
	};
}

// `skipTypedef=false` (default): USE-site — preserves typedef alias names so a
// MyId parameter emits as `x: MyId`. `skipTypedef=true`: DEFINE-site — used by
// emitTypedef so `type MyId = ...` resolves to the underlying type, not back
// to itself (a struct, union or enum carries the name of the typedef that
// first names it, so its typedefName === obj.name).
function cTypeToMs(t: CType, skipTypedef: boolean = false): string {
	if (!skipTypedef && t.typedefName != "") {
		const mapped = mapRuntimeType(t.typedefName);
		if (mapped != "") return mapped;
		// Opaque types from heuristic (unknown C types without #include)
		if (!t.isComplete) return "Ptr<void>";
		return t.typedefName;
	}
	return match (t.kind) {
		CTypeKind.Void => "void",
		CTypeKind.Bool => "boolean",
		CTypeKind.Char => t.isSigned ? "int8" : "uint8",
		CTypeKind.Short => t.isSigned ? "int16" : "uint16",
		CTypeKind.Int => t.isSigned ? "int32" : "uint32",
		CTypeKind.Long => t.size == 4 ? (t.isSigned ? "int32" : "uint32") : (t.isSigned ? "int64" : "uint64"),
		CTypeKind.LongLong => t.isSigned ? "int64" : "uint64",
		CTypeKind.Float => "float32",
		CTypeKind.Double => "number",
		CTypeKind.LongDouble => "number",
		CTypeKind.Enum => {
			if (t.tagName != "") return t.tagName;
			return "int32";
		},
		CTypeKind.Ptr => {
			if (t.base == null) return "Ptr<void>";
			// void* → Ptr<void>: raw ABI pointer. NOT `unknown` — unknown is the
			// boxed dynamic type, so an FFI handle typed unknown gets boxed on
			// module-boundary crossings and C receives a garbage pointer.
			if (t.base.kind == CTypeKind.Void) return "Ptr<void>";
			// char* and const char* → cstring; unsigned char and the fixed-width
			// byte typedefs (uint8_t, int8_t) point at bytes, not text.
			if (t.base.kind == CTypeKind.Char && t.base.isPlainChar && mapRuntimeType(t.base.typedefName) == "") return "cstring";
			// Function pointer → closure type
			if (t.base.kind == CTypeKind.Func) return emitFuncType(t.base);
			if (isOpaqueTag(t.base)) return `Ptr<${t.base.tagName}>`;
			if (t.base.kind == CTypeKind.Struct && t.base.tagName != "") return `Ptr<${t.base.tagName}>`;
			const inner = cTypeToMs(t.base);
			if (t.base.kind == CTypeKind.Struct || t.base.kind == CTypeKind.Union) return `Ptr<${inner}>`;
			// Other typed pointer — const pointee → Borrow<T> (read-only, accepts arr[0]
			// borrow-promotion); mutable → Ptr<T>.
			return t.base.isConst ? `Borrow<${inner}>` : `Ptr<${inner}>`;
		},
		CTypeKind.Array => {
			if (t.base == null) return "unknown";
			const elem = cTypeToMs(t.base);
			if (t.arrayLen >= 0) return elem.includes("=>") ? `(${elem})[${t.arrayLen}]` : `${elem}[${t.arrayLen}]`;
			return `Span<${elem}>`;
		},
		CTypeKind.Func => emitFuncType(t),
		CTypeKind.Struct => {
			if (t.tagName != "") return t.tagName;
			return "unknown";
		},
		CTypeKind.Union => {
			if (t.tagName != "") return t.tagName;
			return "unknown";
		},
		_ => "unknown",
	};
}

function isOutHandle(p: CType): boolean {
	if (p.kind != CTypeKind.Ptr || p.base == null || p.base.isConst) return false;
	const handle = p.base;
	if (handle.kind != CTypeKind.Ptr || handle.base == null) return false;
	const k = handle.base.kind;
	return k == CTypeKind.Struct || k == CTypeKind.Union || k == CTypeKind.Void;
}

function nullablePointer(p: CType, ms: string): string {
	return p.kind == CTypeKind.Ptr && ms.startsWith("Ptr<") ? `${ms} | null` : ms;
}

function emitParams(t: CType, outHandles: boolean): string {
	let result = "";
	for (let i = 0; i < t.params.length; i += 1) {
		if (i > 0) result = result + ", ";
		const pName = i < t.paramNames.length && t.paramNames[i] != "" ? t.paramNames[i] : `p${i}`;
		const p = t.params[i];
		result = outHandles && isOutHandle(p)
			? result + `out ${pName}: ${cTypeToMs(p.base)}`
			: result + `${pName}: ${nullablePointer(p, cTypeToMs(p))}`;
	}
	return result;
}

function emitFuncType(t: CType): string {
	return "(" + emitParams(t, false) + ") => " + cTypeToMs(t.returnType);
}

// ===== Emit Declarations =====

function emitFunction(obj: Obj, prefix: string): string {
	const t = obj.type;
	let params = emitParams(t, true);
	if (t.isVariadic) {
		if (params != "") params = params + ", ";
		params = params + "...args: unknown[]";
	}
	return `${prefix}extern function ${obj.name}(${params}): ${cTypeToMs(t.returnType)};\n`;
}

function emitVariable(obj: Obj, prefix: string): string {
	return `${prefix}extern const ${obj.name}: ${cTypeToMs(obj.type)};\n`;
}

function emitStructBody(name: string, t: CType, prefix: string): string {
	let result = `${prefix}extern struct ${name} {\n`;
	for (const m of t.members) {
		if (m.name == "") continue;
		result = result + `\t${m.name}: ${cTypeToMs(m.type)};\n`;
	}
	result = result + "}\n";
	return result;
}

// ===== Complete extern structs =====
// Complete: the declared fields are all of C's, in C's order, each mapped to a type of C's
// size and alignment; the checker folds that layout and the C backend asserts it. A union's
// key carries UNION_KEY_MARK, so the checker lays its members over each other.

const completeStructKeys = new HashSet<string>();

export function completeStructKey(targetName: string, cName: string, fieldNames: string[], fieldTypes: string[]): string {
	let key = `${targetName}\t${cName}`;
	for (let i = 0; i < fieldNames.length && i < fieldTypes.length; i += 1) {
		key = key + `\t${fieldNames[i]}:${fieldTypes[i].replaceAll(" ", "").replaceAll("\t", "")}`;
	}
	return key;
}

export function registerCompleteStruct(key: string): void {
	completeStructKeys.add(key);
}

export function isCompleteStruct(key: string): boolean {
	return completeStructKeys.has(key);
}

const UNION_KEY_MARK = "\tunion";

export function isCompleteUnion(key: string): boolean {
	return completeStructKeys.has(key + UNION_KEY_MARK);
}

const includedByHeader = new HashMap<string, string[]>();

export function registerHeaderIncludes(header: string, included: string[]): void {
	includedByHeader.set(header, included);
}

// The headers whose declarations `header` brings in through its #includes.
export function headerIncludes(header: string): string[] {
	return includedByHeader.get(header) ?? [];
}

function mappedWidth(ms: string): int32 {
	return match (ms) {
		"int8" | "uint8" | "boolean" => 1,
		"int16" | "uint16" => 2,
		"int32" | "uint32" | "float32" => 4,
		"int64" | "uint64" | "number" => 8,
		_ => -1,
	};
}

function enumFitsInt(t: CType, objs: Obj[]): boolean {
	const lo = -2147483648 as int64;
	const hi = 4294967295 as int64;
	for (const o of objs) {
		if (o.kind != ObjKind.EnumConstant || (o.type != t && o.type != t.origin)) continue;
		if (o.enumValue < lo || o.enumValue > hi) return false;
	}
	return true;
}

function exactField(t: CType, objs: Obj[], target: TargetInfo): boolean {
	if (t.typedefName != "") {
		const mapped = mapRuntimeType(t.typedefName);
		if (mapped != "") return mappedWidth(mapped) == t.size;
		if (!t.isComplete) return false;
	}
	return match (t.kind) {
		CTypeKind.Bool | CTypeKind.Char | CTypeKind.Short | CTypeKind.Int | CTypeKind.Long | CTypeKind.LongLong
			| CTypeKind.Float | CTypeKind.Double | CTypeKind.LongDouble => mappedWidth(cTypeToMs(t, true)) == t.size,
		CTypeKind.Enum => t.size == 4 && enumFitsInt(t, objs),
		CTypeKind.Ptr => t.base == null || t.base.kind != CTypeKind.Func,
		CTypeKind.Array => t.arrayLen > 0 && t.base != null && exactField(t.base, objs, target),
		CTypeKind.Struct | CTypeKind.Union => cTypeToMs(t) != "unknown" && isCompleteTranslation(t, objs, target),
		_ => false,
	};
}

function isCompleteTranslation(t: CType, objs: Obj[], target: TargetInfo): boolean {
	if ((t.kind != CTypeKind.Struct && t.kind != CTypeKind.Union) || !t.layoutKnown || t.isFlexible || t.members.length == 0) return false;
	if (target.pointerSize != 8) return false;
	for (const m of t.members) {
		if (!exactField(m.type, objs, target)) return false;
	}
	return true;
}

function translatedStructKey(name: string, t: CType, target: TargetInfo): string {
	const names: string[] = [];
	const types: string[] = [];
	for (const m of t.members) {
		names.push(m.name);
		types.push(cTypeToMs(m.type));
	}
	const key = completeStructKey(`${target.os}-${target.cpu}`, name, names, types);
	return t.kind == CTypeKind.Union ? key + UNION_KEY_MARK : key;
}

function emitEnum(objs: Obj[], enumType: CType, enumName: string, prefix: string): string {
	let result = `${prefix}extern enum ${enumName} {\n`;
	for (const obj of objs) {
		if (obj.kind == ObjKind.EnumConstant && obj.type == enumType) {
			result = result + `\t${obj.name} = ${obj.enumValue},\n`;
		}
	}
	result = result + "}\n";
	return result;
}

function isOpaqueTag(t: CType): boolean {
	return (t.kind == CTypeKind.Struct || t.kind == CTypeKind.Union) && t.tagName != "" && !t.isComplete;
}

function emitOpaqueTag(t: CType, prefix: string): string {
	const keyword = t.kind == CTypeKind.Union ? "union" : "struct";
	return `${prefix}extern struct ${t.tagName} from "${keyword} ${t.tagName}";\n`;
}

function emitsStructBody(obj: Obj): boolean {
	const t = obj.type;
	if (isOpaqueTag(t) && t.tagName == obj.name) return false;
	return (t.kind == CTypeKind.Struct || t.kind == CTypeKind.Union) && t.members.length > 0;
}

function emitTypedef(obj: Obj, prefix: string): string {
	const t = obj.type;
	if (isOpaqueTag(t) && t.tagName == obj.name) return `${prefix}extern struct ${obj.name};\n`;
	if (emitsStructBody(obj)) return emitStructBody(obj.name, t, prefix);
	// Enum typedef → handled separately via emitEnum
	if (t.kind == CTypeKind.Enum) return "";
	// Skip cTypeToMs's typedefName short-circuit — it would return obj.name
	// itself and emit `type X = X;`. Forward-declared struct whose tagName
	// matches obj.name still produces self-reference via the kind branch;
	// guard with "unknown" fallback.
	let underlying = cTypeToMs(t, true);
	if (underlying == obj.name) underlying = "unknown";
	return `${prefix}type ${obj.name} = ${underlying};\n`;
}

// ===== Main Entry Point =====

export interface HeaderTranslation {
	// Module source: an import of each name an included file declares and this header's own
	// declarations use, an `export *` of each included file, then the header's own declarations.
	source: string;
	// The header's own declarations as text, and those of each file it includes as this header's
	// translation unit read them; a file read two ways (another #define before its #include)
	// is a different declaration under one name.
	ownShape: string;
	includedShapes: HashMap<string, string>;
}

// A header is a module of the declarations its own file writes, as a C translation unit sees
// each declaration once however many headers include it.
export function translateHeaderModule(source: string, headerPath: string = "header.h", includePaths: string[] = [], outDiags: Diagnostic[] | null = null, readLog: string[] | null = null, target: TargetInfo = null as unknown as TargetInfo, outCompleteKeys: string[] | null = null, canonical: ((path: string) => string) | null = null): HeaderTranslation {
	const tg = target != null ? target : hostTarget();
	const parsed = parseHeader(source, headerPath, { target: tg, includePaths, macroFlags: [], readLog });
	if (outDiags != null) {
		for (const d of parsed.diagnostics) outDiags.push(d);
	}
	const canonicalOf = new HashMap<string, string>();
	const fileOf = (path: string): string => {
		const known = canonicalOf.get(path);
		if (known != null) return known;
		const c = canonical != null ? canonical(path) : path;
		canonicalOf.set(path, c);
		return c;
	};
	const own = fileOf(headerPath);

	const emittedEnums: string[] = [];
	const declaredNames = new HashSet<string>();
	const declaringFile = new HashMap<string, string>();
	const seenInFile = new HashSet<string>();
	const redeclared: string[] = [];
	const includedFiles: string[] = [];
	const includedShapes = new HashMap<string, string>();
	const opaqueTags: CType[] = [];
	const refs = new HashSet<string>();
	let ownShape = "";
	for (const obj of parsed.objs) {
		if (obj.name == "" || obj.kind == ObjKind.EnumConstant) continue;
		const file = fileOf(obj.file);
		const mine = file == own;
		if (mine ? declaredNames.has(obj.name) : seenInFile.has(`${file}\t${obj.name}`)) continue;
		const text = emitObj(obj, parsed.objs, tg, emittedEnums, mine ? outCompleteKeys : null, mine);
		if (text == "") continue;
		if (mine) {
			declaredNames.add(obj.name);
			declaringFile.delete(obj.name);
			ownShape = ownShape + text;
			collectTypeRefNames(obj.type, refs, new HashSet<string>(), declaringFile);
			collectOpaqueTags(obj.type, opaqueTags, new HashSet<string>(), declaringFile);
			continue;
		}
		seenInFile.add(`${file}\t${obj.name}`);
		const first = declaringFile.get(obj.name);
		if (first == null) declaringFile.set(obj.name, file);
		else if (first != file && !redeclared.includes(obj.name)) redeclared.push(obj.name);
		const shape = includedShapes.get(file);
		if (shape == null) includedFiles.push(file);
		includedShapes.set(file, (shape ?? "") + text);
	}

	const importsFrom = new HashMap<string, string[]>();
	for (const name of refs) {
		if (declaredNames.has(name)) continue;
		const file = declaringFile.get(name);
		if (file == null) continue;
		const names = importsFrom.get(file) ?? [];
		names.push(name);
		importsFrom.set(file, names);
	}
	let head = "";
	for (const file of includedFiles) {
		const names = importsFrom.get(file);
		if (names != null) {
			names.sort();
			head = head + `import { ${names.join(", ")} } from "${file}";\n`;
		}
		head = head + `export * from "${file}";\n`;
	}
	redeclared.sort();
	for (const name of redeclared) {
		const file = declaringFile.get(name);
		if (file != null && !declaredNames.has(name)) head = head + `export { ${name} } from "${file}";\n`;
	}
	let tags = "";
	for (const tag of opaqueTags) {
		if (declaredNames.has(tag.tagName) || declaringFile.has(tag.tagName)) continue;
		declaredNames.add(tag.tagName);
		tags = tags + emitOpaqueTag(tag, "export ");
	}
	return { source: head + ownShape + tags, ownShape, includedShapes };
}

// `complete`: the struct layout this translation registers as complete, for the header that
// declares it; an included file's declarations register in that file's own translation.
function emitObj(obj: Obj, objs: Obj[], tg: TargetInfo, emittedEnums: string[], outCompleteKeys: string[] | null, complete: boolean): string {
	const prefix = "export ";
	return match (obj.kind) {
		ObjKind.Function => emitFunction(obj, prefix),
		ObjKind.Variable => emitVariable(obj, prefix),
		ObjKind.TypedefName => {
			if (obj.type.kind == CTypeKind.Enum) {
				if (arrayContains(emittedEnums, obj.name)) return "";
				emittedEnums.push(obj.name);
				return emitEnum(objs, obj.type, obj.name, prefix);
			}
			if (complete && emitsStructBody(obj) && isCompleteTranslation(obj.type, objs, tg)) {
				const key = translatedStructKey(obj.name, obj.type, tg);
				registerCompleteStruct(key);
				if (outCompleteKeys != null) outCompleteKeys.push(key);
			}
			return emitTypedef(obj, prefix);
		},
		_ => "",
	};
}

// Walk a CType tree and collect names of user-defined typedefs / tagged
// struct/union/enum referenced anywhere inside. Used by translateHeaderModule
// to compute the transitive closure for the import-name filter so a
// typedef referenced by an emitted function is not silently dropped.
// Skips primitive-mapped typedef names (int32_t, size_t, ...) since those
// resolve via mapRuntimeType and need no separate emit. Struct self-refs
// via pointer-to-self are guarded by a string-keyed seen set so the walk
// terminates.
function collectTypeRefNames(t: CType, refs: HashSet<string>, seen: HashSet<string>, declaredElsewhere: HashMap<string, string>): void {
	if (t == null) return;
	if (t.typedefName != "") {
		const mapped = mapRuntimeType(t.typedefName);
		// Runtime-mapped typedef (msString → string, size_t → uint64, ...):
		// user code uses the MS-native alias; do NOT walk into the C struct
		// internals or we drag implementation details (msStrPayload etc.)
		// into the emitted MS source and clash with other modules' externs.
		if (mapped != "") return;
		refs.add(t.typedefName);
		if (declaredElsewhere.has(t.typedefName)) return;
	}
	const isAggregate = t.kind == CTypeKind.Struct
		|| t.kind == CTypeKind.Union
		|| t.kind == CTypeKind.Enum;
	if (isAggregate && t.tagName != "") {
		refs.add(t.tagName);
		const key = "tag:" + t.tagName;
		if (seen.has(key)) return;
		seen.add(key);
	}
	if (t.base != null) collectTypeRefNames(t.base, refs, seen, declaredElsewhere);
	if (t.returnType != null) collectTypeRefNames(t.returnType, refs, seen, declaredElsewhere);
	for (const p of t.params) collectTypeRefNames(p, refs, seen, declaredElsewhere);
	for (const m of t.members) collectTypeRefNames(m.type, refs, seen, declaredElsewhere);
}

function collectOpaqueTags(t: CType, out: CType[], seen: HashSet<string>, declaredElsewhere: HashMap<string, string>): void {
	if (t == null) return;
	if (t.typedefName != "" && (mapRuntimeType(t.typedefName) != "" || declaredElsewhere.has(t.typedefName))) return;
	if (isOpaqueTag(t)) {
		for (const o of out) {
			if (o.tagName == t.tagName) return;
		}
		out.push(t);
		return;
	}
	if ((t.kind == CTypeKind.Struct || t.kind == CTypeKind.Union) && t.tagName != "") {
		const key = "tag:" + t.tagName;
		if (seen.has(key)) return;
		seen.add(key);
	}
	if (t.base != null) collectOpaqueTags(t.base, out, seen, declaredElsewhere);
	if (t.returnType != null) collectOpaqueTags(t.returnType, out, seen, declaredElsewhere);
	for (const p of t.params) collectOpaqueTags(p, out, seen, declaredElsewhere);
	for (const m of t.members) collectOpaqueTags(m.type, out, seen, declaredElsewhere);
}

function arrayContains(arr: string[], val: string): boolean {
	for (const item of arr) {
		if (item == val) return true;
	}
	return false;
}

// ===== Tests =====

test "emit extern function" {
	const ms = translateHeaderModule("extern int add(int a, int b);").source;
	assert ms.indexOf("extern function add") >= 0;
	assert ms.indexOf("a: int32") >= 0;
	assert ms.indexOf("b: int32") >= 0;
	assert ms.indexOf(": int32;") >= 0;
}

test "emit typedef struct" {
	const ms = translateHeaderModule("typedef struct { int x; int y; } Point;").source;
	assert ms.indexOf("extern struct Point") >= 0;
	assert ms.indexOf("x: int32") >= 0;
	assert ms.indexOf("y: int32") >= 0;
}

test "emit typedef enum" {
	const ms = translateHeaderModule("typedef enum { FLAG_READ = 1, FLAG_WRITE = 2 } Flags;").source;
	assert ms.indexOf("extern enum Flags") >= 0;
	assert ms.indexOf("FLAG_READ = 1") >= 0;
	assert ms.indexOf("FLAG_WRITE = 2") >= 0;
}

test "emit extern variable" {
	const ms = translateHeaderModule("extern int counter;").source;
	assert ms.indexOf("extern const counter: int32") >= 0;
}

test "a fixed C array imports as a sized array of its element" {
	const ms = translateHeaderModule("typedef struct P { int x; } P; typedef int (*Op)(int); typedef struct V { int v[4]; P ps[2]; void (*fs[3])(void); } V; extern int table[8];").source;
	assert ms.indexOf("v: int32[4];") >= 0;
	assert ms.indexOf("ps: P[2];") >= 0;
	assert ms.indexOf("fs: (() => void)[3];") >= 0;
	assert ms.indexOf("extern const table: int32[8];") >= 0;
	assert ms.indexOf("SizedArray") < 0;
}

test "brace initializer does not derail declaration parse" {
	const diags: Diagnostic[] = [];
	const ms = translateHeaderModule("static const int arr[] = {32, 64, 96};\nint after(void);", "init.h", [], diags).source;
	assert ms.indexOf("extern function after") >= 0;
	assert diags.length == 0;
}

test "designated initializer and _Static_assert skip clean" {
	const diags: Diagnostic[] = [];
	const src = "typedef struct T { int a; } T;\n_Static_assert(1 == 1, \"ok\");\nstatic const T t = { .a = 1 };\nint after2(void);";
	const ms = translateHeaderModule(src, "init2.h", [], diags).source;
	assert ms.indexOf("extern function after2") >= 0;
	assert diags.length == 0;
}

test "emit pointer types" {
	const ms = translateHeaderModule("extern void *handle;\nextern const char *name;").source;
	assert ms.indexOf("handle: Ptr<void>") >= 0;
	assert ms.indexOf("name: cstring") >= 0;
}

test "opaque struct-pointer typedef points at its tag declared under its C name" {
	const ms = translateHeaderModule("typedef struct Opaque* OpaqueRef;\nOpaqueRef makeIt(void);").source;
	assert ms.indexOf("OpaqueRef = Ptr<Opaque>") >= 0;
	assert ms.indexOf("extern struct Opaque from \"struct Opaque\";") >= 0;
	assert ms.indexOf("unknown") < 0;
}

test "opaque union pointer is declared as a union" {
	const ms = translateHeaderModule("union U;\nunion U* getU(void);").source;
	assert ms.indexOf("getU(): Ptr<U>") >= 0;
	assert ms.indexOf("extern struct U from \"union U\";") >= 0;
}

test "opaque typedef named after its tag is declared once under the typedef name" {
	const ms = translateHeaderModule("typedef struct X X;\nX* mkX(void);\nvoid useX(struct X* x);").source;
	assert ms.indexOf("extern struct X;") >= 0;
	assert ms.indexOf("from \"struct X\"") < 0;
	assert ms.indexOf("mkX(): Ptr<X>") >= 0;
}

test "the opaque tag behind a handle is declared" {
	const ms = translateHeaderModule("typedef struct Impl* H;\nint use(H h);").source;
	assert ms.indexOf("export extern struct Impl from \"struct Impl\";") >= 0;
}

test "handle written through a pointer param binds as out" {
	const ms = translateHeaderModule("typedef struct Impl* H;\nstruct S;\nint mk(H* out);\nint mk2(struct S** out);\nint mk3(void** out);\nint argv(char** v);\nint ro(const H* h);").source;
	assert ms.indexOf("mk(out out: H)") >= 0;
	assert ms.indexOf("mk2(out out: Ptr<S>)") >= 0;
	assert ms.indexOf("mk3(out out: Ptr<void>)") >= 0;
	assert ms.indexOf("argv(v: Ptr<cstring> | null)") >= 0;
	assert ms.indexOf("out h") < 0;
}

test "struct pointer param is a nullable Ptr, const or not" {
	const ms = translateHeaderModule("typedef struct { int a; } A;\nstruct B { int b; };\nint f(const A* a, A* m, const struct B* b);\nint g(const float* v);").source;
	assert ms.indexOf("a: Ptr<A> | null") >= 0;
	assert ms.indexOf("m: Ptr<A> | null") >= 0;
	assert ms.indexOf("b: Ptr<B> | null") >= 0;
	assert ms.indexOf("v: Borrow<float32>") >= 0;
}

function emitFor(os: string, cpu: string, source: string): string {
	return translateHeaderModule(source, "target.h", [], null, null, targetFor(os, cpu)).source;
}

function plainCharPointersAreCString(os: string, cpu: string): boolean {
	const src = "const char *a(void);\nchar *b(void);\nint c(char **v);\n"
		+ "typedef char ch;\nconst ch *d(void);";
	const ms = emitFor(os, cpu, src);
	return ms.indexOf("function a(): cstring") >= 0
		&& ms.indexOf("function b(): cstring") >= 0
		&& ms.indexOf("v: Ptr<cstring> | null") >= 0
		&& ms.indexOf("function d(): cstring") >= 0;
}

function explicitCharPointersAreBytes(os: string, cpu: string): boolean {
	const src = "signed char *s(void);\nconst signed char *cs(void);\n"
		+ "unsigned char *u(void);\nconst unsigned char *cu(void);";
	const ms = emitFor(os, cpu, src);
	return ms.indexOf("function s(): Ptr<int8>") >= 0
		&& ms.indexOf("function cs(): Borrow<int8>") >= 0
		&& ms.indexOf("function u(): Ptr<uint8>") >= 0
		&& ms.indexOf("function cu(): Borrow<uint8>") >= 0;
}

test "plain char pointers are cstring whether the target's char is signed or unsigned" {
	assert plainCharPointersAreCString("android", "arm64");
	assert plainCharPointersAreCString("linux", "riscv64");
	assert plainCharPointersAreCString("macos", "arm64");
	assert plainCharPointersAreCString("linux", "x86_64");
}

test "signed char and unsigned char pointers are byte pointers on every target" {
	assert explicitCharPointersAreBytes("android", "arm64");
	assert explicitCharPointersAreBytes("linux", "riscv64");
	assert explicitCharPointersAreBytes("macos", "arm64");
	assert explicitCharPointersAreBytes("linux", "x86_64");
}

test "only plain char takes the target's signedness" {
	const src = "char pc(void);\nsigned char sc(void);\nunsigned char uc(void);";
	const unsignedChar = emitFor("android", "arm64", src);
	assert unsignedChar.indexOf("function pc(): uint8") >= 0;
	assert unsignedChar.indexOf("function sc(): int8") >= 0;
	assert unsignedChar.indexOf("function uc(): uint8") >= 0;
	const signedChar = emitFor("macos", "arm64", src);
	assert signedChar.indexOf("function pc(): int8") >= 0;
	assert signedChar.indexOf("function sc(): int8") >= 0;
	assert signedChar.indexOf("function uc(): uint8") >= 0;
}

test "emit with export prefix" {
	const ms = translateHeaderModule("extern int add(int a, int b);").source;
	assert ms.indexOf("export extern function add") >= 0;
}

test "emit variadic function" {
	const ms = translateHeaderModule("extern void printf(const char *fmt, ...);").source;
	assert ms.indexOf("printf") >= 0;
	assert ms.indexOf("fmt: cstring") >= 0;
	assert ms.indexOf("...args") >= 0;
}

test "emit type alias" {
	const ms = translateHeaderModule("typedef unsigned long size_t;", "header.h", [], null, null, targetFor("linux", "x86_64")).source;
	assert ms.indexOf("type size_t = uint64") >= 0, ms;
}

test "a long takes the width of the target's long" {
	const src = "typedef unsigned long ul;\ntypedef long sl;\n";
	const lp64 = translateHeaderModule(src, "header.h", [], null, null, targetFor("linux", "x86_64")).source;
	assert lp64.includes("type ul = uint64") && lp64.includes("type sl = int64"), lp64;
	const llp64 = translateHeaderModule(src, "header.h", [], null, null, targetFor("windows", "x86_64")).source;
	assert llp64.includes("type ul = uint32") && llp64.includes("type sl = int32"), llp64;
	const ilp32 = translateHeaderModule(src, "header.h", [], null, null, targetFor("linux", "i386")).source;
	assert ilp32.includes("type ul = uint32") && ilp32.includes("type sl = int32"), ilp32;
}

test "emit function pointer param" {
	const ms = translateHeaderModule("typedef int (*CompareFn)(const void *, const void *);").source;
	assert ms.indexOf("CompareFn") >= 0;
}

test "user-defined typedef does not self-reference" {
	const ms = translateHeaderModule("typedef int MyId;").source;
	assert ms.indexOf("type MyId = int32") >= 0;
	assert ms.indexOf("type MyId = MyId") < 0;
}

function completeOn(source: string, os: string, cpu: string): string[] {
	const keys: string[] = [];
	translateHeaderModule(source, "header.h", [], null, null, targetFor(os, cpu), keys);
	const names: string[] = [];
	for (const k of keys) names.push(k.split("\t")[1]);
	return names;
}

const EXACT_SHAPES = "typedef struct { unsigned long size; int value; } Plain;\n"
	+ "typedef struct { Plain p; char c; } Nested;\n"
	+ "typedef struct { Plain arr[3]; } ArrOfStruct;\n"
	+ "typedef enum { E_A = 1, E_B = 2 } SmallE;\n"
	+ "typedef struct { SmallE e; char c; } WithEnum;\n"
	+ "typedef struct { char name[13]; int x; } CharArr;\n"
	+ "struct OpaqueT;\ntypedef struct { struct OpaqueT* o; int x; } RefOpaque;\n"
	+ "typedef Plain PlainAlias;\n"
	+ "typedef struct { _Bool b; short s; long long q; float f; double d; } Scalars;\n"
	+ "#pragma pack(push, 1)\ntypedef struct { char a; int b; } Pragma1;\n#pragma pack(pop)\n"
	+ "typedef struct { char a; int b; } AfterPop;\n";

test "a struct whose fields all translate exactly is complete" {
	const names = completeOn(EXACT_SHAPES, "linux", "x86_64");
	for (const n of ["Plain", "Nested", "ArrOfStruct", "WithEnum", "CharArr", "RefOpaque", "PlainAlias", "Scalars", "AfterPop"]) {
		assert arrayContains(names, n), n;
	}
	assert !arrayContains(names, "Pragma1");
}

const UNION_SHAPES = "typedef union { int i; double d; } U;\n"
	+ "typedef struct { int tag; U value; } HoldsUnion;\n"
	+ "typedef struct { unsigned long size; HoldsUnion color; } HoldsUnionDeep;\n"
	+ "typedef struct { char c; long q; char d; } Padded;\n"
	+ "typedef union { Padded p; int i; } PadUnion;\n"
	+ "typedef union { char c[5]; long long q; } Mixed;\n"
	+ "typedef union { PadUnion p; Mixed m; char c; } Nest;\n";

test "a union whose members all translate exactly is complete and keyed as a union" {
	const keys: string[] = [];
	translateHeaderModule(UNION_SHAPES, "header.h", [], null, null, targetFor("linux", "x86_64"), keys);
	const unions: string[] = [];
	const structs: string[] = [];
	for (const k of keys) {
		const name = k.split("\t")[1];
		if (k.endsWith(UNION_KEY_MARK)) unions.push(name);
		else structs.push(name);
	}
	assert unions.join(",") == "U,PadUnion,Mixed,Nest", unions.join(",");
	assert structs.join(",") == "HoldsUnion,HoldsUnionDeep,Padded", structs.join(",");
	assert isCompleteUnion(completeStructKey("linux-x86_64", "Mixed", ["c", "q"], ["int8[5]", "int64"]));
	assert !isCompleteStruct(completeStructKey("linux-x86_64", "Mixed", ["c", "q"], ["int8[5]", "int64"]));
}

test "a fixed C array is spelled T[N]" {
	const ms = translateHeaderModule("typedef struct { char c[5]; int (*fns[2])(int); } Arr;\n").source;
	assert ms.contains("c: int8[5];"), ms;
	assert ms.contains("fns: ((p0: int32) => int32)[2];"), ms;
}

test "a C layout msc does not reproduce leaves the struct incomplete" {
	const src = "typedef struct { int tag; union { int i; double d; }; } AnonU;\n"
		+ "typedef struct { int tag; union { int i; double d; } v; } UntaggedU;\n"
		+ "typedef union { unsigned a : 3; int b; } BitsU;\n"
		+ "typedef union __attribute__((packed)) { char a; int b; } PackedU;\n"
		+ "typedef struct { int a; struct { int b; int c; }; } AnonS;\n"
		+ "typedef struct { unsigned a : 3; unsigned b : 5; int c; } Bits;\n"
		+ "typedef struct __attribute__((packed)) { char a; int b; } Packed;\n"
		+ "typedef struct { char a; int b; } __attribute__((packed)) PackedAfter;\n"
		+ "typedef struct { char a; int b __attribute__((aligned(16))); } FieldAligned;\n"
		+ "typedef struct __attribute__((aligned(32))) { int a; } StructAligned;\n"
		+ "typedef struct { _Alignas(16) int a; } AlignasF;\n"
		+ "typedef struct { int len; char data[]; } Flex;\n"
		+ "typedef struct { void* p; int (*fn)(int); } FnPtr;\n"
		+ "typedef enum { BIG_A = 1, BIG_B = 0x100000000LL } BigE;\n"
		+ "typedef struct { BigE e; int x; } WithBigEnum;\n"
		+ "#pragma pack(4)\ntypedef struct { char a; long b; } Pack4;\n";
	assert completeOn(src, "linux", "x86_64").length == 0, completeOn(src, "linux", "x86_64").join(",");
}

test "an unrecognised pack pragma leaves every later struct incomplete" {
	const src = "#pragma pack(push, tag, 2)\n#pragma pack(pop)\ntypedef struct { char a; int b; } After;\n";
	assert completeOn(src, "linux", "x86_64").length == 0;
}

test "long double is complete only where msc maps it to its width" {
	const src = "typedef struct { long l; long double ld; } LongD;\n";
	assert arrayContains(completeOn(src, "macos", "aarch64"), "LongD");
	assert !arrayContains(completeOn(src, "linux", "x86_64"), "LongD");
}

test "no struct is complete on a 32-bit target" {
	assert completeOn("typedef struct { int a; int b; } Pair;\n", "linux", "i386").length == 0;
}

test "a declaration is located where its name is written" {
	ensureDir("/tmp/mscparse-at");
	writeFile("/tmp/mscparse-at/common.h", "typedef int Common;\nint lastProto(void);\n");
	const src = "#include \"common.h\"\n#define DECL(n) int n(void);\nDECL(made)\ntypedef struct { Common c; } Holder;\nenum { HOLD_A };\n";
	const parsed = parseHeader(src, "/tmp/mscparse-at/h.h", { target: hostTarget(), includePaths: [], macroFlags: [], readLog: null });
	const located = new HashMap<string, string>();
	for (const o of parsed.objs) located.set(o.name, `${o.file}:${o.line}`);
	const at = (name: string): string => located.get(name) ?? "missing";
	assert at("Common") == "/tmp/mscparse-at/common.h:1", at("Common");
	assert at("lastProto") == "/tmp/mscparse-at/common.h:2", at("lastProto");
	assert at("made") == "/tmp/mscparse-at/h.h:3", at("made");
	assert at("Holder") == "/tmp/mscparse-at/h.h:4", at("Holder");
	assert at("HOLD_A") == "/tmp/mscparse-at/h.h:5", at("HOLD_A");
}

test "a typedef declared again with the same type is one declaration" {
	const t = translateHeaderModule("typedef struct Res* ResRef;\ntypedef struct Res* ResRef;\nResRef make(void);\ntypedef int Num;\ntypedef int Num;\n");
	assert t.source.indexOf("export extern function make(): ResRef;") >= 0, t.source;
	assert t.source.indexOf("ResRef =") == t.source.lastIndexOf("ResRef ="), t.source;
	assert t.source.indexOf("Num =") == t.source.lastIndexOf("Num ="), t.source;
}

test "a name two included headers both declare is re-exported from the first" {
	ensureDir("/tmp/mscparse-redecl");
	writeFile("/tmp/mscparse-redecl/a.h", "#ifndef A_H\n#define A_H\ntypedef struct Res* ResRef;\nResRef makeRes(void);\n#endif\n");
	writeFile("/tmp/mscparse-redecl/b.h", "#ifndef B_H\n#define B_H\ntypedef struct Res* ResRef;\nint readRes(ResRef r);\n#endif\n");
	const t = translateHeaderModule("#include \"a.h\"\n#include \"b.h\"\n", "/tmp/mscparse-redecl/all.h");
	assert t.source.indexOf("export { ResRef } from \"/tmp/mscparse-redecl/a.h\";") >= 0, t.source;
	const b = try readFile("/tmp/mscparse-redecl/b.h") catch "";
	assert (t.includedShapes.get("/tmp/mscparse-redecl/b.h") ?? "") == translateHeaderModule(b, "/tmp/mscparse-redecl/b.h").ownShape;
}

test "an alias an includer declares leaves the declarations of the header it includes as they read alone" {
	ensureDir("/tmp/mscparse-alias");
	writeFile("/tmp/mscparse-alias/s.h", "#ifndef S_H\n#define S_H\ntypedef int Num;\ntypedef struct S { Num a; } S;\ntypedef enum { EA, EB } E;\ntypedef struct { Num b; } Anon;\nNum n(Num x);\nS mk(Anon a);\nE ek(void);\n#endif\n");
	const t = translateHeaderModule("#include \"s.h\"\ntypedef Num Id;\ntypedef S T;\ntypedef E F;\ntypedef Anon A2;\nId g(T t, F f, A2 a);\n", "/tmp/mscparse-alias/w.h");
	const s = try readFile("/tmp/mscparse-alias/s.h") catch "";
	const alone = translateHeaderModule(s, "/tmp/mscparse-alias/s.h").ownShape;
	assert (t.includedShapes.get("/tmp/mscparse-alias/s.h") ?? "") == alone, alone;
	assert alone.indexOf("export extern function n(x: Num): Num;") >= 0, alone;
	assert alone.indexOf("export extern function mk(a: Anon): S;") >= 0, alone;
	assert t.source.indexOf("export extern function g(t: S, f: E, a: Anon): Id;") >= 0, t.source;
}

test "a header declares what its own file writes and imports and re-exports what it includes" {
	ensureDir("/tmp/mscparse-split");
	writeFile("/tmp/mscparse-split/common.h", "#ifndef COMMON_H\n#define COMMON_H\ntypedef struct { int a; } Pair;\ntypedef struct Hidden* HiddenRef;\nint common(void);\n#endif\n");
	const src = "#include \"common.h\"\ntypedef struct { Pair first; } Maker;\nPair make(HiddenRef h);\n";
	const t = translateHeaderModule(src, "/tmp/mscparse-split/maker.h");
	assert t.source.indexOf("import { HiddenRef, Pair } from \"/tmp/mscparse-split/common.h\";") >= 0, t.source;
	assert t.source.indexOf("export * from \"/tmp/mscparse-split/common.h\";") >= 0, t.source;
	assert t.source.indexOf("export extern struct Maker") >= 0, t.source;
	assert t.source.indexOf("export extern function make(h: HiddenRef): Pair;") >= 0, t.source;
	assert t.source.indexOf("struct Pair") < 0, t.source;
	assert t.source.indexOf("Hidden from") < 0, t.source;
	assert t.source.indexOf("common(") < 0, t.source;
	const shape = t.includedShapes.get("/tmp/mscparse-split/common.h") ?? "";
	const common = try readFile("/tmp/mscparse-split/common.h") catch "";
	assert shape == translateHeaderModule(common, "/tmp/mscparse-split/common.h").ownShape, shape;
}
