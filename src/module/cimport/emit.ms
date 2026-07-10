// C Header Parser — proper tokenize → preprocess → parse pipeline
//
// Walks the parsed Obj[] from the cparse library and emits MetaScript
// extern declarations.

import { Obj, ObjKind } from "../cparse/obj";
import { CType, CTypeKind } from "../cparse/type";
import { defaultHostTarget } from "../cparse/target";
import { Diagnostic } from "../cparse/error";
import { parseHeader } from "./index";

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
// to itself (chibicc parse.ms:192 mutates typedefName on lookup, so the type
// behind a self-named typedef has typedefName === obj.name).
function cTypeToMs(t: CType, skipTypedef: boolean = false): string {
	if (!skipTypedef && t.typedefName !== "") {
		const mapped = mapRuntimeType(t.typedefName);
		if (mapped !== "") return mapped;
		// Opaque types from heuristic (unknown C types without #include)
		// map to unknown (void* in C) since we don't know if they're pointers or structs
		if (!t.isComplete) return "unknown";
		return t.typedefName;
	}
	return match (t.kind) {
		CTypeKind.Void => "void",
		CTypeKind.Bool => "boolean",
		CTypeKind.Char => t.isSigned ? "int8" : "uint8",
		CTypeKind.Short => t.isSigned ? "int16" : "uint16",
		CTypeKind.Int => t.isSigned ? "int32" : "uint32",
		CTypeKind.Long => t.isSigned ? "int64" : "uint64",
		CTypeKind.LongLong => t.isSigned ? "int64" : "uint64",
		CTypeKind.Float => "float32",
		CTypeKind.Double => "number",
		CTypeKind.LongDouble => "number",
		CTypeKind.Enum => {
			if (t.tagName !== "") return t.tagName;
			return "int32";
		},
		CTypeKind.Ptr => {
			if (t.base === null) return "Ptr<void>";
			// void* → Ptr<void>: raw ABI pointer. NOT `unknown` — unknown is the
			// boxed dynamic type, so an FFI handle typed unknown gets boxed on
			// module-boundary crossings and C receives a garbage pointer.
			if (t.base.kind === CTypeKind.Void) return "Ptr<void>";
			// char* → cstring
			if (t.base.kind === CTypeKind.Char) return "cstring";
			// const char* → cstring (base is Char regardless of const)
			// Function pointer → closure type
			if (t.base.kind === CTypeKind.Func) return emitFuncType(t.base);
			// Struct pointer → Ptr<StructName>, opaque (incomplete) → Ptr<void>
			if (t.base.kind === CTypeKind.Struct && t.base.tagName !== "") {
				if (!t.base.isComplete) return "Ptr<void>";
				return `Ptr<${t.base.tagName}>`;
			}
			// Other typed pointer — const pointee → Borrow<T> (read-only, accepts arr[0]
			// borrow-promotion); mutable → Ptr<T>.
			const inner = cTypeToMs(t.base);
			return t.base.isConst ? `Borrow<${inner}>` : `Ptr<${inner}>`;
		},
		CTypeKind.Array => {
			if (t.base === null) return "unknown";
			const elem = cTypeToMs(t.base);
			if (t.arrayLen >= 0) return `SizedArray<${elem}, ${t.arrayLen}>`;
			return `Span<${elem}>`;
		},
		CTypeKind.Func => emitFuncType(t),
		CTypeKind.Struct => {
			if (t.tagName !== "") return t.tagName;
			return "unknown";
		},
		CTypeKind.Union => {
			if (t.tagName !== "") return t.tagName;
			return "unknown";
		},
		_ => "unknown",
	};
}

function emitParams(t: CType): string {
	let result = "";
	for (let i = 0; i < t.params.length; i += 1) {
		if (i > 0) result = result + ", ";
		const pName = i < t.paramNames.length && t.paramNames[i] !== "" ? t.paramNames[i] : `p${i}`;
		result = result + `${pName}: ${cTypeToMs(t.params[i])}`;
	}
	return result;
}

function emitFuncType(t: CType): string {
	return "(" + emitParams(t) + ") => " + cTypeToMs(t.returnType);
}

// ===== Emit Declarations =====

function emitFunction(obj: Obj, prefix: string): string {
	const t = obj.type;
	let params = emitParams(t);
	if (t.isVariadic) {
		if (params !== "") params = params + ", ";
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
		if (m.name === "") continue;
		result = result + `\t${m.name}: ${cTypeToMs(m.type)};\n`;
	}
	result = result + "}\n";
	return result;
}

function emitEnum(objs: Obj[], enumType: CType, enumName: string, prefix: string): string {
	let result = `${prefix}extern enum ${enumName} {\n`;
	for (const obj of objs) {
		if (obj.kind === ObjKind.EnumConstant && obj.type === enumType) {
			result = result + `\t${obj.name} = ${obj.enumValue},\n`;
		}
	}
	result = result + "}\n";
	return result;
}

function emitTypedef(obj: Obj, prefix: string): string {
	const t = obj.type;
	// Struct/union typedef → emit as extern struct
	if ((t.kind === CTypeKind.Struct || t.kind === CTypeKind.Union) && t.members.length > 0) {
		return emitStructBody(obj.name, t, prefix);
	}
	// Enum typedef → handled separately via emitEnum
	if (t.kind === CTypeKind.Enum) return "";
	// Skip cTypeToMs's typedefName short-circuit — it would return obj.name
	// itself and emit `type X = X;`. Forward-declared struct whose tagName
	// matches obj.name still produces self-reference via the kind branch;
	// guard with "unknown" fallback.
	let underlying = cTypeToMs(t, true);
	if (underlying === obj.name) underlying = "unknown";
	return `${prefix}type ${obj.name} = ${underlying};\n`;
}

// ===== Main Entry Point =====

export function translateCHeader(source: string, importedNames: string[], withExport: boolean = false, headerPath: string = "header.h", includePaths: string[] = [], outDiags: Diagnostic[] = null as unknown as Diagnostic[], emittedNames: HashSet<string> = null as unknown as HashSet<string>): string {
	const prefix = withExport ? "export " : "";
	const parsed = parseHeader(source, headerPath, { target: defaultHostTarget(), includePaths, extraDefines: [] });
	if (outDiags !== null) {
		for (const d of parsed.diagnostics) outDiags.push(d);
	}

	const filterAll = importedNames.length === 0;

	// Build "wanted" set: object names whose declaration must reach the
	// emit pass. When filterAll, every parsed name is wanted. When the
	// caller passed an import list, seed with that list and transitively
	// close over type references so typedefs / struct tags / enum tags
	// referenced by emitted functions/vars/typedefs also emit. Without
	// this closure, `import { fn } from "x.h"` where `fn` takes a typedef
	// param emits the function but drops the typedef → unresolved type.
	const wantedNames = new HashSet<string>();
	if (filterAll) {
		for (const obj of parsed.objs) wantedNames.add(obj.name);
	} else {
		for (const name of importedNames) wantedNames.add(name);
		const queue: string[] = [];
		for (const name of importedNames) queue.push(name);
		const processed = new HashSet<string>();
		while (queue.length > 0) {
			const name = queue.pop();
			if (processed.has(name)) continue;
			processed.add(name);
			for (const obj of parsed.objs) {
				if (obj.name !== name) continue;
				const refs = new HashSet<string>();
				const seenTypes = new HashSet<string>();
				collectTypeRefNames(obj.type, refs, seenTypes);
				for (const r of refs) {
					if (!wantedNames.has(r)) {
						wantedNames.add(r);
						queue.push(r);
					}
				}
			}
		}
	}

	// Track which enum types we've already emitted
	const emittedEnums: string[] = [];

	let result = "";
	for (const obj of parsed.objs) {
		if (!wantedNames.has(obj.name)) continue;
		// Cross-import-site dedup: a name already emitted by an earlier import
		// in the same module (shared typedefs between sibling headers) must not
		// re-emit — the checker rejects program-wide duplicate extern decls.
		if (emittedNames !== null && obj.name !== "" && emittedNames.has(obj.name)) continue;
		const lenBefore = result.length;

		match (obj.kind) {
			ObjKind.Function => {
				result = result + emitFunction(obj, prefix);
			},
			ObjKind.Variable => {
				result = result + emitVariable(obj, prefix);
			},
			ObjKind.TypedefName => {
				// Enum typedefs: emit the enum with its constants
				if (obj.type.kind === CTypeKind.Enum) {
					const enumKey = obj.name;
					if (!arrayContains(emittedEnums, enumKey)) {
						emittedEnums.push(enumKey);
						result = result + emitEnum(parsed.objs, obj.type, obj.name, prefix);
					}
				} else {
					result = result + emitTypedef(obj, prefix);
				}
			},
			ObjKind.EnumConstant => {
				// Handled as part of enum emission
			},
			_ => {},
		};
		if (emittedNames !== null && obj.name !== "" && result.length > lenBefore) {
			emittedNames.add(obj.name);
		}
	}

	return result;
}

// Walk a CType tree and collect names of user-defined typedefs / tagged
// struct/union/enum referenced anywhere inside. Used by translateCHeader
// to compute the transitive closure for the import-name filter so a
// typedef referenced by an emitted function is not silently dropped.
// Skips primitive-mapped typedef names (int32_t, size_t, ...) since those
// resolve via mapRuntimeType and need no separate emit. Struct self-refs
// via pointer-to-self are guarded by a string-keyed seen set so the walk
// terminates.
function collectTypeRefNames(t: CType, refs: HashSet<string>, seen: HashSet<string>): void {
	if (t === null) return;
	if (t.typedefName !== "") {
		const mapped = mapRuntimeType(t.typedefName);
		// Runtime-mapped typedef (msString → string, size_t → uint64, ...):
		// user code uses the MS-native alias; do NOT walk into the C struct
		// internals or we drag implementation details (msStrPayload etc.)
		// into the emitted MS source and clash with other modules' externs.
		if (mapped !== "") return;
		refs.add(t.typedefName);
	}
	const isAggregate = t.kind === CTypeKind.Struct
		|| t.kind === CTypeKind.Union
		|| t.kind === CTypeKind.Enum;
	if (isAggregate && t.tagName !== "") {
		refs.add(t.tagName);
		const key = "tag:" + t.tagName;
		if (seen.has(key)) return;
		seen.add(key);
	}
	if (t.base !== null) collectTypeRefNames(t.base, refs, seen);
	if (t.returnType !== null) collectTypeRefNames(t.returnType, refs, seen);
	for (const p of t.params) collectTypeRefNames(p, refs, seen);
	for (const m of t.members) collectTypeRefNames(m.type, refs, seen);
}

function arrayContains(arr: string[], val: string): boolean {
	for (const item of arr) {
		if (item === val) return true;
	}
	return false;
}

// ===== Tests =====

test "emit extern function" {
	const ms = translateCHeader("extern int add(int a, int b);", [], false);
	assert ms.indexOf("extern function add") >= 0;
	assert ms.indexOf("a: int32") >= 0;
	assert ms.indexOf("b: int32") >= 0;
	assert ms.indexOf(": int32;") >= 0;
}

test "emit typedef struct" {
	const ms = translateCHeader("typedef struct { int x; int y; } Point;", [], false);
	assert ms.indexOf("extern struct Point") >= 0;
	assert ms.indexOf("x: int32") >= 0;
	assert ms.indexOf("y: int32") >= 0;
}

test "emit typedef enum" {
	const ms = translateCHeader("typedef enum { FLAG_READ = 1, FLAG_WRITE = 2 } Flags;", [], false);
	assert ms.indexOf("extern enum Flags") >= 0;
	assert ms.indexOf("FLAG_READ = 1") >= 0;
	assert ms.indexOf("FLAG_WRITE = 2") >= 0;
}

test "emit extern variable" {
	const ms = translateCHeader("extern int counter;", [], false);
	assert ms.indexOf("extern const counter: int32") >= 0;
}

test "brace initializer does not derail declaration parse" {
	const diags: Diagnostic[] = [];
	const ms = translateCHeader("static const int arr[] = {32, 64, 96};\nint after(void);", ["after"], false, "init.h", [], diags);
	assert ms.indexOf("extern function after") >= 0;
	assert diags.length === 0;
}

test "designated initializer and _Static_assert skip clean" {
	const diags: Diagnostic[] = [];
	const src = "typedef struct T { int a; } T;\n_Static_assert(1 == 1, \"ok\");\nstatic const T t = { .a = 1 };\nint after2(void);";
	const ms = translateCHeader(src, ["after2"], false, "init2.h", [], diags);
	assert ms.indexOf("extern function after2") >= 0;
	assert diags.length === 0;
}

test "emit pointer types" {
	const ms = translateCHeader("extern void *handle;\nextern const char *name;", [], false);
	assert ms.indexOf("handle: Ptr<void>") >= 0;
	assert ms.indexOf("name: cstring") >= 0;
}

test "opaque struct-pointer typedef maps to Ptr<void> not unknown" {
	const ms = translateCHeader("typedef struct Opaque* OpaqueRef;\nOpaqueRef makeIt(void);", [], false);
	assert ms.indexOf("OpaqueRef = Ptr<void>") >= 0;
	assert ms.indexOf("unknown") < 0;
}

test "emit with name filter" {
	const ms = translateCHeader("extern int foo(void);\nextern int bar(void);", ["foo"], false);
	assert ms.indexOf("foo") >= 0;
	assert ms.indexOf("bar") < 0;
}

test "emit with export prefix" {
	const ms = translateCHeader("extern int add(int a, int b);", [], true);
	assert ms.indexOf("export extern function add") >= 0;
}

test "emit variadic function" {
	const ms = translateCHeader("extern void printf(const char *fmt, ...);", [], false);
	assert ms.indexOf("printf") >= 0;
	assert ms.indexOf("fmt: cstring") >= 0;
	assert ms.indexOf("...args") >= 0;
}

test "emit type alias" {
	const ms = translateCHeader("typedef unsigned long size_t;", [], false);
	assert ms.indexOf("type size_t = uint64") >= 0;
}

test "emit function pointer param" {
	const ms = translateCHeader("typedef int (*CompareFn)(const void *, const void *);", [], false);
	assert ms.indexOf("CompareFn") >= 0;
}

test "user-defined typedef does not self-reference" {
	const ms = translateCHeader("typedef int MyId;", [], false);
	assert ms.indexOf("type MyId = int32") >= 0;
	assert ms.indexOf("type MyId = MyId") < 0;
}

test "name filter transitively keeps referenced typedef" {
	const ms = translateCHeader("typedef int MyId;\nMyId doThing(MyId x);", ["doThing"], false);
	assert ms.indexOf("extern function doThing") >= 0;
	assert ms.indexOf("type MyId = int32") >= 0;
}
