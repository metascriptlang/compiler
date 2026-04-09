// C Header Parser — proper tokenize → preprocess → parse pipeline
//
// Replaces the previous regex-based scanner with the chibicc-ported
// cparse library at src/cparse/. Walks the parsed Obj[] and emits
// MetaScript extern declarations.

import { tokenizeFile } from "../cparse/tokenize";
import { preprocess } from "../cparse/preprocess";
import { parseTranslationUnit } from "../cparse/parse";
import { Obj, ObjKind } from "../cparse/obj";
import { CType, CTypeKind } from "../cparse/type";
import { defaultHostTarget } from "../cparse/target";

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

function cTypeToMs(t: CType): string {
	// Check typedef name first — handles anonymous struct typedefs like msString
	if (t.typedefName !== "") {
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
			if (t.base === null) return "unknown";
			// void* → unknown (opaque pointer)
			if (t.base.kind === CTypeKind.Void) return "unknown";
			// char* → cstring
			if (t.base.kind === CTypeKind.Char) return "cstring";
			// const char* → cstring (base is Char regardless of const)
			// Function pointer → closure type
			if (t.base.kind === CTypeKind.Func) return emitFuncType(t.base);
			// Struct pointer → Ptr<StructName> (or unknown if opaque)
			if (t.base.kind === CTypeKind.Struct && t.base.tagName !== "") {
				if (!t.base.isComplete) return "unknown";
				return `Ptr<${t.base.tagName}>`;
			}
			// Other typed pointer
			const inner = cTypeToMs(t.base);
			return `Ptr<${inner}>`;
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
	// Simple type alias
	return `${prefix}type ${obj.name} = ${cTypeToMs(t)};\n`;
}

// ===== Main Entry Point =====

export function translateCHeader(source: string, importedNames: string[], withExport: boolean = false, headerPath: string = "header.h", includePaths: string[] = []): string {
	const prefix = withExport ? "export " : "";
	const target = defaultHostTarget();
	const tokens = tokenizeFile(source, headerPath);
	const pp = preprocess(tokens.head, target, includePaths);
	const parsed = parseTranslationUnit(pp.head, target);

	// Build name filter set
	const filterAll = importedNames.length === 0;

	// Track which enum types we've already emitted
	const emittedEnums: string[] = [];

	let result = "";
	for (const obj of parsed.objs) {
		// Name filtering: skip declarations not in the import list
		if (!filterAll && !nameMatches(obj, importedNames)) continue;

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
	}

	return result;
}

function nameMatches(obj: Obj, importedNames: string[]): boolean {
	for (const name of importedNames) {
		if (obj.name === name) return true;
	}
	return false;
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

test "emit pointer types" {
	const ms = translateCHeader("extern void *handle;\nextern const char *name;", [], false);
	assert ms.indexOf("handle: unknown") >= 0;
	assert ms.indexOf("name: cstring") >= 0;
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
