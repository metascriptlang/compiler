// JSON C Emission — generates per-type C helper functions for JSON.parse<T> / JSON.stringify<T>
//
// Called from builtinLower when @builtin("JsonParse") or @builtin("JsonStringify") is encountered.
// Emits raw C code via @emit nodes — calls runtime/core/json.h functions directly
// (msJsonParse, msJsonGet, msJsonStringify, etc.). No cross-module symbol resolution needed.
//
// Architecture: builtinLower resolves the struct type + field metadata from the checker,
// then delegates to this module for C code generation. Clean separation:
//   builtinLower.ms — AST rewriting (@builtin dispatch, call site replacement)
//   jsonEmit.ms     — C code generation (string building, type mapping)

import {
	Node, NodeKind, SourceLocation, createNode,
} from "../../ast/node";
import { Type, TypeKind } from "../../checker/types";
import { syntheticToken, makeExprStmt } from "../../transform/util";

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

// Map MetaScript TypeKind → MsJsonKind C constant (matches runtime/core/json.h).
export function fieldTypeToJsonKind(ftype: Type): number {
	if (ftype === null) return -1;
	return match (ftype.kind) {
		TypeKind.String => 3,           // MsJsonKind_String
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32
			| TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
			=> 2,                       // MsJsonKind_Number
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
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
			| TypeKind.Float32 => "->numVal",
		_ => "",
	};
}

// Whether a numeric field needs a cast from double (JSON numbers are always double).
function needsNumCast(ftype: Type): boolean {
	if (ftype === null) return false;
	return match (ftype.kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
			| TypeKind.Float32 => true,
		_ => false,
	};
}

// C builder function name for constructing MsJsonValue* from a field value.
function fieldTypeToJsonCtor(ftype: Type): string {
	if (ftype === null) return "";
	return match (ftype.kind) {
		TypeKind.String => "msJsonNewString",
		TypeKind.Number | TypeKind.Float64 => "msJsonNewNumber",
		TypeKind.Float32 => "msJsonNewNumber",
		TypeKind.Boolean => "msJsonNewBool",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
			=> "msJsonNewNumber",
		_ => "",
	};
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
// Calls msJsonParse + msJsonGet from runtime/core/json.h.
// Returns null if any field type is unsupported.
export function generateJsonParseC(
	helperName: string, typeName: string, structType: Type, loc: SourceLocation
): Node {
	const fieldNames = structType.typeNames;
	const fieldTypes = structType.typeChildren;
	if (fieldNames === null || fieldTypes === null) return null as unknown as Node;

	// Validate all fields are supported
	let fi = 0;
	while (fi < fieldNames.length) {
		if (fieldTypeToJsonKind(fieldTypes[fi]) < 0) return null as unknown as Node;
		fi = fi + 1;
	}

	const resultCType = "msResult_" + typeName + "_msString";

	// Include json runtime header (INCLUDESECTION routes it to #include area)
	let c = "/*INCLUDESECTION*/#include \"core/json.h\"\n";
	c = c + "static " + resultCType + " " + helperName + "(msString input) {\n";
	c = c + "  " + resultCType + " __r; memset(&__r, 0, sizeof(__r));\n";
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
		const fVar = "__f" + fi.toString();

		c = c + "  MsJsonValue* " + fVar + " = msJsonGet(__jv, msStringNew(\"" + fname + "\", " + fname.length.toString() + "));\n";
		c = c + "  if (!" + fVar + " || " + fVar + "->kind != " + jsonKind.toString() + ") {\n";

		const errMsg = "field '" + fname + "': type mismatch";
		c = c + "    msJsonFree(__jv);\n";
		c = c + "    __r.ok = MS_FALSE; __r.error = msStringNew(\"" + errMsg + "\", " + errMsg.length.toString() + ");\n";
		c = c + "    return __r;\n";
		c = c + "  }\n";

		if (needsNumCast(ftype)) {
			c = c + "  __r.value." + fname + " = (" + cFieldType + ")" + fVar + "->numVal;\n";
		} else {
			c = c + "  __r.value." + fname + " = " + fVar + jsonCAccessor(ftype) + ";\n";
			// String fields: incref before msJsonFree releases the JSON tree
			if (ftype.kind === TypeKind.String) {
				c = c + "  msStringIncref(__r.value." + fname + ");\n";
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
// Calls msJsonNewObject + msJsonSet + msJsonStringify from runtime/core/json.h.
// Returns null if any field type is unsupported.
export function generateJsonStringifyC(
	helperName: string, typeName: string, structType: Type, loc: SourceLocation
): Node {
	const fieldNames = structType.typeNames;
	const fieldTypes = structType.typeChildren;
	if (fieldNames === null || fieldTypes === null) return null as unknown as Node;

	// Validate all fields are supported
	let fi = 0;
	while (fi < fieldNames.length) {
		if (fieldTypeToJsonCtor(fieldTypes[fi]) === "") return null as unknown as Node;
		fi = fi + 1;
	}

	// Include json runtime header
	let c = "/*INCLUDESECTION*/#include \"core/json.h\"\n";
	c = c + "static msString " + helperName + "(" + typeName + " value) {\n";
	c = c + "  MsJsonValue* __o = msJsonNewObject();\n";

	// Per-field: msJsonSet(__o, "fieldName", msJsonNewString/Number/Bool(value.field))
	fi = 0;
	while (fi < fieldNames.length) {
		const fname = fieldNames[fi];
		const ftype = fieldTypes[fi];
		const ctorName = fieldTypeToJsonCtor(ftype);
		const cFieldType = fieldTypeToCType(ftype);

		// Integer/float fields need cast to double for msJsonNewNumber
		let valueExpr = "value." + fname;
		if (needsNumCast(ftype)) {
			valueExpr = "(double)" + valueExpr;
		}

		c = c + "  msJsonSet(__o, msStringNew(\"" + fname + "\", " + fname.length.toString() + "), " + ctorName + "(" + valueExpr + "));\n";

		fi = fi + 1;
	}

	c = c + "  msString __result = msJsonStringify(__o);\n";
	c = c + "  msJsonFree(__o);\n";
	c = c + "  return __result;\n";
	c = c + "}\n";

	return makeEmitNode(c, loc);
}

// ===== JSON.stringify<T> (Colored) — for console.log debug format =====

// Same as generateJsonStringifyC but uses msJsonStringifyColored (Go-style, ANSI colors).
// Prefixes output with type name: "Person { ... }" or "class Person { ... }".
// Used by echoCoerceArg for console.log(structValue).
export function generateJsonStringifyColoredC(
	helperName: string, typeName: string, structType: Type, isClass: boolean, loc: SourceLocation
): Node {
	const fieldNames = structType.typeNames;
	const fieldTypes = structType.typeChildren;
	if (fieldNames === null || fieldTypes === null) return null as unknown as Node;

	let fi = 0;
	while (fi < fieldNames.length) {
		if (fieldTypeToJsonCtor(fieldTypes[fi]) === "") return null as unknown as Node;
		fi = fi + 1;
	}

	// Build type prefix with ANSI color: blue for interface, green for class
	// "class Person " or "Person " — colored at runtime via msColorsEnabled()
	const plainPrefix = isClass ? "class " + typeName + " " : typeName + " ";
	const plainLen = plainPrefix.length.toString();
	// ANSI: \x1b[34m = blue (interface), \x1b[32m = green (class), \x1b[0m = reset
	const colorCode = isClass ? "\\x1b[32m" : "\\x1b[34m";

	let c = "/*INCLUDESECTION*/#include \"core/json.h\"\n";
	c = c + "static msString " + helperName + "(" + typeName + " value) {\n";
	c = c + "  MsJsonValue* __o = msJsonNewObject();\n";

	fi = 0;
	while (fi < fieldNames.length) {
		const fname = fieldNames[fi];
		const ftype = fieldTypes[fi];
		const ctorName = fieldTypeToJsonCtor(ftype);

		let valueExpr = "value." + fname;
		if (needsNumCast(ftype)) {
			valueExpr = "(double)" + valueExpr;
		}

		c = c + "  msJsonSet(__o, msStringNew(\"" + fname + "\", " + fname.length.toString() + "), " + ctorName + "(" + valueExpr + "));\n";
		fi = fi + 1;
	}

	c = c + "  msString __body = msJsonStringifyColored(__o);\n";
	c = c + "  msJsonFree(__o);\n";
	// Build colored prefix at runtime: color + "class TypeName " + reset + body
	c = c + "  char __pbuf[256];\n";
	c = c + "  int __plen;\n";
	c = c + "  if (msColorsEnabled()) {\n";
	c = c + "    __plen = snprintf(__pbuf, sizeof(__pbuf), \"" + colorCode + "" + plainPrefix + "\\x1b[0m\");\n";
	c = c + "  } else {\n";
	c = c + "    __plen = snprintf(__pbuf, sizeof(__pbuf), \"" + plainPrefix + "\");\n";
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
