// JSON C Emission — generates per-type C helper functions for JSON.parse<T> / JSON.stringify<T>
//
// Called from builtinLower when @builtin("JsonParse") or @builtin("JsonStringify") is encountered.
// Emits raw C code via @emit nodes — calls runtime/std/core/json/native.h functions directly
// (msJsonParse, msJsonGet, msJsonStringify, etc.). No cross-module symbol resolution needed.
//
// Architecture: builtinLower resolves the struct type + field metadata from the checker,
// then delegates to this module for C code generation. Clean separation:
//   builtinLower.ms — AST rewriting (@builtin dispatch, call site replacement)
//   json.ms         — C code generation (string building, type mapping)

import { Node, NodeKind, SourceLocation, createNode, Type, TypeKind } from "../../ast/node";
import { syntheticToken, makeExprStmt } from "../../transform/util";
import { TransformContext, hasEmitted } from "../../transform/context";

// ===== Shared Helpers =====

// Register a helper function (dedup + emit). Returns true if newly registered.
export function registerHelper(name: string, emitNode: Node, ctx: TransformContext): void {
	ctx.emittedHelpers.push(name);
	ctx.pendingDecls.push(emitNode);
}

// Ensure json.h is included exactly once.
export function ensureJsonInclude(ctx: TransformContext, loc: SourceLocation): void {
	if (!hasEmitted(ctx, "__jsonInclude")) {
		ctx.emittedHelpers.push("__jsonInclude");
		ctx.pendingDecls.push(makeEmitNode("/*INCLUDESECTION*/#include \"std/core/json/native.h\"\n", loc));
	}
}

// ===== Type Mapping =====

// Map MetaScript TypeKind → C type string for struct field emission.
export function fieldTypeToCType(ftype: Type): string {
	if (ftype === null) return "void*";
	return match (ftype.kind) {
		TypeKind.String => "msString",
		TypeKind.Number | TypeKind.Float64 => "double",
		TypeKind.Float32 => "float",
		TypeKind.Boolean => "MS_BOOL",
		TypeKind.Int8 => "int8_t",
		TypeKind.Int16 => "int16_t",
		TypeKind.Int32 => "int32_t",
		TypeKind.Int64 => "int64_t",
		TypeKind.Uint8 => "uint8_t",
		TypeKind.Uint16 => "uint16_t",
		TypeKind.Uint32 => "uint32_t",
		TypeKind.Uint64 => "uint64_t",
		_ => "void*",
	};
}

// Map MetaScript TypeKind → MsJsonKind C constant (matches runtime/std/core/json/native.h).
export function fieldTypeToJsonKind(ftype: Type): number {
	if (ftype === null) return -1;
	return match (ftype.kind) {
		TypeKind.String => 3,           // MsJsonKind_String
		TypeKind.Number
			| TypeKind.Float64
			| TypeKind.Float32
			| TypeKind.Int8
			| TypeKind.Int16
			| TypeKind.Int32
			| TypeKind.Int64
			| TypeKind.Uint8
			| TypeKind.Uint16
			| TypeKind.Uint32
			| TypeKind.Uint64 => 2,       // MsJsonKind_Number
		TypeKind.Boolean => 1,          // MsJsonKind_Bool
		_ => -1,
	};
}

// C accessor suffix on MsJsonValue* for the given field type.
function jsonCAccessor(ftype: Type): string {
	if (ftype === null) return "";
	return match (ftype.kind) {
		TypeKind.String => "->strVal",
		TypeKind.Number | TypeKind.Float64 => "->numVal",
		TypeKind.Boolean => "->boolVal",
		TypeKind.Int8
			| TypeKind.Int16
			| TypeKind.Int32
			| TypeKind.Int64
			| TypeKind.Uint8
			| TypeKind.Uint16
			| TypeKind.Uint32
			| TypeKind.Uint64
			| TypeKind.Float32 => "->numVal",
		_ => "",
	};
}

// Whether a numeric field needs a cast from double (JSON numbers are always double).
export function needsNumCast(ftype: Type): boolean {
	if (ftype === null) return false;
	return match (ftype.kind) {
		TypeKind.Int8
			| TypeKind.Int16
			| TypeKind.Int32
			| TypeKind.Int64
			| TypeKind.Uint8
			| TypeKind.Uint16
			| TypeKind.Uint32
			| TypeKind.Uint64
			| TypeKind.Float32 => true,
		_ => false,
	};
}

// C builder function name for constructing MsJsonValue* from a field value.
// Map a primitive field type to its MsJsonValue constructor name.
// Struct, Array, Enum, Tuple are handled inline in emitJsonSetFields.
export function fieldTypeToJsonCtor(ftype: Type): string {
	if (ftype === null) return "";
	return match (ftype.kind) {
		TypeKind.String => "msJsonNewString",
		TypeKind.Number | TypeKind.Float64 => "msJsonNewNumber",
		TypeKind.Float32 => "msJsonNewNumber",
		TypeKind.Boolean => "msJsonNewBool",
		TypeKind.Int8
			| TypeKind.Int16
			| TypeKind.Int32
			| TypeKind.Int64
			| TypeKind.Uint8
			| TypeKind.Uint16
			| TypeKind.Uint32
			| TypeKind.Uint64 => "msJsonNewNumber",
		TypeKind.Enum => "msJsonNewNumber",  // enums are integers in C
		_ => "",
	};
}

// Check if a field type is supported for JSON serialization.
// Reference parity: storeAny handles object, array, enum, tuple, and all primitives.
function isFieldSupported(ftype: Type): boolean {
	if (ftype === null) return false;
	if (ftype.kind === TypeKind.Struct) return ftype.typeName !== "";
	if (ftype.kind === TypeKind.Array) return ftype.typeReturn !== null && isFieldSupported(ftype.typeReturn);
	if (ftype.kind === TypeKind.Tuple) return ftype.typeChildren !== null;
	if (ftype.kind === TypeKind.Enum) return true;
	return fieldTypeToJsonCtor(ftype) !== "";
}

// Validate all struct fields are supported for JSON stringify/colored emission.
function allFieldsSupported(fieldTypes: Type[]): boolean {
	for (const ft of fieldTypes) {
		if (!isFieldSupported(ft)) return false;
	}
	return true;
}

// Generate __jsonToValue_<type> helpers for all nested struct types (recursive, depth-first).
// Returns C code that must be emitted BEFORE the parent helper.
// Reference parity: storeAny recursively dispatches on object kind for nested fields.
// Get a stable key for an array element type (for dedup and naming).
export function arrayElemKey(elemType: Type): string {
	if (elemType === null) return "unknown";
	if (elemType.typeName !== "") return elemType.typeName;
	return match (elemType.kind) {
		TypeKind.String => "string",
		TypeKind.Number | TypeKind.Float64 => "number",
		TypeKind.Boolean => "boolean",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		_ => "unknown",
	};
}

// Map element TypeKind to C array type name.
export function arrayCType(elemType: Type): string {
	if (elemType === null) return "msRefArray";
	return match (elemType.kind) {
		TypeKind.String => "msStringArray",
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "msNumberArray",
		TypeKind.Boolean => "msNumberArray",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => "msNumberArray",
		_ => "msRefArray",
	};
}

export function emitNestedToValueHelpers(fieldTypes: Type[], emitted: Set<string>): string {
	let c = "";
	for (const ft of fieldTypes) {
		if (ft === null) continue;
		// Nested struct: generate __jsonToValue_ helper
		if (ft.kind === TypeKind.Struct && ft.typeName !== "") {
			if (emitted.has(ft.typeName)) continue;
			emitted.add(ft.typeName);
			if (ft.typeChildren !== null) {
				c = c + emitNestedToValueHelpers(ft.typeChildren, emitted);
			}
			// #ifndef guard: reference parity (declaredThings per-module dedup).
			// Multiple JSON.stringify<T> calls sharing the same nested type
			// each emit this helper — C preprocessor deduplicates.
			const guard = `__jsonToValue_${ft.typeName}_DEFINED`;
			c = c + `#ifndef ${guard}\n#define ${guard}\n`;
			c = c + `static MsJsonValue* __jsonToValue_${ft.typeName}(${ft.typeName} value) {\n`;
			c = c + "  MsJsonValue* __o = msJsonNewObject();\n";
			c = c + emitJsonSetFields(ft.typeNames, ft.typeChildren);
			c = c + "  return __o;\n";
			c = c + "}\n#endif\n";
		}
		// Array: generate __jsonArrayToValue_ helper that iterates elements.
		// Reference parity: array/sequence iterates a[i], recurses storeAny.
		if (ft.kind === TypeKind.Array && ft.typeReturn !== null) {
			const elemType = ft.typeReturn;
			if (elemType.kind === TypeKind.Struct) {
				c = c + emitNestedToValueHelpers([elemType], emitted);
			}
			const elemKey = arrayElemKey(elemType);
			const arrHelperName = "__jsonArrayToValue_" + elemKey;
			if (!emitted.has(arrHelperName)) {
				emitted.add(arrHelperName);
				const arrCType = arrayCType(elemType);
				const elemAccess = arrCType === "msRefArray" ? "msArrayAccess(arr, __i)" : "arr.p->data[__i]";
				const elemConvert = emitValueToJson(elemAccess, elemType);
				const arrGuard = arrHelperName + "_DEFINED";
				c = c + `#ifndef ${arrGuard}\n#define ${arrGuard}\n`;
				c = c + `static MsJsonValue* ${arrHelperName}(${arrCType} arr) {\n`;
				c = c + "  MsJsonValue* __a = msJsonNewArray();\n";
				c = c + "  for (int64_t __i = 0; __i < arr.len; __i++) {\n";
				c = c + `    msJsonPush(__a, ${elemConvert});\n`;
				c = c + "  }\n";
				c = c + "  return __a;\n";
				c = c + "}\n#endif\n";
			}
		}
		// Tuple: recurse into children
		if (ft.kind === TypeKind.Tuple && ft.typeChildren !== null) {
			c = c + emitNestedToValueHelpers(ft.typeChildren, emitted);
		}
	}
	return c;
}

// Emit per-field msJsonSet calls for a struct value → MsJsonValue* object.
// Primitives: msJsonNewString/Number/Bool. Nested structs: __jsonToValue_<type>.
// Reference parity: storeAny dispatches per field, recursing for object kind.
// Emit C code to convert a single value to MsJsonValue*, given its type.
// Used by emitJsonSetFields for each field and by array element emission.
export function emitValueToJson(valueExpr: string, ftype: Type): string {
	if (ftype === null) return `msJsonNewNull()`;
	// Nested struct → call __jsonToValue_ helper
	if (ftype.kind === TypeKind.Struct && ftype.typeName !== "") {
		return `__jsonToValue_${ftype.typeName}(${valueExpr})`;
	}
	// Array → call generated array helper
	// Reference parity: array iterates a[i], recurses storeAny
	if (ftype.kind === TypeKind.Array && ftype.typeReturn !== null) {
		return `__jsonArrayToValue_${arrayElemKey(ftype.typeReturn)}(${valueExpr})`;
	}
	// Tuple → build JSON array from tuple fields
	// Reference parity: tuple same as object (keyed), but we serialize as positional array
	if (ftype.kind === TypeKind.Tuple && ftype.typeChildren !== null) {
		return `msJsonNewNull()`; // TODO: tuple serialization needs per-type helper
	}
	// Primitive types (number, string, bool, enum, integers)
	if (needsNumCast(ftype)) return `msJsonNewNumber((double)${valueExpr})`;
	const ctor = fieldTypeToJsonCtor(ftype);
	if (ctor !== "") return `${ctor}(${valueExpr})`;
	return `msJsonNewNull()`;
}

function emitJsonSetFields(fieldNames: string[], fieldTypes: Type[]): string {
	let c = "";
	let fi = 0;
	while (fi < fieldNames.length) {
		const fname = fieldNames[fi];
		const ftype = fieldTypes[fi];
		const key = `msStringNew("${fname}", ${fname.length})`;
		c = c + `  msJsonSet(__o, ${key}, ${emitValueToJson("value." + fname, ftype)});\n`;
		fi = fi + 1;
	}
	return c;
}

// ===== @emit Node Helper =====

// Create an @emit ExprStmt node that injects raw C code into the output.
export function makeEmitNode(code: string, loc: SourceLocation): Node {
	const strNode = createNode(NodeKind.StringLiteral, { value: code }, syntheticToken(loc));
	const macroNode = createNode(NodeKind.MacroInvocation, { macroName: "emit", macroArgs: [strNode] }, syntheticToken(loc));
	return makeExprStmt(macroNode, loc);
}

// ===== JSON.parse<T> — C Helper Generation =====

// Generate a C function: static msResult_T_msString __jsonParse_T(msString input) { ... }
// Calls msJsonParse + msJsonGet from runtime/std/core/json/native.h.
// Returns null if any field type is unsupported.
export function generateJsonParseC(helperName: string, typeName: string, structType: Type, loc: SourceLocation): Node {
	const fieldNames = structType.typeNames;
	const fieldTypes = structType.typeChildren;
	if (fieldNames === null || fieldTypes === null) return null as unknown as Node;

	// Validate all fields are supported
	let fi = 0;
	while (fi < fieldNames.length) {
		if (fieldTypeToJsonKind(fieldTypes[fi]) < 0) return null as unknown as Node;
		fi = fi + 1;
	}

	const resultCType = `msResult_${typeName}_msString`;

	// Include json runtime header (INCLUDESECTION routes it to #include area)
	let c = "";
	c = c + `static ${resultCType} ${helperName}(msString input) {\n`;
	c = c + `  ${resultCType} __r; memset(&__r, 0, sizeof(__r));\n`;
	c = c + "  MsJsonValue* __jv = msJsonParse(input);\n";
	c = c + "  if (!__jv || __jv->kind != MsJsonKind_Object) {\n";
	c = c + "    msJsonFree(__jv);\n";
	c = c + "    __r.ok = MS_FALSE; __r.error = msStringNew(\"expected object\", 15);\n";
	c = c + "    return __r;\n";
	c = c + "  }\n";

	// Per-field extraction
	fi = 0;
	while (fi < fieldNames.length) {
		const fname = fieldNames[fi];
		const ftype = fieldTypes[fi];
		const jsonKind = fieldTypeToJsonKind(ftype);
		const cFieldType = fieldTypeToCType(ftype);
		const fVar = `__f${fi.toString()}`;

		c = c + `  MsJsonValue* ${fVar} = msJsonGet(__jv, msStringNew("${fname}", ${fname.length.toString()}));\n`;
		c = c + `  if (!${fVar} || ${fVar}->kind != ${jsonKind.toString()}) {\n`;

		const errMsg = `field '${fname}': type mismatch`;
		c = c + "    msJsonFree(__jv);\n";
		c = c + `    __r.ok = MS_FALSE; __r.error = msStringNew("${errMsg}", ${errMsg.length.toString()});\n`;
		c = c + "    return __r;\n";
		c = c + "  }\n";

		if (needsNumCast(ftype)) {
			c = c + `  __r.value.${fname} = (${cFieldType})${fVar}->numVal;\n`;
		} else {
			c = c + `  __r.value.${fname} = ${fVar}${jsonCAccessor(ftype)};\n`;
			// String fields: incref before msJsonFree releases the JSON tree
			if (ftype.kind === TypeKind.String) {
				c = c + `  msStringIncref(__r.value.${fname});\n`;
			}
		}

		fi = fi + 1;
	}

	c = c + "  msJsonFree(__jv);\n";
	c = c + "  __r.ok = MS_TRUE;\n";
	c = c + "  return __r;\n";
	c = c + "}\n";

	return makeEmitNode(c, loc);
}

// ===== JSON.stringify<T> — C Helper Generation =====

// Generate a C function: static msString __jsonStringify_T(T value) { ... }
// Calls msJsonNewObject + msJsonSet + msJsonStringify from runtime/std/core/json/native.h.
// Returns null if any field type is unsupported.
export function generateJsonStringifyC(
	helperName: string, typeName: string, structType: Type, loc: SourceLocation
): Node {
	const fieldNames = structType.typeNames;
	const fieldTypes = structType.typeChildren;
	if (fieldNames === null || fieldTypes === null) return null as unknown as Node;

	if (!allFieldsSupported(fieldTypes)) return null as unknown as Node;

	let c = "";

	// Emit __jsonToValue_ helpers for nested struct fields (depth-first).
	// These must appear before the parent so the C compiler sees their declarations.
	const emitted: Set<string> = new Set<string>();
	c = c + emitNestedToValueHelpers(fieldTypes, emitted);

	// Top-level: builds MsJsonValue* tree, stringifies, frees.
	c = c + `static msString ${helperName}(${typeName} value) {\n`;
	c = c + "  MsJsonValue* __o = msJsonNewObject();\n";
	c = c + emitJsonSetFields(fieldNames, fieldTypes);
	c = c + "  msString __result = msJsonStringify(__o);\n";
	c = c + "  msJsonFree(__o);\n";
	c = c + "  return __result;\n";
	c = c + "}\n";

	return makeEmitNode(c, loc);
}

// ===== Debug Stringify (colored console.log output) =====

// Generate a C function: static msString __jsonDbg_T(T value) { ... }
// Same as JSON.stringify<T> but uses msJsonStringifyColored (Go-style, ANSI colors).
// Used by echoCoerceArg for console.log(structValue).
//
// displayName: prefix shown before { ... } (e.g., "Person ", "class Person ", "Anon ")
// colorCode: ANSI escape for the prefix (e.g., "\\x1b[34m" blue, "\\x1b[32m" green, "\\x1b[36m" cyan)
export function generateJsonStringifyColoredC(
	helperName: string, typeName: string, structType: Type, displayName: string, colorCode: string, loc: SourceLocation
): Node {
	const fieldNames = structType.typeNames;
	const fieldTypes = structType.typeChildren;
	if (fieldNames === null || fieldTypes === null) return null as unknown as Node;

	if (!allFieldsSupported(fieldTypes)) return null as unknown as Node;

	let c = "";

	// Emit __jsonToValue_ helpers for nested struct fields (depth-first).
	const emittedDbg: Set<string> = new Set<string>();
	c = c + emitNestedToValueHelpers(fieldTypes, emittedDbg);

	c = c + `static msString ${helperName}(${typeName} value) {\n`;
	c = c + "  MsJsonValue* __o = msJsonNewObject();\n";
	c = c + emitJsonSetFields(fieldNames, fieldTypes);
	c = c + "  msString __body = msJsonStringifyColored(__o);\n";
	c = c + "  msJsonFree(__o);\n";
	// Build colored prefix at runtime: color + "class TypeName " + reset + body
	c = c + "  char __pbuf[256];\n";
	c = c + "  int __plen;\n";
	c = c + "  if (msColorsEnabled()) {\n";
	c = c + `    __plen = snprintf(__pbuf, sizeof(__pbuf), "${colorCode}${displayName}\\x1b[0m");\n`;
	c = c + "  } else {\n";
	c = c + `    __plen = snprintf(__pbuf, sizeof(__pbuf), "${displayName}");\n`;
	c = c + "  }\n";
	c = c + "  msString __prefix = msStringNew(__pbuf, __plen);\n";
	c = c + "  msString __result = msStringConcat(__prefix, __body);\n";
	c = c + "  return __result;\n";
	c = c + "}\n";

	return makeEmitNode(c, loc);
}

// ===== Tests =====

import { stmtCountAfter } from "../../transform/testUtil";

test "fieldTypeToCType string" {
	const t: Type = { kind: TypeKind.String, typeName: "", typeNames: null as unknown as string[], typeChildren: null as unknown as Type[], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert fieldTypeToCType(t) === "msString";
}

test "fieldTypeToCType int32" {
	const t: Type = { kind: TypeKind.Int32, typeName: "", typeNames: null as unknown as string[], typeChildren: null as unknown as Type[], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert fieldTypeToCType(t) === "int32_t";
}

test "fieldTypeToJsonKind string" {
	const t: Type = { kind: TypeKind.String, typeName: "", typeNames: null as unknown as string[], typeChildren: null as unknown as Type[], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert fieldTypeToJsonKind(t) === 3;
}

test "fieldTypeToJsonKind number" {
	const t: Type = { kind: TypeKind.Number, typeName: "", typeNames: null as unknown as string[], typeChildren: null as unknown as Type[], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert fieldTypeToJsonKind(t) === 2;
}

test "fieldTypeToJsonKind unsupported" {
	const t: Type = { kind: TypeKind.Void, typeName: "", typeNames: null as unknown as string[], typeChildren: null as unknown as Type[], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert fieldTypeToJsonKind(t) === -1;
}

test "needsNumCast int32" {
	const t: Type = { kind: TypeKind.Int32, typeName: "", typeNames: null as unknown as string[], typeChildren: null as unknown as Type[], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert needsNumCast(t);
}

test "needsNumCast double" {
	const t: Type = { kind: TypeKind.Number, typeName: "", typeNames: null as unknown as string[], typeChildren: null as unknown as Type[], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert !needsNumCast(t);
}
