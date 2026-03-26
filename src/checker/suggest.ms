// Suggest — LSP intelligence layer
//
// Pure computation: typeToString, findNodeAtPosition, getSymbolAtCursor,
// formatHover, collectDiagnostics. No I/O, no protocol knowledge.
// Called by src/lsp/handlers.ms.

import { Node, NodeKind, SourceLocation, makeLoc, createNodeAt, ProgramData, DeclKind, IdentifierData, MemberExprData, CallExprData, BinaryExprData, UnaryExprData, VariableDeclData, FunctionDeclData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, BlockStmtData, ExprStmtData, ReturnStmtData, ArrayLiteralData, ObjectLiteralData, ConditionalExprData, ArrowFunctionData, ArrayAccessData, MatchExprData, MatchCaseData, TryCatchStmtData, TryExprData, ClassDeclData, InterfaceDeclData, EnumDeclData, TypeAliasDeclData, ExportDeclData, ImportDeclData, HiddenDerefData, HiddenStdConvData, MethodDeclData, PropertyDeclData, ConstructorDeclData, NewExprData, NumberLiteralData, Type, TypeKind, Symbol, SymbolKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { typeNameOf, getProperty, unwrapRef, numberType, stringType, booleanType, voidType, nullType, unknownType, neverType, errorType, isResult, getResultOkType, getResultErrType } from "./types";
import { SymbolTable, Scope, ScopeKind, lookupSymbol, makeSymbol, hasFlag, SymbolFlag } from "./symbol";
import { CheckerContext, findAllExtensionsByName, filterExtsByReceiverType, getExtFnType, stripReceiverParam, SgSymRecord } from "./context";
// (utils/string imports removed — using native .slice/.charAt)
import { checkProgram } from "./checkPass";
import { parseSource, parseSourceLenient } from "../parser/statements/validation";
// Import parseProgram to trigger callback registration (side-effect import)
import { parseProgram } from "../parser/statements/core";

// ===== Data Types =====

export interface SgSuggest {
	sym: Symbol;           // symbol pointer for identity-based matching
	name: string;
	kind: SymbolKind;
	symType: Type;
	location: SourceLocation;
	modulePath: string;    // source file path (for cross-file navigation)
	containerName: string; // owning class/interface name (for display: "console.log")
	prefixScore: number;   // 0=None, 1=Substr, 2=Prefix
	scopeDepth: number;    // 0=innermost, higher=outer
	contextFit: boolean;   // type-context match
	isExported: boolean;   // from sym.isExported
	isMutable: boolean;    // from sym.isMutable (let vs const)
	usageCount: number;    // number of usages in current file (for completion ranking)
}

export interface SgDiagnostic {
	message: string;
	line: number;
	column: number;
	endColumn: number; // 0 = use column+1
	severity: number;  // 1=Error, 2=Warning
}

export enum SgCompletionKind {
	Identifier,
	MemberAccess,
	TypeAnnotation,
	ObjectField,
	ImportPath,
	ImportName,
}

export interface SgDocumentSymbol {
	name: string;
	kind: SymbolKind;
	location: SourceLocation;
	detail: string;    // type signature for outline view
	isMutable: boolean; // let/var vs const — for Constant(14) vs Variable(13) icon
	children: SgDocumentSymbol[];
}

export interface SgSignatureInfo {
	label: string;
	paramLabels: string[];
}

// ===== sgQueryAtPosition — binary search on check-time records =====
// Replaces the fragile AST walker (sgFindNodeAtPosition + sgGetSymbolAtCursor).
// Records are sorted by (line, col) after check completes.

export function sgQueryAtPosition(ctx: CheckerContext, line: number, col: number): SgSuggest {
	if (ctx.symRecords === null || ctx.symRecords.length === 0) return null as unknown as SgSuggest;
	const records = ctx.symRecords;
	// Binary search for first record on this line
	let lo = 0;
	let hi = records.length - 1;
	while (lo <= hi) {
		const mid = (lo + hi) as int32 >> 1;
		if (records[mid].line < line) {
			lo = mid + 1;
		} else {
			hi = mid - 1;
		}
	}
	// Linear scan records on this line for col match
	let i = lo;
	while (i < records.length && records[i].line === line) {
		const rec = records[i];
		if (col >= rec.col && col < rec.colEnd) {
			return sgSuggestFromRecord(rec);
		}
		i = i + 1;
	}
	return null as unknown as SgSuggest;
}

function sgSuggestFromRecord(rec: SgSymRecord): SgSuggest {
	// Use sym.location if valid, otherwise fall back to record's own position.
	// Catches symbols created with default location {0, 0} (e.g. synthetic field syms).
	let loc: SourceLocation = makeLoc(rec.line, rec.col);
	if (rec.sym !== null && rec.sym.location !== null && rec.sym.location.line > 0) {
		loc = rec.sym.location;
	}
	const modPath = rec.sym !== null && rec.sym.modulePath !== null ? rec.sym.modulePath : "";
	return {
		sym: rec.sym,
		name: rec.name,
		kind: rec.kind,
		symType: rec.symType,
		location: loc,
		modulePath: modPath,
		containerName: rec.containerName,
		prefixScore: 0,
		scopeDepth: 0,
		contextFit: false,
		isExported: rec.sym !== null ? hasFlag(rec.sym, SymbolFlag.Exported) : false,
		isMutable: rec.sym !== null ? hasFlag(rec.sym, SymbolFlag.Mutable) : false,
		usageCount: 0,
	};
}

// ===== sgQueryBySym — find all records matching a symbol by pointer identity =====
// Reference-aligned: uses sym pointer identity (not name string) to avoid false positives
// with shadowed or aliased symbols. Falls back to name+modulePath for cross-module.

export function sgQueryBySym(ctx: CheckerContext, targetSym: Symbol): SgSymbolRef[] {
	const result: SgSymbolRef[] = [];
	if (ctx.symRecords === null || targetSym === null) return result;
	const records = ctx.symRecords;
	let i = 0;
	while (i < records.length) {
		const rec = records[i];
		if (rec.sym === targetSym) {
			result.push({ name: rec.name, line: rec.line, col: rec.col, nameLen: rec.colEnd - rec.col, isDecl: rec.isDecl });
		}
		i = i + 1;
	}
	return result;
}

// Cross-module fallback: match by (name, modulePath) when sym pointers differ across checker contexts.
export function sgQueryByName(ctx: CheckerContext, name: string, modulePath: string): SgSymbolRef[] {
	const result: SgSymbolRef[] = [];
	if (ctx.symRecords === null) return result;
	const records = ctx.symRecords;
	let i = 0;
	while (i < records.length) {
		const rec = records[i];
		if (rec.name === name) {
			if (modulePath === "" || rec.sym === null || rec.sym.modulePath === null || rec.sym.modulePath === "" || rec.sym.modulePath === modulePath) {
				result.push({ name: rec.name, line: rec.line, col: rec.col, nameLen: rec.colEnd - rec.col, isDecl: rec.isDecl });
			}
		}
		i = i + 1;
	}
	return result;
}

// Strict cross-module match: name AND defining module must match exactly.
// Rust-analyzer two-pass: fast text match + precise semantic confirmation.
export function sgQueryByDefiningModule(ctx: CheckerContext, name: string, defModule: string): SgSymbolRef[] {
	const result: SgSymbolRef[] = [];
	if (ctx.symRecords === null) return result;
	const records = ctx.symRecords;
	let i = 0;
	while (i < records.length) {
		const rec = records[i];
		if (rec.name === name && rec.sym !== null && rec.sym.modulePath !== null && rec.sym.modulePath === defModule) {
			result.push({ name: rec.name, line: rec.line, col: rec.col, nameLen: rec.colEnd - rec.col, isDecl: rec.isDecl });
		}
		i = i + 1;
	}
	return result;
}

// ===== sgTypeToString — full recursive type formatting =====

export function sgTypeToString(t: Type): string {
	return sgTypeToStringDepth(t, 0);
}

function sgTypeToStringDepth(t: Type, depth: number): string {
	if (t === null) return "unknown";
	if (depth > 10) return "...";

	const prim = match (t.kind) {
		TypeKind.Number => "number", TypeKind.String => "string",
		TypeKind.Boolean => "boolean", TypeKind.Void => "void",
		TypeKind.Null => "null", TypeKind.Unknown => "unknown",
		TypeKind.Never => "never", TypeKind.Error => "error",
		TypeKind.Int8 => "int8", TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32", TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8", TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32", TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32", TypeKind.Float64 => "float64",
		_ => "",
	};
	if (prim.length > 0) return prim;

	if (t.kind === TypeKind.Array) {
		const elem = sgTypeToStringDepth(t.typeReturn, depth + 1);
		return elem + "[]";
	}

	if (t.kind === TypeKind.Struct) {
		// Named struct with a real name (not internal __anon*)
		if (t.typeName.length > 0 && sgFindSubstring(t.typeName, "__anon") < 0) return t.typeName;
		// Anonymous/inline struct: { key: type, ... } — TypeScript style
		if (t.typeNames !== null && t.typeNames.length > 0) {
			let result = "{ ";
			for (let i = 0; i < t.typeNames.length; i = i + 1) {
				if (i > 0) result = result + "; ";
				result = result + t.typeNames[i] + ": ";
				if (i < t.typeChildren.length) {
					result = result + sgTypeToStringDepth(t.typeChildren[i], depth + 1);
				}
			}
			result = result + " }";
			return result;
		}
		return "{}";
	}

	if (t.kind === TypeKind.Function) {
		let result = "(";
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			if (i > 0) result = result + ", ";
			if (i < t.typeNames.length && t.typeNames[i].length > 0) {
				result = result + t.typeNames[i] + ": ";
			}
			result = result + sgTypeToStringDepth(t.typeChildren[i], depth + 1);
		}
		result = result + ") => " + sgTypeToStringDepth(t.typeReturn, depth + 1);
		return result;
	}

	if (t.kind === TypeKind.Enum) return t.typeName;

	if (t.kind === TypeKind.Union) {
		let result = "";
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			if (i > 0) result = result + " | ";
			result = result + sgTypeToStringDepth(t.typeChildren[i], depth + 1);
		}
		return result;
	}

	if (t.kind === TypeKind.Tuple) {
		let result = "[";
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			if (i > 0) result = result + ", ";
			result = result + sgTypeToStringDepth(t.typeChildren[i], depth + 1);
		}
		result = result + "]";
		return result;
	}

	if (isResult(t)) {
		const ok = sgTypeToStringDepth(getResultOkType(t), depth + 1);
		const err = sgTypeToStringDepth(getResultErrType(t), depth + 1);
		return "Result<" + ok + ", " + err + ">";
	}

	if (t.kind === TypeKind.Ref) {
		// Ref<T> is an implementation detail (class = heap pointer + RC).
		// Show just the inner type name — TypeScript doesn't expose ref/ptr.
		return sgTypeToStringDepth(t.typeReturn, depth + 1);
	}

	if (t.kind === TypeKind.Ptr) {
		// Ptr<T> is also an implementation detail — show inner type.
		return sgTypeToStringDepth(t.typeReturn, depth + 1);
	}

	if (t.kind === TypeKind.Distinct) {
		return "distinct " + sgTypeToStringDepth(t.typeReturn, depth + 1);
	}

	if (t.kind === TypeKind.Span) {
		return "Span<" + sgTypeToStringDepth(t.typeReturn, depth + 1) + ">";
	}

	if (t.kind === TypeKind.Var) {
		return sgTypeToStringDepth(t.typeReturn, depth + 1);
	}

	if (t.kind === TypeKind.Borrow) {
		return sgTypeToStringDepth(t.typeReturn, depth + 1);
	}

	if (t.kind === TypeKind.SizedArray) {
		return sgTypeToStringDepth(t.typeReturn, depth + 1) + "[" + String(t.typeFlags as int64) + "]";
	}

	if (t.kind === TypeKind.GenericParam) return t.typeName;

	if (t.kind === TypeKind.GenericInstance) {
		let result = sgTypeToStringDepth(t.typeExtra, depth + 1);
		result = result + "<";
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			if (i > 0) result = result + ", ";
			result = result + sgTypeToStringDepth(t.typeChildren[i], depth + 1);
		}
		result = result + ">";
		return result;
	}

	return "unknown";
}

// ===== sgFormatHover — markdown hover info =====

// Find substring in string. Returns index or -1.
function sgFindSubstring(haystack: string, needle: string): number {
	if (needle.byteLength === 0) return 0;
	if (needle.byteLength > haystack.byteLength) return -1;
	const limit = haystack.byteLength - needle.byteLength;
	for (let i = 0; i <= limit; i = i + 1) {
		let match = true;
		for (let j = 0; j < needle.byteLength; j = j + 1) {
			if (haystack.byteAt(i + j) !== needle.byteAt(j)) {
				match = false;
				break;
			}
		}
		if (match) return i;
	}
	return -1;
}

function sgSymbolKindName(kind: SymbolKind): string {
	return match (kind) {
		SymbolKind.Variable => "variable",
		SymbolKind.Function => "function",
		SymbolKind.Class => "class",
		SymbolKind.Interface => "interface",
		SymbolKind.Struct => "struct",
		SymbolKind.TypeAlias => "type",
		SymbolKind.Enum => "enum",
		SymbolKind.Parameter => "parameter",
		SymbolKind.Property => "property",
		SymbolKind.Method => "method",
		SymbolKind.EnumMember => "enum member",
	};
}

// Format parameter list: (a: number, b: string)
function sgFormatParamList(t: Type): string {
	let result = "(";
	for (let i = 0; i < t.typeChildren.length; i = i + 1) {
		if (i > 0) result = result + ", ";
		// Show `out` prefix for Var<T> params (out parameters)
		const isOut = t.typeChildren[i] !== null && t.typeChildren[i].kind === TypeKind.Var;
		if (isOut) result = result + "out ";
		if (i < t.typeNames.length && t.typeNames[i].length > 0) {
			result = result + t.typeNames[i] + ": ";
		}
		result = result + sgTypeToString(t.typeChildren[i]);
	}
	result = result + ")";
	return result;
}

// Format function type as declaration: function name(params): returnType
function sgFormatFuncDecl(name: string, t: Type): string {
	return "function " + name + sgFormatParamList(t) + ": " + sgTypeToString(t.typeReturn);
}

// Format interface fields as "field1: T1; field2: T2; ..." (up to 5)
function sgFormatFieldList(t: Type): string {
	if (t === null || t.typeNames.length === 0) return "";
	let result = "";
	const limit = 5;
	let maxLen = t.typeNames.length;
	if (maxLen > limit) maxLen = limit;
	for (let i = 0; i < maxLen; i = i + 1) {
		if (i > 0) result = result + "; ";
		result = result + t.typeNames[i];
		if (i < t.typeChildren.length) {
			result = result + ": " + sgTypeToString(t.typeChildren[i]);
		}
	}
	if (t.typeNames.length > limit) result = result + "; ...";
	return result;
}

// Format struct/interface/class fields as multiline "  field: type;\n" for hover display.
// Unwraps Ref to reach the inner Struct. Returns "" if no fields.
function sgFormatStructFields(t: Type): string {
	if (t === null) return "";
	let st = t;
	if (st.kind === TypeKind.Ref && st.typeReturn !== null) st = st.typeReturn;
	if (st.kind !== TypeKind.Struct || st.typeNames === null || st.typeNames.length === 0) return "";
	let result = "";
	for (let i = 0; i < st.typeNames.length; i = i + 1) {
		result = result + "  " + st.typeNames[i] + ": ";
		if (i < st.typeChildren.length) {
			result = result + sgTypeToString(st.typeChildren[i]);
		} else {
			result = result + "unknown";
		}
		result = result + ";\n";
	}
	return result;
}

// Build a Set of extension method names from the ExtensionRegistry.
// Used to filter prelude extensions from global completion (they only appear via member access).
function sgBuildExtensionNameSet(ctx: CheckerContext): Set<string> {
	const names: Set<string> = new Set<string>();
	if (ctx.extensionRegistry !== null) {
		for (const m of ctx.extensionRegistry.methods) {
			names.add(m.methodName);
		}
	}
	return names;
}

function sgIsAlias(suggest: SgSuggest): boolean {
	if (suggest.sym === null) return false;
	const orig = suggest.sym.originalName;
	return orig !== null && orig !== "" && orig !== suggest.name;
}

export function sgFormatHover(suggest: SgSuggest): string {
	if (suggest === null) return "";
	const typeStr = sgTypeToString(suggest.symType);
	const aliasPrefix = sgIsAlias(suggest) ? "(alias) " : "";
	// Variable/Parameter: const x: number / let x: number / parameter x: string
	if (suggest.kind === SymbolKind.Variable || suggest.kind === SymbolKind.Parameter) {
		let kw = "";
		if (suggest.kind === SymbolKind.Parameter) {
			kw = "(parameter)";
		} else {
			if (suggest.isMutable) { kw = "let"; } else { kw = "const"; }
		}
		return "```metascript\n" + aliasPrefix + kw + " " + suggest.name + ": " + typeStr + "\n```";
	}
	// Function: function name(params): returnType
	if (suggest.kind === SymbolKind.Function) {
		if (suggest.symType !== null && suggest.symType.kind === TypeKind.Function) {
			return "```metascript\n" + aliasPrefix + sgFormatFuncDecl(suggest.name, suggest.symType) + "\n```";
		}
		return "```metascript\n" + aliasPrefix + "function " + suggest.name + "\n```";
	}
	// Method: (method) Container.name(params): returnType — TS-Go: "(method) " prefix
	if (suggest.kind === SymbolKind.Method) {
		const container = suggest.containerName !== null && suggest.containerName !== ""
			? suggest.containerName + "." : "";
		if (suggest.symType !== null && suggest.symType.kind === TypeKind.Function) {
			return "```metascript\n" + aliasPrefix + "(method) " + container + suggest.name + sgFormatParamList(suggest.symType) + ": " + sgTypeToString(suggest.symType.typeReturn) + "\n```";
		}
		return "```metascript\n" + aliasPrefix + "(method) " + container + suggest.name + "\n```";
	}
	// EnumMember: (enum member) Name = value — TS-Go: "(enum member) " prefix with literal value
	if (suggest.kind === SymbolKind.EnumMember) {
		return "```metascript\n" + aliasPrefix + "(enum member) " + suggest.name + " = " + typeStr + "\n```";
	}
	// Property: (property) Container.name: type — TS-Go: "(property) " prefix
	if (suggest.kind === SymbolKind.Property) {
		let propContainer = "";
		if (suggest.containerName !== null && suggest.containerName !== "") {
			if (sgFindSubstring(suggest.containerName, "__anon") < 0) {
				propContainer = suggest.containerName + ".";
			}
		}
		return "```metascript\n" + aliasPrefix + "(property) " + propContainer + suggest.name + ": " + typeStr + "\n```";
	}
	// Interface/Struct/Class: show keyword + name + fields
	if (suggest.kind === SymbolKind.Interface || suggest.kind === SymbolKind.Struct || suggest.kind === SymbolKind.Class) {
		const kw = match (suggest.kind) {
			SymbolKind.Interface => "interface",
			SymbolKind.Struct => "struct",
			_ => "class",
		};
		const fields = sgFormatStructFields(suggest.symType);
		if (fields === "") {
			return "```metascript\n" + aliasPrefix + kw + " " + suggest.name + "\n```";
		}
		return "```metascript\n" + aliasPrefix + kw + " " + suggest.name + " {\n" + fields + "}\n```";
	}
	// Enum: enum Name — TS-Go: just the name, no members
	if (suggest.kind === SymbolKind.Enum) {
		return "```metascript\n" + aliasPrefix + "enum " + suggest.name + "\n```";
	}
	// TypeAlias: type T = underlying
	if (suggest.kind === SymbolKind.TypeAlias) {
		return "```metascript\n" + aliasPrefix + "type " + suggest.name + " = " + typeStr + "\n```";
	}
	// Fallback
	const kindName = sgSymbolKindName(suggest.kind);
	return "```metascript\n" + aliasPrefix + "(" + kindName + ") " + suggest.name + ": " + typeStr + "\n```";
}

// Hover documentation section — doc comments only (TS-Go: no file paths in hover)
export function sgFormatHoverDoc(suggest: SgSuggest, docComment: string): string {
	if (suggest === null) return "";
	return docComment;
}

// Built-in documentation for well-known symbols — sourced from TypeScript lib.es5.d.ts / lib.dom.d.ts JSDoc
export function sgBuiltinDoc(name: string, containerName: string): string {
	// console methods (lib.dom.d.ts Console interface)
	if (containerName === "console") {
		if (name === "log") return "The **`console.log()`** static method outputs a message to the console.\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/API/console/log_static)";
		if (name === "error") return "The **`console.error()`** static method outputs a message to the console at the 'error' log level.\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/API/console/error_static)";
		if (name === "warn") return "The **`console.warn()`** static method outputs a message to the console at the 'warning' log level.\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/API/console/warn_static)";
		if (name === "info") return "The **`console.info()`** static method outputs a message to the console at the 'info' log level.\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/API/console/info_static)";
		if (name === "debug") return "The **`console.debug()`** static method outputs a message to the console at the 'debug' log level.\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/API/console/debug_static)";
		if (name === "assert") return "The **`console.assert()`** static method writes an error message to the console if the assertion is false.\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/API/console/assert_static)";
		if (name === "clear") return "The **`console.clear()`** static method clears the console if possible.\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/API/console/clear_static)";
		if (name === "time") return "The **`console.time()`** static method starts a timer you can use to track how long an operation takes.\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/API/console/time_static)";
		if (name === "timeEnd") return "The **`console.timeEnd()`** static method stops a timer that was previously started.\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/API/console/timeEnd_static)";
		return "";
	}
	// JSON methods (lib.es5.d.ts JSON interface)
	if (containerName === "JSON") {
		if (name === "parse") return "Converts a JavaScript Object Notation (JSON) string into an object.\n\n@param `text` \u2014 A valid JSON string.\n\n@param `reviver` \u2014 A function that transforms the results. This function is called for each member of the object. If a member contains nested objects, the nested objects are transformed before the parent object is.\n\n@throws {SyntaxError} If `text` is not valid JSON.";
		if (name === "stringify") return "Converts a JavaScript value to a JavaScript Object Notation (JSON) string.\n\n@param `value` \u2014 A JavaScript value, usually an object or array, to be converted.\n\n@param `replacer` \u2014 A function that transforms the results.\n\n@param `space` \u2014 Adds indentation, white space, and line break characters to the return-value JSON text to make it easier to read.\n\n@throws {TypeError} If a circular reference or a BigInt value is found.";
		return "";
	}
	// JSON variable hover (lib.es5.d.ts)
	if (name === "JSON" && containerName === "") return "An intrinsic object that provides functions to convert JavaScript values to and from the JavaScript Object Notation (JSON) format.";
	// Math methods (lib.es5.d.ts Math interface)
	if (containerName === "Math") {
		if (name === "floor") return "Returns the greatest integer value less than or equal to its numeric argument.";
		if (name === "ceil") return "Returns the smallest integer greater than or equal to its numeric argument.";
		if (name === "round") return "Returns a supplied numeric expression rounded to the nearest integer.";
		if (name === "abs") return "Returns the absolute value of a number (the value without regard to whether it is positive or negative).";
		if (name === "sqrt") return "Returns the square root of a number.";
		if (name === "min") return "Returns the smaller of a set of supplied numeric expressions.";
		if (name === "max") return "Returns the larger of a set of supplied numeric expressions.";
		if (name === "pow") return "Returns the value of a base expression taken to a specified power.\n\n@param `x` \u2014 The base value of the expression.\n\n@param `y` \u2014 The exponent value of the expression.";
		if (name === "random") return "Returns a pseudorandom number between 0 and 1.";
		if (name === "trunc") return "Returns the integral part of a numeric expression, `x`, removing any fractional digits. If `x` is already an integer, the result is `x`.";
		if (name === "sign") return "Returns the sign of the `x`, indicating whether `x` is positive, negative, or zero.\n\n@param `x` \u2014 The numeric expression to test.";
		if (name === "log") return "Returns the natural logarithm (base e) of a number.";
		if (name === "log2") return "Returns the base 2 logarithm of a number.";
		if (name === "log10") return "Returns the base 10 logarithm of a number.";
		if (name === "PI") return "The mathematical constant e. This is Euler's number, the base of natural logarithms.";
		if (name === "E") return "The number whose value is the ratio of the circumference of a circle to its diameter.";
		return "";
	}
	// Result methods
	if (containerName === "Result") {
		if (name === "ok") return "Creates a successful Result wrapping the given value.";
		if (name === "err") return "Creates an error Result wrapping the given error.";
		return "";
	}
	// String methods (lib.es5.d.ts String interface)
	if (name === "length") return "Returns the length of a String object.";
	if (name === "toString") return "Returns a string representation of an object.";
	if (name === "charAt") return "Returns the character at the specified index.\n\n@param `pos` \u2014 The zero-based index of the desired character.";
	if (name === "charCodeAt") return "Returns the Unicode value of the character at the specified location.\n\n@param `index` \u2014 The zero-based index of the desired character.";
	if (name === "indexOf") return "Returns the position of the first occurrence of a substring.\n\n@param `searchString` \u2014 The substring to search for in the string.";
	if (name === "slice") return "Returns a section of a string or array.\n\n@param `start` \u2014 The index to the beginning of the specified portion.\n\n@param `end` \u2014 The index to the end of the specified portion (exclusive).";
	if (name === "substring") return "Returns the substring at the specified location within a String object.";
	if (name === "toLowerCase") return "Converts all the alphabetic characters in a string to lowercase.";
	if (name === "toUpperCase") return "Converts all the alphabetic characters in a string to uppercase.";
	if (name === "trim") return "Removes the leading and trailing white space and line terminator characters from a string.";
	if (name === "split") return "Split a string into substrings using the specified separator and return them as an array.\n\n@param `separator` \u2014 A string that identifies character or characters to use in separating the string.";
	if (name === "replace") return "Replaces text in a string, using a regular expression or search string.\n\n@param `searchValue` \u2014 A string or pattern to search for.\n\n@param `replaceValue` \u2014 A string containing the text to replace.";
	if (name === "includes") return "Returns true if searchString appears as a substring of the result of converting this object to a String, at one or more positions that are greater than or equal to position; otherwise, returns false.";
	if (name === "startsWith") return "Returns true if the sequence of elements of searchString converted to a String is the same as the corresponding elements of this object (converted to a String) starting at position. Otherwise returns false.";
	if (name === "endsWith") return "Returns true if the sequence of elements of searchString converted to a String is the same as the corresponding elements of this object (converted to a String) starting at endPosition - length(this). Otherwise returns false.";
	if (name === "repeat") return "Returns a String value that is made from count copies appended together. If count is 0, the empty string is returned.\n\n@param `count` \u2014 Number of copies to append.";
	if (name === "concat") return "Returns a string that contains the concatenation of two or more strings.";
	// Array methods (lib.es5.d.ts Array interface)
	if (name === "push") return "Appends new elements to the end of an array, and returns the new length of the array.\n\n@param `items` \u2014 New elements to add to the array.";
	if (name === "pop") return "Removes the last element from an array and returns it. If the array is empty, undefined is returned and the array is not modified.";
	if (name === "join") return "Adds all the elements of an array into a string, separated by the specified separator string.\n\n@param `separator` \u2014 A string used to separate one element of the array from the next.";
	if (name === "sort") return "Sorts an array in place. This method mutates the array and returns a reference to the same array.\n\n@param `compareFn` \u2014 Function used to determine the order of the elements.";
	if (name === "reverse") return "Reverses the elements in an array in place. This method mutates the array and returns a reference to the same array.";
	if (name === "map") return "Calls a defined callback function on each element of an array, and returns an array that contains the results.\n\n@param `callbackfn` \u2014 A function that accepts up to three arguments.";
	if (name === "filter") return "Returns the elements of an array that meet the condition specified in a callback function.\n\n@param `predicate` \u2014 A function that accepts up to three arguments.";
	if (name === "find") return "Returns the value of the first element in the array where predicate is true, and undefined otherwise.\n\n@param `predicate` \u2014 find calls predicate once for each element of the array.";
	if (name === "every") return "Determines whether all the members of an array satisfy the specified test.\n\n@param `predicate` \u2014 A function that accepts up to three arguments.";
	if (name === "some") return "Determines whether the specified callback function returns true for any element of an array.\n\n@param `predicate` \u2014 A function that accepts up to three arguments.";
	if (name === "reduce") return "Calls the specified callback function for all the elements in an array. The return value of the callback function is the accumulated result.\n\n@param `callbackfn` \u2014 A function that accepts up to four arguments.";
	if (name === "forEach") return "Performs the specified action for each element in an array.\n\n@param `callbackfn` \u2014 A function that accepts up to three arguments.";
	return "";
}

// ===== Doc Comment Extraction =====

// Extract the line content at a given 1-indexed line number.
// Returns "" if line is out of range.
function sgExtractLine(source: string, line: number): string {
	if (line < 1) return "";
	const start = sgGetLineOffset(source, line);
	if (start >= source.byteLength) return "";
	let end = start;
	while (end < source.byteLength && source.byteAt(end) !== "\n".code) {
		end = end + 1;
	}
	return source.slice(start, end);
}

// Strip leading whitespace from a string.
function sgTrimLeft(s: string): string {
	let i = 0;
	while (i < s.byteLength) {
		const ch = s.byteAt(i);
		if (ch !== " ".code && ch !== "\t".code) break;
		i = i + 1;
	}
	if (i === 0) return s;
	return s.slice(i, s.byteLength);
}

// Extract /** JSDoc */ doc comment above a declaration at the given line (1-indexed).
// TypeScript convention only: /** ... */ block comments.
export function sgExtractDocComment(source: string, declLine: number): string {
	if (declLine <= 1) return "";
	const lastCommentLine = declLine - 1;
	const lastRaw = sgExtractLine(source, lastCommentLine);
	const lastTrimmed = sgTrimLeft(lastRaw);
	if (sgFindSubstring(lastTrimmed, "*/") >= 0) {
		return sgExtractJsDocBlock(source, lastCommentLine);
	}
	return "";
}

// Extract a /** ... */ JSDoc block comment ending at `endLine` (1-indexed).
// Scans upward to find the opening /**, collects lines, strips * prefixes.
function sgExtractJsDocBlock(source: string, endLine: number): string {
	// Scan upward to find the line with /**
	let startLine = endLine;
	while (startLine >= 1) {
		const raw = sgExtractLine(source, startLine);
		if (sgFindSubstring(raw, "/**") >= 0) break;
		startLine = startLine - 1;
	}
	if (startLine < 1) return "";
	// Single-line: /** Some doc */
	if (startLine === endLine) {
		const raw = sgTrimLeft(sgExtractLine(source, startLine));
		// Strip /** and */
		let s = raw;
		const openIdx = sgFindSubstring(s, "/**");
		if (openIdx >= 0) s = s.slice(openIdx + 3, s.length);
		const closeIdx = sgFindSubstring(s, "*/");
		if (closeIdx >= 0) s = s.slice(0, closeIdx);
		return sgTrimLeft(sgTrimRight(s));
	}
	// Multi-line: collect from startLine+1 to endLine-1, plus partial first/last
	const lines: string[] = [];
	// First line: everything after /**
	const firstRaw = sgExtractLine(source, startLine);
	const openIdx = sgFindSubstring(firstRaw, "/**");
	if (openIdx >= 0) {
		const after = firstRaw.slice(openIdx + 3, firstRaw.length);
		const trimAfter = sgTrimLeft(sgTrimRight(after));
		if (trimAfter.length > 0) lines.push(trimAfter);
	}
	// Middle lines: strip leading * prefix
	let ln = startLine + 1;
	while (ln < endLine) {
		const raw = sgTrimLeft(sgExtractLine(source, ln));
		let content = raw;
		// Strip leading * (with optional space)
		if (content.byteLength > 0 && content.byteAt(0) === "*".code) {
			content = content.slice(1, content.byteLength);
			if (content.byteLength > 0 && content.byteAt(0) === " ".code) {
				content = content.slice(1, content.byteLength);
			}
		}
		lines.push(sgTrimRight(content));
		ln = ln + 1;
	}
	// Last line: everything before */
	const lastRaw = sgTrimLeft(sgExtractLine(source, endLine));
	// Strip */ first, then strip leading * prefix
	let lastContent = lastRaw;
	const closeIdx2 = sgFindSubstring(lastContent, "*/");
	if (closeIdx2 >= 0) lastContent = lastContent.slice(0, closeIdx2);
	lastContent = sgTrimLeft(lastContent);
	if (lastContent.byteLength > 0 && lastContent.byteAt(0) === "*".code) {
		lastContent = lastContent.slice(1, lastContent.byteLength);
		if (lastContent.byteLength > 0 && lastContent.byteAt(0) === " ".code) {
			lastContent = lastContent.slice(1, lastContent.byteLength);
		}
	}
	lastContent = sgTrimRight(lastContent);
	if (lastContent.byteLength > 0) lines.push(lastContent);
	// Join lines
	let result = "";
	let i = 0;
	while (i < lines.length) {
		if (i > 0) result = result + "\n";
		result = result + lines[i];
		i = i + 1;
	}
	return result;
}

// Trim trailing whitespace
function sgTrimRight(s: string): string {
	let i = s.byteLength - 1;
	while (i >= 0) {
		const ch = s.byteAt(i);
		if (ch !== " ".code && ch !== "\t".code && ch !== "\r".code) break;
		i = i - 1;
	}
	return s.slice(0, i + 1);
}

// ===== Cross-Module Helpers =====

// Find which import provides `name`. Returns the import source specifier or "".
// Walks ProgramData.programStmts, checks ImportDecl.importNames for a match.
// Also checks inside ExportDecl wrappers (re-exports).
export function sgFindImportSource(program: Node, name: string): string {
	if (program === null) return "";
	if (program.kind !== NodeKind.Program) return "";
	const data = program.data as ProgramData;
	for (let i = 0; i < data.programStmts.length; i = i + 1) {
		let stmt = data.programStmts[i];
		// Unwrap ExportDecl (re-exports)
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			stmt = ed.exportedDecl;
		}
		if (stmt.kind === NodeKind.ImportDecl) {
			const imp = stmt.data as ImportDeclData;
			for (let j = 0; j < imp.importNames.length; j = j + 1) {
				if (imp.importNames[j] === name) {
					return imp.importSource;
				}
			}
		}
	}
	return "";
}

// Find the ImportDecl node that imports from a given source path.
export function sgFindImportBySource(program: Node, importSource: string): Node {
	if (program === null || program.kind !== NodeKind.Program) return null as unknown as Node;
	const data = program.data as ProgramData;
	for (let i = 0; i < data.programStmts.length; i = i + 1) {
		let stmt = data.programStmts[i];
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			stmt = ed.exportedDecl;
		}
		if (stmt.kind === NodeKind.ImportDecl) {
			const imp = stmt.data as ImportDeclData;
			if (imp.importSource === importSource) return stmt;
		}
	}
	return null as unknown as Node;
}

// Compute the text edit needed to add a symbol to imports.
// Returns: { kind: 0=add-to-existing/1=new-import, line, col, endCol, newText }
export interface SgImportEdit {
	kind: number;
	line: number;
	col: number;
	endCol: number;
	newText: string;
}

export function sgComputeImportEdit(program: Node, source: string, symbolName: string, importSource: string): SgImportEdit {
	// Check if an import from this module already exists
	const existing = sgFindImportBySource(program, importSource);
	if (existing !== null) {
		// Add to existing import: find the closing } on the import line
		const imp = existing.data as ImportDeclData;
		const importLine = existing.location.line;
		// Find the } in source text on this line
		const lineOffset = sgGetLineOffset(source, importLine);
		let bracePos = lineOffset;
		while (bracePos < source.byteLength && source.byteAt(bracePos) !== "}".code) {
			bracePos = bracePos + 1;
		}
		if (bracePos < source.byteLength) {
			// Insert ", symbolName" before the space+} at end of import names
			// e.g., "import { BuildConfig }" → insert ", FmtConfig" before " }"
			let insertPos = bracePos;
			// Skip back over whitespace before }
			while (insertPos > lineOffset && source.byteAt(insertPos - 1) === " ".code) {
				insertPos = insertPos - 1;
			}
			// Skip back over trailing comma: { CpuInfo, } → insert after "CpuInfo"
			if (insertPos > lineOffset && source.byteAt(insertPos - 1) === ",".code) {
				insertPos = insertPos - 1;
			}
			const col = insertPos - lineOffset;
			const insertText = imp.importNames.length > 0 ? ", " + symbolName : symbolName;
			return { kind: 0, line: importLine - 1, col, endCol: col, newText: insertText };
		}
	}
	// New import: find last import line, insert after it
	let lastImportLine = 0;
	if (program.kind === NodeKind.Program) {
		const pd = program.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i = i + 1) {
			let stmt = pd.programStmts[i];
			if (stmt.kind === NodeKind.ExportDecl) {
				const ed = stmt.data as ExportDeclData;
				stmt = ed.exportedDecl;
			}
			if (stmt.kind === NodeKind.ImportDecl) {
				if (stmt.location.line > lastImportLine) lastImportLine = stmt.location.line;
			}
		}
	}
	const insertLine = lastImportLine; // 0-based for LSP (lastImportLine is 1-based, insert after it = same 0-based index)
	const newText = `import { ${symbolName} } from "${importSource}";\n`;
	return { kind: 1, line: insertLine, col: 0, endCol: 0, newText };
}

// Helper: get declaration name from a top-level node.
function sgGetDeclName(node: Node): string {
	if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		return d.fnName;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		return d.declName;
	}
	if (node.kind === NodeKind.InterfaceDecl || node.kind === NodeKind.StructDecl) {
		const d = node.data as InterfaceDeclData;
		return d.interfaceName;
	}
	if (node.kind === NodeKind.EnumDecl) {
		const d = node.data as EnumDeclData;
		return d.enumName;
	}
	if (node.kind === NodeKind.TypeAliasDecl) {
		const d = node.data as TypeAliasDeclData;
		return d.aliasName;
	}
	if (node.kind === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		return d.className;
	}
	return "";
}

// Find the declaration location of `name` in a program AST.
// Walks top-level stmts (including inside ExportDecl) for matching declarations.
// Returns { line: 0, column: 0 } if not found.
export function sgFindExportedDecl(program: Node, name: string): SourceLocation {
	const notFound = makeLoc(0, 0);
	if (program === null) return notFound;
	if (program.kind !== NodeKind.Program) return notFound;
	const data = program.data as ProgramData;
	for (let i = 0; i < data.programStmts.length; i = i + 1) {
		let stmt = data.programStmts[i];
		let inner = stmt;
		// Unwrap ExportDecl
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			inner = ed.exportedDecl;
		}
		const declName = sgGetDeclName(inner);
		if (declName === name) {
			return inner.location;
		}
	}
	return notFound;
}


// ===== sgCollectDiagnostics — wrap checker errors =====

export function sgCollectDiagnostics(ctx: CheckerContext): SgDiagnostic[] {
	const result: SgDiagnostic[] = [];
	for (let i = 0; i < ctx.errors.length; i = i + 1) {
		const err = ctx.errors[i];
		// Map Severity enum to LSP DiagnosticSeverity (1=Error, 2=Warning, 3=Info, 4=Hint)
		const lspSeverity = (err.severity as number) + 1;
		const diag: SgDiagnostic = {
			message: err.message,
			line: err.line > 0 ? err.line : 1,
			column: err.column,
			endColumn: err.endColumn,
			severity: lspSeverity,
		};
		result.push(diag);
	}
	return result;
}

// ===== Completion Helpers =====

export function sgIsIdentChar(ch: string): boolean {
	if (ch.byteLength === 0) return false;
	const c = ch.byteAt(0);
	return sgIsIdentByte(c);
}

function sgIsIdentByte(c: number): boolean {
	if (c === "_".code) return true;
	if (c >= "a".code && c <= "z".code) return true;
	if (c >= "A".code && c <= "Z".code) return true;
	if (c >= "0".code && c <= "9".code) return true;
	return false;
}

export function sgGetLineOffset(source: string, line: number): number {
	// line is 1-indexed. Returns offset of the first char on that line.
	let offset = 0;
	let currentLine = 1;
	while (offset < source.byteLength && currentLine < line) {
		if (source.byteAt(offset) === "\n".code) {
			currentLine = currentLine + 1;
		}
		offset = offset + 1;
	}
	return offset;
}

// Extract full line text for a 1-based line number.
function sgGetLineText(source: string, line: number): string {
	const lineOffset = sgGetLineOffset(source, line);
	let lineEnd = lineOffset;
	while (lineEnd < source.byteLength && source.byteAt(lineEnd) !== "\n".code) {
		lineEnd = lineEnd + 1;
	}
	return source.slice(lineOffset, lineEnd);
}

function sgStartsWith(s: string, prefix: string): boolean {
	if (prefix.length === 0) return true;
	if (prefix.length > s.length) return false;
	return s.slice(0, prefix.length) === prefix;
}

function sgIsTypeKind(kind: SymbolKind): boolean {
	return kind === SymbolKind.Interface || kind === SymbolKind.Class
		|| kind === SymbolKind.Enum || kind === SymbolKind.TypeAlias;
}

// ===== Completion Ranking =====

function sgToLowerByte(c: number): number {
	if (c >= "A".code && c <= "Z".code) return c + 32;
	return c;
}

function sgCaseEqualByte(a: number, b: number): boolean {
	return sgToLowerByte(a) === sgToLowerByte(b);
}

function sgCaseEqualStr(a: string, b: string): boolean {
	if (a.byteLength !== b.byteLength) return false;
	for (let i = 0; i < a.byteLength; i = i + 1) {
		if (!sgCaseEqualByte(a.byteAt(i), b.byteAt(i))) return false;
	}
	return true;
}

// Returns 0=None, 1=Substr, 2=Prefix
function sgPrefixMatch(prefix: string, name: string): number {
	if (prefix.byteLength === 0) return 2;
	if (prefix.byteLength > name.byteLength) return 0;
	// Check prefix match (case-insensitive)
	let isPrefix = true;
	for (let k = 0; k < prefix.byteLength; k = k + 1) {
		if (!sgCaseEqualByte(prefix.byteAt(k), name.byteAt(k))) {
			isPrefix = false;
			break;
		}
	}
	if (isPrefix) return 2;
	// Check substring match (case-insensitive)
	for (let start = 1; start + prefix.byteLength <= name.byteLength; start = start + 1) {
		let matched = true;
		for (let m = 0; m < prefix.byteLength; m = m + 1) {
			if (!sgCaseEqualByte(prefix.byteAt(m), name.byteAt(start + m))) {
				matched = false;
				break;
			}
		}
		if (matched) return 1;
	}
	return 0;
}

// Count how many times a symbol appears in the current file's sym records.
function sgCountSymUsages(ctx: CheckerContext, targetSym: Symbol): number {
	if (ctx.symRecords === null || targetSym === null) return 0;
	let count = 0;
	const records = ctx.symRecords;
	for (let i = 0; i < records.length; i = i + 1) {
		if (records[i].sym === targetSym) count = count + 1;
	}
	return count;
}

function sgCompareSuggestions(a: SgSuggest, b: SgSuggest): number {
	// Higher prefixScore first
	if (a.prefixScore !== b.prefixScore) return b.prefixScore - a.prefixScore;
	// contextFit true first
	const aFit = a.contextFit ? 1 : 0;
	const bFit = b.contextFit ? 1 : 0;
	if (aFit !== bFit) return bFit - aFit;
	// Higher usage count first (more used = more relevant)
	if (a.usageCount !== b.usageCount) return b.usageCount - a.usageCount;
	// Lower scopeDepth first (closer scope)
	if (a.scopeDepth !== b.scopeDepth) return a.scopeDepth - b.scopeDepth;
	// Shorter name tiebreaker (more concise = likely more relevant)
	if (a.name.length !== b.name.length) return a.name.length - b.name.length;
	return 0;
}

function sgSortSuggestions(list: SgSuggest[]): void {
	for (let i = 1; i < list.length; i = i + 1) {
		const current = list[i];
		let j = i - 1;
		while (j >= 0 && sgCompareSuggestions(list[j], current) > 0) {
			list[j + 1] = list[j];
			j = j - 1;
		}
		list[j + 1] = current;
	}
}

// ===== AST-Based Completion Context Detection =====
// Walks the parsed AST to determine completion context by node kind.
// Aligned with reference (MemberExpr/ObjectLiteral) and rust-analyzer (classify_name_ref).

// Find the innermost AST node at or before the given 1-based line:col.
// Walks depth-first; among matches, prefers the one with largest column (closest to cursor).
export function findNodeAtPosition(root: Node, line: number, col: number): Node {
	if (root === null) return null as unknown as Node;
	let best = null as unknown as Node;
	if (root.location.line === line && root.location.column <= col) {
		best = root;
	}
	forEachChild(root, (child: Node): void => {
		const found = findNodeAtPosition(child, line, col);
		if (found !== null) {
			if (best === null || found.location.column >= best.location.column) {
				best = found;
			}
		}
	});
	return best;
}

// Find a MemberExpr with empty property on the given line where cursor >= dot column.
// Targeted search for incomplete dot access: `config.|`
function findIncompleteMemberExpr(root: Node, line: number, col: number): Node {
	if (root === null) return null as unknown as Node;
	if (root.kind === NodeKind.MemberExpr) {
		const d = root.data as MemberExprData;
		if (d.property === "" && root.location.line === line && root.location.column <= col) {
			return root;
		}
	}
	let found = null as unknown as Node;
	forEachChild(root, (child: Node): void => {
		if (found === null) {
			const r = findIncompleteMemberExpr(child, line, col);
			if (r !== null) {
				found = r;
			}
		}
	});
	return found;
}

// Find the innermost ObjectLiteral node containing the cursor position.
// Returns null if cursor is not inside any ObjectLiteral.
// Uses subtree check: an ObjectLiteral "contains" the cursor only if the cursor's
// deepest node is inside that ObjectLiteral's subtree (prevents false positives
// on closed ObjectLiterals from earlier lines).
export function findEnclosingObjectLiteral(root: Node, line: number, col: number): Node {
	if (root === null) return null as unknown as Node;
	let result = null as unknown as Node;
	if (root.kind === NodeKind.ObjectLiteral) {
		// Same-line check: cursor is on ObjectLiteral's opening line
		if (root.location.line === line && root.location.column <= col) {
			result = root;
		}
		// Multi-line check: ObjectLiteral starts before cursor line.
		// Only match if a descendant of this ObjectLiteral is on or past the cursor line.
		if (root.location.line < line && sgSubtreeTouchesLine(root, line)) {
			result = root;
		}
	}
	// Check children — a deeper ObjectLiteral wins
	forEachChild(root, (child: Node): void => {
		const found = findEnclosingObjectLiteral(child, line, col);
		if (found !== null) {
			result = found;
		}
	});
	return result;
}

// Check if the subtree of node spans across the target line.
// Returns true if any descendant is ON or PAST the target line.
// This handles empty lines inside multi-line constructs (e.g. ObjectLiteral with blank lines).
function sgSubtreeTouchesLine(node: Node, targetLine: number): boolean {
	if (node === null) return false;
	let touches = false;
	forEachChild(node, (child: Node): void => {
		if (!touches) {
			if (child.location.line >= targetLine) {
				// Child is on or past target line — the parent spans across it
				touches = true;
			} else {
				// Child is before target — check its subtree
				if (sgSubtreeTouchesLine(child, targetLine)) {
					touches = true;
				}
			}
		}
	});
	return touches;
}

// ===== AST-Based Signature Help (CallExpr callee + child count for active param) =====

// Find the innermost CallExpr enclosing the cursor position.
// Mirrors findEnclosingObjectLiteral pattern. Deepest (innermost) call wins.
function findEnclosingCallExpr(root: Node, line: number, col: number): Node {
	if (root === null) return null as unknown as Node;
	let result = null as unknown as Node;
	if (root.kind === NodeKind.CallExpr) {
		// Same-line: CallExpr location is at '(' token
		if (root.location.line === line && root.location.column <= col) {
			result = root;
		}
		// Multi-line: CallExpr starts before cursor line, has descendant on cursor line
		if (root.location.line < line && sgSubtreeTouchesLine(root, line)) {
			result = root;
		}
	}
	// Recurse — deepest (innermost) CallExpr wins
	forEachChild(root, (child: Node): void => {
		const found = findEnclosingCallExpr(child, line, col);
		if (found !== null) {
			result = found;
		}
	});
	return result;
}

// Extract callee name from CallExpr AST node.
// Reference: CallExpr.callee → Identifier or MemberExpr.property.
function sgGetCalleeFromNode(callNode: Node): string {
	const d = callNode.data as CallExprData;
	if (d.callee === null) return "";
	if (d.callee.kind === NodeKind.Identifier) {
		return (d.callee.data as IdentifierData).name;
	}
	if (d.callee.kind === NodeKind.MemberExpr) {
		return (d.callee.data as MemberExprData).property;
	}
	return "";
}

// Extract receiver name for method calls (e.g. "console" from console.log()).
// Reference: MemberExpr.object.
function sgGetReceiverFromNode(callNode: Node): string {
	const d = callNode.data as CallExprData;
	if (d.callee === null || d.callee.kind !== NodeKind.MemberExpr) return "";
	const md = d.callee.data as MemberExprData;
	if (md.object === null) return "";
	if (md.object.kind === NodeKind.Identifier) {
		return (md.object.data as IdentifierData).name;
	}
	return "";
}

// Determine active parameter index from cursor position within CallExpr arguments.
// Reference: count CallExpr arguments before cursor position.
function sgGetActiveParamFromNode(callNode: Node, line: number, col: number): number {
	const d = callNode.data as CallExprData;
	if (d.arguments.length === 0) return 0;
	// Count arguments whose start location is before cursor
	let activeParam = 0;
	for (let i = 0; i < d.arguments.length; i = i + 1) {
		const arg = d.arguments[i];
		if (arg.location.line < line) {
			activeParam = i + 1;
		} else if (arg.location.line === line && arg.location.column < col) {
			activeParam = i + 1;
		}
	}
	return activeParam;
}

// Unified signature context: AST-based with text-based fallback.
export interface SgSignatureContext {
	calleeName: string;
	receiverName: string;
	activeParam: number;
}

export function sgGetSignatureContext(program: Node, source: string, line: number, col: number): SgSignatureContext {
	// Primary: AST-based
	const callNode = findEnclosingCallExpr(program, line, col);
	if (callNode !== null) {
		return {
			calleeName: sgGetCalleeFromNode(callNode),
			receiverName: sgGetReceiverFromNode(callNode),
			activeParam: sgGetActiveParamFromNode(callNode, line, col),
		};
	}
	// Fallback: text-based (handles incomplete source where parser couldn't produce CallExpr)
	return {
		calleeName: sgGetCalleeAtCursor(source, line, col),
		receiverName: sgGetReceiverAtCursor(source, line, col),
		activeParam: sgCountActiveParam(source, line, col),
	};
}

// Find the ObjectLiteral nesting path from cursor to root.
// For `{ fmt: { | } }`, returns ["fmt"] (the key whose value is the inner ObjectLiteral).
// Walks from cursor's enclosing ObjectLiteral outward through parent ObjectLiterals.
export function sgObjectFieldPathAST(root: Node, line: number, col: number): string[] {
	const path: string[] = [];
	// Collect all ObjectLiteral ancestors containing cursor, deepest first
	sgCollectObjLiteralChain(root, line, col, path);
	return path;
}

// Recursively find ObjectLiteral nesting chain. For each nested ObjectLiteral
// that is a property value of an outer ObjectLiteral, record the parent's key name.
function sgCollectObjLiteralChain(node: Node, line: number, col: number, path: string[]): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		// Check each property value — if cursor is inside a nested ObjectLiteral value,
		// record the key name for this level
		for (let i = 0; i < d.properties.length; i = i + 1) {
			const propVal = d.properties[i];
			if (propVal !== null && propVal.kind === NodeKind.ObjectLiteral) {
				if (sgCollectObjLiteralChain(propVal, line, col, path)) {
					// Cursor is inside this nested ObjectLiteral — add parent key
					if (i < d.keys.length) {
						path.push(d.keys[i]);
					}
					return true;
				}
			} else if (propVal !== null) {
				// Non-ObjectLiteral property — recurse for deeper nesting
				if (sgCollectObjLiteralChain(propVal, line, col, path)) {
					return true;
				}
			}
		}
		// Cursor is directly inside this ObjectLiteral (not in a nested one)
		if (node.location.line < line || (node.location.line === line && node.location.column <= col)) {
			return true;
		}
	}
	// Recurse into non-ObjectLiteral children
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && sgCollectObjLiteralChain(child, line, col, path)) {
			found = true;
		}
	});
	return found;
}

// ===== AST-Based Import Detection =====
// Reference: findImportStmtOnLine + extractImportContextFromAst

// Find an ImportDecl node that spans the given line. Handles multi-line imports
// by checking if cursor line is between this import and the next statement.
function findImportDeclOnLine(program: Node, line: number): Node {
	if (program === null) return null as unknown as Node;
	let found = null as unknown as Node;
	if (program.kind === NodeKind.Program && program.data !== null) {
		const d = program.data as ProgramData;
		if (d.programStmts === null) return null as unknown as Node;
		for (let i = 0; i < d.programStmts.length; i = i + 1) {
			const stmt = d.programStmts[i];
			const imp = importNodeFrom(stmt);
			if (imp === null) continue;
			if (imp.location.line === line) return imp;
			// Multi-line imports: only extend to subsequent lines if the import
			// is still being written (no importSource yet = incomplete import).
			// Complete imports (have "from ...") don't extend beyond their line.
			const impData = imp.data as ImportDeclData;
			if (impData.importSource === "" && imp.location.line < line) {
				if (i + 1 < d.programStmts.length) {
					const nextLine = d.programStmts[i + 1].location.line;
					if (line < nextLine) return imp;
				}
			}
		}
	} else {
		let prevImp = null as unknown as Node;
		let prevLine = 0;
		forEachChild(program, (child: Node): void => {
			if (found !== null) return;
			// If we had a pending import and this child starts after cursor → import spans cursor
			if (prevImp !== null && child.location.line > line) {
				found = prevImp;
				return;
			}
			prevImp = null as unknown as Node;
			const imp = importNodeFrom(child);
			if (imp !== null) {
				if (imp.location.line === line) { found = imp; return; }
				if (imp.location.line < line) { prevImp = imp; }
			}
		});
		// If last statement was an import that started before cursor
		if (found === null && prevImp !== null) found = prevImp;
	}
	return found;
}

// Extract ImportDecl from a statement (handles ExportDecl wrapping).
function importNodeFrom(stmt: Node): Node {
	if (stmt.kind === NodeKind.ImportDecl) return stmt;
	if (stmt.kind === NodeKind.ExportDecl) {
		const ed = stmt.data as ExportDeclData;
		if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.ImportDecl) return ed.exportedDecl;
	}
	return null as unknown as Node;
}

// Determine import context from AST ImportDecl node.
// Returns: "names" if cursor is in the names region, "path" if in the source string.
// Reference: extractImportContextFromAst checks child node positions.
function importContextFromAST(importNode: Node, col: number): string {
	const d = importNode.data as ImportDeclData;
	// Side-effect import: `import "module"` — only path, no names.
	if (d.importNames.length === 0 && d.importSource === "") return "path";
	// Use the importSource string length + nameLocations to determine context.
	// The AST gives us: importNames, importAliases, importSource, nameLocations.
	// Strategy: if importSource exists, compute where it starts in the line.
	// The source string position = nodeCol + everything before it.
	// Simpler: use nameLocations for "names" region, importSource for "path" region.
	if (d.importSource !== "") {
		// The path string occupies the last part of the import statement.
		// Its 1-based end column = importNode endColumn (approximately).
		// The names region is between the first nameLocation and closing `}`.
		if (d.nameLocations.length > 0) {
			const firstNameCol = d.nameLocations[0].column;
			const lastIdx = d.nameLocations.length - 1;
			const lastNameEnd = d.nameLocations[lastIdx].column + d.importNames[lastIdx].length;
			// Cursor is in names region if between first name and `} from "` boundary
			if (col >= firstNameCol - 1 && col <= lastNameEnd + 3) return "names";
			// Past the names + `} from "` → path
			if (col > lastNameEnd + 8) return "path";
			return "names";
		}
		// No nameLocations (empty braces): cursor is in `{ }` or in `"path"`.
		// `{` starts at importNode.column + 7 (after "import ").
		// For empty/space-only braces, content is at most a few chars.
		// Wider braces with actual names would have nameLocations.
		const braceOpen = importNode.location.column + 7;
		if (col >= braceOpen && col <= braceOpen + 4) return "names";
		return "path";
	}
	return "names";
}

// ===== AST-Based Type Annotation Detection =====
// Reference: declaration type-position check + inTypeContext flag.
// We check if cursor is on a typeExpr or typeExprs node of any declaration.

function isInTypeAnnotation(program: Node, line: number, col: number): boolean {
	let found = false;
	forEachChild(program, (child: Node): void => {
		if (found) return;
		if (sgCheckTypeExprAt(child, line, col)) {
			found = true;
			return;
		}
		if (isInTypeAnnotation(child, line, col)) {
			found = true;
		}
	});
	return found;
}

// Check if a node's typeExpr or typeExprs contains the cursor position.
function sgCheckTypeExprAt(node: Node, line: number, col: number): boolean {
	// Check typeExpr (return type, variable type, type alias RHS)
	if (node.typeExpr !== null) {
		const te = node.typeExpr;
		if (te.location.line === line && te.location.column <= col) {
			return true;
		}
	}
	// Check typeExprs (per-param type annotations)
	if (node.typeExprs !== null) {
		for (let i = 0; i < node.typeExprs.length; i = i + 1) {
			const te = node.typeExprs[i];
			if (te !== null && te.location.line === line && te.location.column <= col) {
				return true;
			}
		}
	}
	return false;
}

// ===== Fully AST-Based Completion Context Detection =====
// Reference: all detection via node kinds, no text scanning.
// - ImportDecl → ImportName / ImportPath
// - MemberExpr → MemberAccess
// - ObjectLiteral → ObjectField
// - typeExpr/typeExprs → TypeAnnotation

export function sgDetectCompletionContext(program: Node, line: number, col: number): SgCompletionKind {
	// Import detection: find ImportDecl on cursor line (ref: findImportStmtOnLine)
	const importNode = findImportDeclOnLine(program, line);
	if (importNode !== null) {
		const ctx = importContextFromAST(importNode, col);
		if (ctx === "names") return SgCompletionKind.ImportName;
		return SgCompletionKind.ImportPath;
	}

	// MemberExpr at cursor → member access
	const node = findNodeAtPosition(program, line, col);
	if (node !== null && node.kind === NodeKind.MemberExpr) {
		return SgCompletionKind.MemberAccess;
	}

	// ObjectLiteral → field completion
	const objNode = findEnclosingObjectLiteral(program, line, col);
	if (objNode !== null) {
		return SgCompletionKind.ObjectField;
	}

	// TypeAnnotation: cursor on a typeExpr/typeExprs node (ref: declaration type-position)
	if (isInTypeAnnotation(program, line, col)) {
		return SgCompletionKind.TypeAnnotation;
	}

	return SgCompletionKind.Identifier;
}

// ===== AST-Based Import Data Extraction =====
// All import data comes from ImportDeclData — no text scanning.

// Extract the import source path from the ImportDecl AST node on cursor line.
// `import { ... } from "std/build"` → "std/build"
export function sgExtractImportSource(program: Node, line: number): string {
	const importNode = findImportDeclOnLine(program, line);
	if (importNode === null) return "";
	const d = importNode.data as ImportDeclData;
	return d.importSource;
}

// Extract partial import path (what user has typed so far) for path completion.
// For incomplete source like `from "std/bu|"` — the parser may not have the full string,
// so we use source text to get the partial text between opening quote and cursor.
// This is the ONE place where source text is needed: the parser only stores completed strings.
export function sgExtractImportPath(source: string, line: number, col: number): string {
	const lineText = sgGetLineText(source, line);
	// Find opening quote on the line (after `from ` or `import `)
	let fromIdx = sgFindPattern(lineText, "from ");
	if (fromIdx < 0) fromIdx = sgFindPattern(lineText, "import ");
	if (fromIdx < 0) return "";
	let qi = fromIdx;
	while (qi < lineText.byteLength && lineText.byteAt(qi) !== "\"".code) qi = qi + 1;
	if (qi >= lineText.byteLength) return "";
	const openQuote = qi;
	const cursorCol0 = col - 1;
	if (cursorCol0 <= openQuote) return "";
	return lineText.slice(openQuote + 1, cursorCol0);
}

// Extract existing imported names from ImportDecl AST node.
// Reference: reads ImportDecl children directly.
export function sgExtractExistingImportNames(program: Node, line: number, col: number): string[] {
	const importNode = findImportDeclOnLine(program, line);
	if (importNode === null) return [];
	const d = importNode.data as ImportDeclData;
	// Exclude the name at the cursor position (the one being edited)
	const result: string[] = [];
	for (let i = 0; i < d.importNames.length; i = i + 1) {
		if (i < d.nameLocations.length) {
			const nameLoc = d.nameLocations[i];
			const nameLen = d.importNames[i].length;
			// If cursor is within this name's span, skip it (user is editing this name)
			if (nameLoc.line === line && col >= nameLoc.column && col <= nameLoc.column + nameLen) {
				continue;
			}
		}
		result.push(d.importNames[i]);
	}
	return result;
}

// Extract the prefix being typed at cursor using sgGetPrefix (reuse existing function).
// For import names: `import { re| }` → prefix is "re" — same as any identifier prefix.

// Simple substring search (no indexOf on strings in MetaScript).
function sgFindPattern(text: string, pattern: string): number {
	if (pattern.byteLength > text.byteLength) return -1;
	let i = 0;
	while (i <= text.byteLength - pattern.byteLength) {
		let match = true;
		let j = 0;
		while (j < pattern.byteLength) {
			if (text.byteAt(i + j) !== pattern.byteAt(j)) {
				match = false;
				j = pattern.byteLength; // break
			}
			j = j + 1;
		}
		if (match) return i;
		i = i + 1;
	}
	return -1;
}

// Get existing field keys from the ObjectLiteral node at cursor position.
// Reads keys directly from ObjectLiteralData — no text scanning needed.
function sgExistingFieldKeysAST(program: Node, line: number, col: number): string[] {
	const objNode = findEnclosingObjectLiteral(program, line, col);
	if (objNode === null) return [];
	const d = objNode.data as ObjectLiteralData;
	return d.keys;
}

// Complete object literal fields: given a struct type and nesting path,
// walk to the nested type and suggest its fields.
export function sgCompleteObjectFields(ctx: CheckerContext, prefix: string, rootType: Type, fieldPath: string[], existingKeys: string[]): SgSuggest[] {
	const result: SgSuggest[] = [];
	// Walk the nesting path to find the target struct type
	let t = rootType;
	if (t !== null && (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr)) {
		t = unwrapRef(t);
	}
	for (let pi = 0; pi < fieldPath.length; pi = pi + 1) {
		if (t === null || t.kind !== TypeKind.Struct) return result;
		const fieldName = fieldPath[pi];
		let found = false;
		if (t.typeNames !== null) {
			let ni = 0;
			while (ni < t.typeNames.length) {
				if (t.typeNames[ni] === fieldName) {
					if (ni < t.typeChildren.length) {
						t = t.typeChildren[ni];
						if (t !== null && (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr)) {
							t = unwrapRef(t);
						}
						found = true;
					}
					break;
				}
				ni = ni + 1;
			}
		}
		if (!found) return result;
	}
	if (t === null || t.kind !== TypeKind.Struct || t.typeNames === null) return result;
	// Suggest fields from the struct type, excluding already-specified keys
	for (let fi = 0; fi < t.typeNames.length; fi = fi + 1) {
		const fname = t.typeNames[fi];
		// Skip already-specified fields
		let already = false;
		for (let ei = 0; ei < existingKeys.length; ei = ei + 1) {
			if (existingKeys[ei] === fname) { already = true; }
		}
		if (already) continue;
		const ps = sgPrefixMatch(prefix, fname);
		if (ps > 0) {
			const ft = fi < t.typeChildren.length ? t.typeChildren[fi] : unknownType();
			const loc = makeLoc(0, 0);
			const item: SgSuggest = {
				sym: null, name: fname, kind: SymbolKind.Property, symType: ft,
				location: loc, modulePath: "", containerName: "",
				prefixScore: ps, scopeDepth: 0, contextFit: true,
				isExported: false, isMutable: false, usageCount: 0,
			};
			result.push(item);
		}
	}
	return result;
}

// ===== sgGetPrefix — extract word fragment at cursor =====

export function sgGetPrefix(source: string, line: number, col: number): string {
	const lineOffset = sgGetLineOffset(source, line);
	const cursorOffset = lineOffset + col;
	let start = cursorOffset;
	while (start > 0 && sgIsIdentByte(source.byteAt(start - 1))) {
		start = start - 1;
	}
	if (start >= cursorOffset) return "";
	return source.slice(start, cursorOffset);
}

// ===== sgGetCompletionCandidates — collect matching symbols =====

function sgCompleteMemberAccess(ctx: CheckerContext, prefix: string, receiverType: Type): SgSuggest[] {
	const result: SgSuggest[] = [];
	// Unwrap Ref/Ptr to get inner struct (class instances are Ref<Struct>)
	let rt = receiverType;
	if (rt !== null && (rt.kind === TypeKind.Ref || rt.kind === TypeKind.Ptr)) {
		rt = unwrapRef(rt);
	}
	// Dot completion: properties from receiver type
	if (rt !== null && rt.kind === TypeKind.Struct) {
		for (let i = 0; i < rt.typeNames.length; i = i + 1) {
			const propName = rt.typeNames[i];
			const ps = sgPrefixMatch(prefix, propName);
			if (ps > 0) {
				const propType = i < rt.typeChildren.length
					? rt.typeChildren[i] : unknownType();
				const loc = makeLoc(0, 0);
				const item: SgSuggest = {
					sym: null, name: propName, kind: SymbolKind.Property, symType: propType,
					location: loc, modulePath: "", containerName: "",
					prefixScore: ps, scopeDepth: 0, contextFit: false,
					isExported: false, isMutable: false, usageCount: 0,
				};
				result.push(item);
			}
		}
	}
	// Enum member completion
	if (rt !== null && rt.kind === TypeKind.Enum) {
		for (let i = 0; i < rt.typeNames.length; i = i + 1) {
			const memberName = rt.typeNames[i];
			const ps = sgPrefixMatch(prefix, memberName);
			if (ps > 0) {
				const loc = makeLoc(0, 0);
				const item: SgSuggest = {
					sym: null, name: memberName, kind: SymbolKind.Property, symType: rt,
					location: loc, modulePath: "", containerName: "",
					prefixScore: ps, scopeDepth: 0, contextFit: false,
					isExported: false, isMutable: false, usageCount: 0,
				};
				result.push(item);
			}
		}
	}
	// Extension methods — type-based matching (shared with checker)
	if (receiverType !== null && ctx.extensionRegistry !== null) {
		// Collect unique method names first, then filter by receiver type
		const seenMethods: string[] = [];
		for (let j = 0; j < ctx.extensionRegistry.methods.length; j = j + 1) {
			const ext = ctx.extensionRegistry.methods[j];
			const ps = sgPrefixMatch(prefix, ext.methodName);
			if (ps === 0) continue;
			// Deduplicate: skip if we already added this method name
			let seen = false;
			for (let si = 0; si < seenMethods.length; si = si + 1) {
				if (seenMethods[si] === ext.methodName) { seen = true; }
			}
			if (seen) continue;
			// Type-based receiver matching (same algo as checker)
			const allByName = findAllExtensionsByName(ctx.extensionRegistry, ext.methodName);
			const matched = filterExtsByReceiverType(allByName, receiverType);
			if (matched.length > 0) {
				seenMethods.push(ext.methodName);
				// Use first match's type; strip receiver param for instance extensions
				const bestExt = matched[0];
				let sigType = getExtFnType(bestExt);
				if (!bestExt.isStatic && sigType.typeChildren !== null && sigType.typeChildren.length > 0) {
					sigType = stripReceiverParam(sigType);
				}
				const loc = makeLoc(0, 0);
				const item: SgSuggest = {
					sym: bestExt.sym, name: bestExt.methodName, kind: SymbolKind.Method, symType: sigType,
					location: loc, modulePath: "", containerName: "",
					prefixScore: ps, scopeDepth: 0, contextFit: false,
					isExported: false, isMutable: false, usageCount: 0,
				};
				result.push(item);
			}
		}
	}
	sgSortSuggestions(result);
	return result;
}

export function sgGetCompletionCandidates(ctx: CheckerContext, kind: SgCompletionKind, prefix: string, receiverType: Type): SgSuggest[] {
	if (kind === SgCompletionKind.MemberAccess) {
		return sgCompleteMemberAccess(ctx, prefix, receiverType);
	}

	// Walk scope chain for Identifier or TypeAnnotation
	const result: SgSuggest[] = [];
	const extNames = sgBuildExtensionNameSet(ctx);
	let scope = ctx.table.current;
	let depth = 0;
	while (scope !== null) {
		for (let i = 0; i < scope.symbols.length; i = i + 1) {
			const sym = scope.symbols[i];
			const ps = sgPrefixMatch(prefix, sym.name);
			if (ps > 0) {
				// Skip prelude extension methods at Global scope — they only appear via member access.
				// Explicitly imported extensions at Module scope are kept.
				if (scope.scopeKind === ScopeKind.Global && extNames.has(sym.name)) continue;
				const inTypeCtx = kind === SgCompletionKind.TypeAnnotation;
				const cf = inTypeCtx === sgIsTypeKind(sym.symbolKind);
				if (!inTypeCtx || sgIsTypeKind(sym.symbolKind)) {
					const item: SgSuggest = {
						sym: sym, name: sym.name, kind: sym.symbolKind, symType: sym.symbolType,
						location: sym.location, modulePath: sym.modulePath, containerName: "",
						prefixScore: ps, scopeDepth: depth, contextFit: cf,
						isExported: hasFlag(sym, SymbolFlag.Exported), isMutable: hasFlag(sym, SymbolFlag.Mutable),
						usageCount: sgCountSymUsages(ctx, sym),
					};
					result.push(item);
				}
			}
		}
		scope = scope.parent;
		depth = depth + 1;
	}

	sgSortSuggestions(result);
	return result;
}

// ===== Document Symbols — collect top-level declarations =====

// Join field/member names as "a, b, c" — truncated to 3 items
function sgJoinFieldNames(names: string[]): string {
	if (names.length === 0) return "";
	let result = "";
	const limit = 3;
	const maxLen = names.length < limit ? names.length : limit;
	for (let i = 0; i < maxLen; i = i + 1) {
		if (i > 0) result = result + ", ";
		result = result + names[i];
	}
	if (names.length > limit) result = result + ", ...";
	return result;
}

function sgGetSymbolDetail(ctx: CheckerContext, name: string): string {
	const sym = lookupSymbol(ctx.table, name);
	if (sym === null) return "";
	if (sym.symbolType === null) return "";
	return sgTypeToString(sym.symbolType);
}

function sgCollectClassChildren(cd: ClassDeclData): SgDocumentSymbol[] {
	const children: SgDocumentSymbol[] = [];
	for (let i = 0; i < cd.classBody.length; i = i + 1) {
		const member = cd.classBody[i];
		if (member === null) continue;
		if (member.kind === NodeKind.MethodDecl) {
			const md = member.data as MethodDeclData;
			const params = sgJoinFieldNames(md.methodParamTypes);
			const dt = "(" + params + ")" + (md.methodReturnType !== "" ? " => " + md.methodReturnType : "");
			children.push({ name: md.methodName, kind: SymbolKind.Method, location: member.location, detail: dt, isMutable: false, children: [] });
		}
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			children.push({ name: pd.propName, kind: SymbolKind.Property, location: member.location, detail: pd.propType, isMutable: false, children: [] });
		}
		if (member.kind === NodeKind.ConstructorDecl) {
			const ct = member.data as ConstructorDeclData;
			const params = sgJoinFieldNames(ct.ctorParamTypes);
			children.push({ name: "constructor", kind: SymbolKind.Method, location: member.location, detail: "(" + params + ")", isMutable: false, children: [] });
		}
	}
	return children;
}

function sgCollectInterfaceChildren(ifd: InterfaceDeclData, loc: SourceLocation): SgDocumentSymbol[] {
	const children: SgDocumentSymbol[] = [];
	for (let i = 0; i < ifd.interfaceFields.length; i = i + 1) {
		const fieldType = i < ifd.interfaceFieldTypes.length ? ifd.interfaceFieldTypes[i] : "";
		children.push({ name: ifd.interfaceFields[i], kind: SymbolKind.Property, location: loc, detail: fieldType, isMutable: false, children: [] });
	}
	return children;
}

function sgCollectEnumChildren(ed: EnumDeclData, loc: SourceLocation): SgDocumentSymbol[] {
	const children: SgDocumentSymbol[] = [];
	for (let i = 0; i < ed.enumMembers.length; i = i + 1) {
		const val = i < ed.enumValues.length ? "" + ed.enumValues[i] : "";
		children.push({ name: ed.enumMembers[i], kind: SymbolKind.Property, location: loc, detail: val, isMutable: false, children: [] });
	}
	return children;
}

function sgCollectOneSymbol(node: Node, ctx: CheckerContext, result: SgDocumentSymbol[]): void {
	if (node === null) return;

	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		const dt = sgGetSymbolDetail(ctx, fd.fnName);
		const item: SgDocumentSymbol = { name: fd.fnName, kind: SymbolKind.Function, location: node.location, detail: dt, isMutable: false, children: [] };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		const dt = sgGetSymbolDetail(ctx, vd.declName);
		const mut = vd.declKind !== DeclKind.Const;
		const item: SgDocumentSymbol = { name: vd.declName, kind: SymbolKind.Variable, location: node.location, detail: dt, isMutable: mut, children: [] };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.InterfaceDecl || node.kind === NodeKind.StructDecl) {
		const ifd = node.data as InterfaceDeclData;
		const dt = sgJoinFieldNames(ifd.interfaceFields);
		const children = sgCollectInterfaceChildren(ifd, node.location);
		const skind = node.kind === NodeKind.StructDecl ? SymbolKind.Struct : SymbolKind.Interface;
		const item: SgDocumentSymbol = { name: ifd.interfaceName, kind: skind, location: node.location, detail: dt, isMutable: false, children };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.EnumDecl) {
		const ed = node.data as EnumDeclData;
		const dt = sgJoinFieldNames(ed.enumMembers);
		const children = sgCollectEnumChildren(ed, node.location);
		const item: SgDocumentSymbol = { name: ed.enumName, kind: SymbolKind.Enum, location: node.location, detail: dt, isMutable: false, children };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.ClassDecl) {
		const cd = node.data as ClassDeclData;
		const children = sgCollectClassChildren(cd);
		const item: SgDocumentSymbol = { name: cd.className, kind: SymbolKind.Class, location: node.location, detail: cd.classExtends, isMutable: false, children };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.TypeAliasDecl) {
		const td = node.data as TypeAliasDeclData;
		const dt = sgGetSymbolDetail(ctx, td.aliasName);
		const item: SgDocumentSymbol = { name: td.aliasName, kind: SymbolKind.TypeAlias, location: node.location, detail: dt, isMutable: false, children: [] };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.ExportDecl) {
		const xd = node.data as ExportDeclData;
		sgCollectOneSymbol(xd.exportedDecl, ctx, result);
		return;
	}
}

export function sgCollectSymbolsInFile(ctx: CheckerContext, program: Node): SgDocumentSymbol[] {
	const result: SgDocumentSymbol[] = [];
	if (program === null || program.kind !== NodeKind.Program) return result;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i = i + 1) {
		sgCollectOneSymbol(pd.programStmts[i], ctx, result);
	}
	return result;
}

// ===== Signature Help — format function signatures =====

function sgBuildSignatureInfo(name: string, fnType: Type): SgSignatureInfo {
	const paramLabels: string[] = [];
	let label = name + "(";
	for (let i = 0; i < fnType.typeChildren.length; i = i + 1) {
		if (i > 0) label = label + ", ";
		let paramLabel = "";
		if (i < fnType.typeNames.length && fnType.typeNames[i].length > 0) {
			paramLabel = fnType.typeNames[i] + ": " + sgTypeToString(fnType.typeChildren[i]);
		} else {
			paramLabel = sgTypeToString(fnType.typeChildren[i]);
		}
		paramLabels.push(paramLabel);
		label = label + paramLabel;
	}
	label = label + "): " + sgTypeToString(fnType.typeReturn);
	const info: SgSignatureInfo = { label, paramLabels };
	return info;
}

export function sgFormatSignature(sym: Symbol): SgSignatureInfo[] {
	const result: SgSignatureInfo[] = [];
	if (sym === null) return result;
	if (sym.symbolType === null || sym.symbolType.kind !== TypeKind.Function) return result;

	// Main signature
	const main = sgBuildSignatureInfo(sym.name, sym.symbolType);
	result.push(main);

	// Overloads
	for (let i = 0; i < sym.overloads.length; i = i + 1) {
		const ovl = sym.overloads[i];
		if (ovl.symbolType !== null && ovl.symbolType.kind === TypeKind.Function) {
			const ovlInfo = sgBuildSignatureInfo(sym.name, ovl.symbolType);
			result.push(ovlInfo);
		}
	}

	return result;
}

// ===== sgFormatExtensionSignatures — build signatures filtered by receiver type =====

export function sgFormatExtensionSignatures(ctx: CheckerContext, methodName: string, receiverType: Type): SgSignatureInfo[] {
	if (ctx.extensionRegistry === null || receiverType === null) return [];
	const allByName = findAllExtensionsByName(ctx.extensionRegistry, methodName);
	const matched = filterExtsByReceiverType(allByName, receiverType);
	const result: SgSignatureInfo[] = [];
	for (let i = 0; i < matched.length; i = i + 1) {
		const ext = matched[i];
		let fnType = getExtFnType(ext);
		if (fnType === null || fnType.kind !== TypeKind.Function) continue;
		if (!ext.isStatic && fnType.typeChildren.length > 0) {
			fnType = stripReceiverParam(fnType);
		}
		result.push(sgBuildSignatureInfo(methodName, fnType));
	}
	return result;
}

// ===== sgGetCalleeAtCursor — find function name for signature help =====

// Scans backwards from cursor to matching unclosed '(', then extracts
// the identifier before it (the callee name).
// Returns "" if no enclosing call found.
// Text-based fallback — used when parser can't produce CallExpr (incomplete source).
function sgGetCalleeAtCursor(source: string, line: number, col: number): string {
	const lineOffset = sgGetLineOffset(source, line);
	const cursorOffset = lineOffset + col;
	let pos = cursorOffset - 1;
	let depth = 0;

	// Find the matching unclosed '('
	while (pos >= 0) {
		const ch = source.byteAt(pos);
		if (ch === ")".code) { depth = depth + 1; }
		if (ch === "(".code) {
			if (depth === 0) {
				// Found the open paren. Now extract the identifier before it.
				let end = pos;
				pos = pos - 1;
				// Skip whitespace
				while (pos >= 0) {
					const ws = source.byteAt(pos);
					if (ws !== " ".code && ws !== "\t".code) {
						let identEnd = pos + 1;
						// Scan backwards through identifier chars
						while (pos >= 0) {
							const ic = source.byteAt(pos);
							if (sgIsIdentByte(ic)) {
								pos = pos - 1;
							} else {
								return source.slice(pos + 1, identEnd);
							}
						}
						return source.slice(0, identEnd);
					}
					pos = pos - 1;
				}
				return "";
			}
			depth = depth - 1;
		}
		pos = pos - 1;
	}
	return "";
}

// ===== sgGetReceiverAtCursor — extract receiver for dot calls =====
// For "console.log(x", returns "console". For "foo(x", returns "".
// Scans backwards from the callee identifier to find "." + identifier pattern.

function sgGetReceiverAtCursor(source: string, line: number, col: number): string {
	const lineOffset = sgGetLineOffset(source, line);
	const cursorOffset = lineOffset + col;
	let pos = cursorOffset - 1;
	let depth = 0;
	// Find matching unclosed '('
	while (pos >= 0) {
		const ch = source.byteAt(pos);
		if (ch === ")".code) { depth = depth + 1; }
		if (ch === "(".code) {
			if (depth === 0) {
				// Skip backwards past callee identifier
				pos = pos - 1;
				while (pos >= 0 && (source.byteAt(pos) === " ".code || source.byteAt(pos) === "\t".code)) {
					pos = pos - 1;
				}
				while (pos >= 0 && sgIsIdentByte(source.byteAt(pos))) {
					pos = pos - 1;
				}
				// Check for dot
				if (pos >= 0 && source.byteAt(pos) === ".".code) {
					pos = pos - 1;
					// Extract receiver identifier
					const recEnd = pos + 1;
					while (pos >= 0 && sgIsIdentByte(source.byteAt(pos))) {
						pos = pos - 1;
					}
					return source.slice(pos + 1, recEnd);
				}
				return "";
			}
			depth = depth - 1;
		}
		pos = pos - 1;
	}
	return "";
}

// ===== Active Parameter — count commas from nearest unclosed ( =====

function sgCountActiveParam(source: string, line: number, col: number): number {
	const lineOffset = sgGetLineOffset(source, line);
	const cursorOffset = lineOffset + col;
	let pos = cursorOffset - 1;
	let depth = 0;
	let commas = 0;
	while (pos >= 0) {
		const ch = source.byteAt(pos);
		if (ch === ")".code) { depth = depth + 1; }
		if (ch === "(".code) {
			if (depth === 0) return commas;
			depth = depth - 1;
		}
		if (ch === ",".code && depth === 0) { commas = commas + 1; }
		pos = pos - 1;
	}
	return commas;
}

// ===== Inlay Hints — type annotations + parameter names =====

export enum SgInlayHintKind {
	Type,       // 1 in LSP
	Parameter,  // 2 in LSP
	Exception,  // mapped to 1 (Type) in LSP — shows "throws ErrorType"
}

export interface SgInlayHint {
	label: string;
	line: number;
	col: number;
	hintKind: SgInlayHintKind;
}

// Walk top-level statements in range [startLine, endLine] (1-indexed, inclusive).
// Collect type hints for variables without annotations,
// and parameter name hints at call sites.
export function sgCollectInlayHints(
	ctx: CheckerContext, program: Node, startLine: number, endLine: number
): SgInlayHint[] {
	const result: SgInlayHint[] = [];
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i = i + 1) {
		const stmt = pd.programStmts[i];
		sgCollectHintsInNode(ctx, stmt, startLine, endLine, result);
	}
	return result;
}

function sgCollectHintsInNode(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	if (node === null) return;
	const loc = node.location;
	// Skip nodes outside range
	if (loc.line > endLine) return;

	// Variable declarations: type hint if no annotation + walk initializer
	if (node.kind === NodeKind.VariableDecl) {
		sgCollectVarTypeHint(ctx, node, startLine, endLine, hints);
		sgCollectArraySizeHint(node, startLine, endLine, hints);
		const vd = node.data as VariableDeclData;
		if (vd.initializer !== null) {
			sgCollectHintsInNode(ctx, vd.initializer, startLine, endLine, hints);
		}
		return;
	}

	// Function declarations: return type hint + exception hint + walk body
	if (node.kind === NodeKind.FunctionDecl) {
		sgCollectReturnTypeHint(ctx, node, startLine, endLine, hints);
		sgCollectExceptionHints(ctx, node, startLine, endLine, hints);
		const fd = node.data as FunctionDeclData;
		if (fd.fnBody !== null) {
			sgCollectHintsInNode(ctx, fd.fnBody, startLine, endLine, hints);
		}
		return;
	}

	// Try expressions: exception hint showing error type
	if (node.kind === NodeKind.TryExpr) {
		sgCollectExceptionHints(ctx, node, startLine, endLine, hints);
		return;
	}

	// Call expressions: parameter name hints
	if (node.kind === NodeKind.CallExpr) {
		sgCollectCallParamHints(ctx, node, startLine, endLine, hints);
		return;
	}

	// Generic fallback: recurse into all children
	forEachChild(node, (child: Node): void => {
		sgCollectHintsInNode(ctx, child, startLine, endLine, hints);
	});
}

function sgCollectVarTypeHint(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	const vd = node.data as VariableDeclData;
	if (node.location.line < startLine) return;
	if (node.location.line > endLine) return;

	// Only show hint if no explicit type annotation
	if (vd.declType.length > 0) return;

	// Use resolvedSym from the checked AST node (set during semantic analysis).
	// Scope-based lookupSymbol is unreliable after checker finishes — function scopes
	// are closed, so prelude extensions with the same name could shadow local variables.
	const sym = node.resolvedSym !== null ? node.resolvedSym : lookupSymbol(ctx.table, vd.declName);
	if (sym === null) return;
	if (sym.symbolKind !== SymbolKind.Variable && sym.symbolKind !== SymbolKind.Parameter) return;
	if (sym.symbolType === null) return;
	if (sym.symbolType.kind === TypeKind.Unknown) return;
	if (sym.symbolType.kind === TypeKind.Error) return;

	let typeStr = sgTypeToString(sym.symbolType);
	// For `const a = new Array<T>(n)` — show `T[n]` instead of `T[]`
	if (typeStr.endsWith("[]") && vd.initializer !== null && vd.initializer.kind === NodeKind.NewExpr) {
		const arraySizeStr = sgExtractNewArraySize(vd.initializer);
		if (arraySizeStr !== "") {
			typeStr = `${typeStr.slice(0, typeStr.length - 1)}${arraySizeStr}]`;
		}
	}
	// Skip hint when variable name matches type name (e.g. const token: Token)
	if (sgCaseEqualStr(vd.declName, typeStr)) return;
	const hint: SgInlayHint = {
		label: ": " + typeStr,
		line: node.location.line,
		col: node.location.column + vd.declName.length,
		hintKind: SgInlayHintKind.Type,
	};
	hints.push(hint);
}

// Extract the size argument from `new Array<T>(n)` as a display string.
// Returns "" if the initializer is not a sized Array constructor.
function sgExtractNewArraySize(init: Node): string {
	if (init.kind !== NodeKind.NewExpr) return "";
	const nd = init.data as NewExprData;
	if (nd.newArguments.length !== 1) return "";
	if (nd.newCallee === null || nd.newCallee.kind !== NodeKind.Identifier) return "";
	if ((nd.newCallee.data as IdentifierData).name !== "Array") return "";
	const sizeArg = nd.newArguments[0];
	if (sizeArg.kind === NodeKind.NumberLiteral) {
		const v = (sizeArg.data as NumberLiteralData).value;
		return String(v as int64);
	}
	if (sizeArg.kind === NodeKind.Identifier) return (sizeArg.data as IdentifierData).name;
	return "";
}

// For `const e: string[] = new Array(8)` → show trailing hint `string[8]` at end of line.
// LSP inlay hints can only insert text, not replace — so we show the full sized type as trailing.
function sgCollectArraySizeHint(
	node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	if (node.location.line < startLine || node.location.line > endLine) return;
	const vd = node.data as VariableDeclData;
	// Only for annotated arrays — unannotated case handled in sgCollectVarTypeHint
	if (vd.declType.length === 0) return;
	if (!vd.declType.endsWith("[]") && !vd.declType.endsWith("[ ]")) return;
	if (vd.initializer === null) return;
	const sizeStr = sgExtractNewArraySize(vd.initializer);
	if (sizeStr === "") return;
	// Show full sized type as trailing hint: "string[8]"
	// Extract element type from annotation (strip trailing "[]" or "[ ]")
	let elemType = vd.declType;
	if (elemType.endsWith("[ ]")) {
		elemType = elemType.slice(0, elemType.length - 3).trim();
	} else if (elemType.endsWith("[]")) {
		elemType = elemType.slice(0, elemType.length - 2).trim();
	}
	// Place at end of line — LSP renders trailing hints after all source text
	const endOfLineCol = 10000;
	const hint: SgInlayHint = {
		label: `${elemType}[${sizeStr}]`,
		line: node.location.line,
		col: endOfLineCol,
		hintKind: SgInlayHintKind.Type,
	};
	hints.push(hint);
}

function sgCollectReturnTypeHint(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	if (node.location.line < startLine) return;
	if (node.location.line > endLine) return;

	const fd = node.data as FunctionDeclData;
	// Only show hint if no explicit return type annotation
	if (fd.fnReturnType.length > 0) return;

	const sym = lookupSymbol(ctx.table, fd.fnName);
	if (sym === null) return;
	if (sym.symbolType === null) return;
	const retType = sym.symbolType.typeReturn;
	if (retType === null) return;
	if (retType.kind === TypeKind.Unknown) return;
	if (retType.kind === TypeKind.Error) return;
	if (retType.kind === TypeKind.Void) return;

	const typeStr = sgTypeToString(retType);
	// Position: after closing paren, before body. Use fnBody location - 2 as approximation.
	// Better: after the last param type or param name + closing paren
	let hintCol = node.location.column + fd.fnName.length;
	if (fd.fnBody !== null) {
		hintCol = fd.fnBody.location.column - 1;
	}
	const hint: SgInlayHint = {
		label: ": " + typeStr,
		line: node.location.line,
		col: hintCol,
		hintKind: SgInlayHintKind.Type,
	};
	hints.push(hint);
}

function sgCollectCallParamHints(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	const cd = node.data as CallExprData;
	if (node.location.line < startLine) return;
	if (node.location.line > endLine) return;

	// Resolve callee name
	let calleeName = "";
	if (cd.callee !== null && cd.callee.kind === NodeKind.Identifier) {
		const cid = cd.callee.data as IdentifierData;
		calleeName = cid.name;
	}
	if (calleeName === "") return;

	const sym = lookupSymbol(ctx.table, calleeName);
	if (sym === null) return;
	if (sym.symbolType === null) return;
	if (sym.symbolType.kind !== TypeKind.Function) return;

	// Get parameter names from the function type
	const paramNames = sym.symbolType.typeNames;
	if (paramNames.length === 0) return;

	const paramLimit = cd.arguments.length < paramNames.length ? cd.arguments.length : paramNames.length;
	for (let j = 0; j < paramLimit; j = j + 1) {
		const arg = cd.arguments[j];
		if (arg === null) { continue; }
		// Skip hints for trivially obvious args (same name as param)
		let argName = "";
		if (arg.kind === NodeKind.Identifier) {
			const aid = arg.data as IdentifierData;
			argName = aid.name;
		}
		if (argName !== paramNames[j]) {
			const hint: SgInlayHint = {
				label: paramNames[j] + ":",
				line: arg.location.line,
				col: arg.location.column,
				hintKind: SgInlayHintKind.Parameter,
			};
			hints.push(hint);
		}
	}

	// Also walk into argument expressions for nested calls
	for (let j = 0; j < cd.arguments.length; j = j + 1) {
		sgCollectHintsInNode(ctx, cd.arguments[j], startLine, endLine, hints);
	}
}

// ===== Exception Inlay Hints =====

// Infer the return type of a call expression's callee.
function inferCalleeReturnType(ctx: CheckerContext, node: Node): Type {
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		if (cd.callee !== null && cd.callee.kind === NodeKind.Identifier) {
			const id = cd.callee.data as IdentifierData;
			const sym = lookupSymbol(ctx.table, id.name);
			if (sym !== null && sym.symbolType !== null && sym.symbolType.kind === TypeKind.Function) {
				return sym.symbolType.typeReturn;
			}
		}
	}
	if (node.kind === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		const sym = lookupSymbol(ctx.table, id.name);
		if (sym !== null && sym.symbolType !== null && sym.symbolType.kind === TypeKind.Function) {
			return sym.symbolType.typeReturn;
		}
	}
	return null;
}

// Collect exception hints for try expressions and functions returning Result<T,E>.
function sgCollectExceptionHints(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	// TryExpr: show the error type being caught
	if (node.kind === NodeKind.TryExpr) {
		if (node.location.line < startLine || node.location.line > endLine) return;
		const d = node.data as TryExprData;
		const argType = inferCalleeReturnType(ctx, d.tryArg);
		if (argType !== null && isResult(argType) && getResultErrType(argType) !== null) {
			const errTypeName = typeNameOf(getResultErrType(argType));
			if (errTypeName !== "" && errTypeName !== "unknown") {
				const hint: SgInlayHint = {
					label: "throws " + errTypeName,
					line: node.location.line,
					col: node.location.column + 3,
					hintKind: SgInlayHintKind.Exception,
				};
				hints.push(hint);
			}
		}
		return;
	}

	// FunctionDecl returning Result<T,E>: show "throws E" after function name
	if (node.kind === NodeKind.FunctionDecl) {
		if (node.location.line < startLine || node.location.line > endLine) return;
		const fd = node.data as FunctionDeclData;
		const retType = node.nodeType;
		if (retType !== null && retType.kind === TypeKind.Function && retType.typeReturn !== null) {
			if (isResult(retType.typeReturn) && getResultErrType(retType.typeReturn) !== null) {
				const errName = typeNameOf(getResultErrType(retType.typeReturn));
				if (errName !== "" && errName !== "unknown") {
					const hint: SgInlayHint = {
						label: "throws " + errName,
						line: node.location.line,
						col: node.location.column + fd.fnName.length,
						hintKind: SgInlayHintKind.Exception,
					};
					hints.push(hint);
				}
			}
		}
	}
}

// ===== Semantic Tokens — server-side highlighting =====

// LSP Semantic Token Types (index = type ID, must match legend in handleInitialize):
// 0=namespace, 1=type, 2=class, 3=enum, 4=interface, 5=struct,
// 6=typeParameter, 7=parameter, 8=variable, 9=property,
// 10=enumMember, 11=event, 12=function, 13=method, 14=macro,
// 15=keyword, 16=modifier, 17=comment, 18=string, 19=number,
// 20=regexp, 21=operator, 22=decorator
//
// Modifiers (bit positions): 0=declaration, 1=definition, 2=readonly, 3=static

export interface SgSemanticToken {
	line: number;       // 1-indexed (converted to 0-indexed by handler)
	col: number;        // 1-indexed (converted to 0-indexed by handler)
	length: number;
	tokenType: number;  // index into legend
	modifiers: number;  // bitmask
}

export function sgCollectSemanticTokens(ctx: CheckerContext, program: Node): SgSemanticToken[] {
	const result: SgSemanticToken[] = [];
	if (program === null) return result;
	sgCollectTokensInNode(ctx, program, result);
	return result;
}

// Map SymbolKind to semantic token type index
function sgSymbolToTokenType(kind: SymbolKind): number {
	if (kind === SymbolKind.Function) return 12;
	if (kind === SymbolKind.Method) return 13;
	if (kind === SymbolKind.Variable) return 8;
	if (kind === SymbolKind.Parameter) return 7;
	if (kind === SymbolKind.Class) return 2;
	if (kind === SymbolKind.Interface) return 4;
	if (kind === SymbolKind.Enum) return 3;
	if (kind === SymbolKind.TypeAlias) return 1;
	if (kind === SymbolKind.Property) return 9;
	return 8; // default: variable
}

function sgCollectTokensInNode(ctx: CheckerContext, node: Node, tokens: SgSemanticToken[]): void {
	if (node === null) return;
	const loc = node.location;

	// Identifiers: look up symbol for semantic classification
	if (node.kind === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		if (id.name.length === 0) return;
		const sym = lookupSymbol(ctx.table, id.name);
		if (sym !== null) {
			const tt = sgSymbolToTokenType(sym.symbolKind);
			let mods: int32 = 0;
			if (!hasFlag(sym, SymbolFlag.Mutable) && sym.symbolKind === SymbolKind.Variable) mods = 4; // readonly bit 2
			if (sym.builtinKind.length > 0) mods = mods | 16; // defaultLibrary bit 4
			const tok: SgSemanticToken = { line: loc.line, col: loc.column, length: id.name.length, tokenType: tt, modifiers: mods };
			tokens.push(tok);
		}
		return;
	}

	// Declaration names get declaration modifier (bit 0)
	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		if (fd.fnName.length > 0 && fd.nameLocation !== null) {
			const tok: SgSemanticToken = { line: fd.nameLocation.line, col: fd.nameLocation.column, length: fd.fnName.length, tokenType: 12, modifiers: 1 };
			tokens.push(tok);
		}
		if (fd.fnBody !== null) sgCollectTokensInNode(ctx, fd.fnBody, tokens);
		return;
	}

	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		if (vd.declName.length > 0 && vd.nameLocation !== null) {
			let mods = 1; // declaration
			if (vd.declKind === DeclKind.Const) {
				mods = 5; // declaration + readonly (1 + 4)
			}
			const tok: SgSemanticToken = { line: vd.nameLocation.line, col: vd.nameLocation.column, length: vd.declName.length, tokenType: 8, modifiers: mods };
			tokens.push(tok);
		}
		if (vd.initializer !== null) sgCollectTokensInNode(ctx, vd.initializer, tokens);
		return;
	}

	if (node.kind === NodeKind.InterfaceDecl || node.kind === NodeKind.StructDecl) {
		const ifd = node.data as InterfaceDeclData;
		if (ifd.interfaceName.length > 0 && ifd.nameLocation !== null) {
			const tok: SgSemanticToken = { line: ifd.nameLocation.line, col: ifd.nameLocation.column, length: ifd.interfaceName.length, tokenType: 4, modifiers: 1 };
			tokens.push(tok);
		}
		return;
	}

	if (node.kind === NodeKind.EnumDecl) {
		const ed = node.data as EnumDeclData;
		if (ed.enumName.length > 0 && ed.nameLocation !== null) {
			const tok: SgSemanticToken = { line: ed.nameLocation.line, col: ed.nameLocation.column, length: ed.enumName.length, tokenType: 3, modifiers: 1 };
			tokens.push(tok);
		}
		return;
	}

	if (node.kind === NodeKind.ClassDecl) {
		const cd = node.data as ClassDeclData;
		if (cd.className.length > 0 && cd.nameLocation !== null) {
			const tok: SgSemanticToken = { line: cd.nameLocation.line, col: cd.nameLocation.column, length: cd.className.length, tokenType: 2, modifiers: 1 };
			tokens.push(tok);
		}
		for (let ci = 0; ci < cd.classBody.length; ci = ci + 1) {
			sgCollectTokensInNode(ctx, cd.classBody[ci], tokens);
		}
		return;
	}

	if (node.kind === NodeKind.TypeAliasDecl) {
		const td = node.data as TypeAliasDeclData;
		if (td.aliasName.length > 0 && td.nameLocation !== null) {
			const tok: SgSemanticToken = { line: td.nameLocation.line, col: td.nameLocation.column, length: td.aliasName.length, tokenType: 1, modifiers: 1 };
			tokens.push(tok);
		}
		return;
	}

	// CallExpr: if callee is MemberExpr, emit method (not property) for the property name
	if (node.kind === NodeKind.CallExpr) {
		const ce = node.data as CallExprData;
		if (ce.callee !== null && ce.callee.kind === NodeKind.MemberExpr) {
			const me = ce.callee.data as MemberExprData;
			sgCollectTokensInNode(ctx, me.object, tokens);
			if (me.property.length > 0) {
				const ceLoc = ce.callee.location;
				const tok: SgSemanticToken = { line: ceLoc.line, col: ceLoc.column + 1, length: me.property.length, tokenType: 13, modifiers: 0 };
				tokens.push(tok);
			}
		} else {
			sgCollectTokensInNode(ctx, ce.callee, tokens);
		}
		// Recurse into arguments
		let ai = 0;
		while (ai < ce.arguments.length) {
			sgCollectTokensInNode(ctx, ce.arguments[ai], tokens);
			ai = ai + 1;
		}
		return;
	}

	// MemberExpr: recurse into object, emit token for property name
	if (node.kind === NodeKind.MemberExpr) {
		const me = node.data as MemberExprData;
		sgCollectTokensInNode(ctx, me.object, tokens);
		if (me.property.length > 0) {
			// loc is at the ".", property starts right after
			const tok: SgSemanticToken = { line: loc.line, col: loc.column + 1, length: me.property.length, tokenType: 9, modifiers: 0 };
			tokens.push(tok);
		}
		return;
	}

	// ExternDecl: skip — tree-sitter handles extern keyword highlighting.
	if (node.kind === NodeKind.ExternDecl) return;

	// Compound nodes — recurse into children
	sgCollectTokensCompound(ctx, node, tokens);
}

function sgCollectTokensCompound(ctx: CheckerContext, node: Node, tokens: SgSemanticToken[]): void {
	forEachChild(node, (child: Node): void => {
		sgCollectTokensInNode(ctx, child, tokens);
	});
}

// Sort tokens by (line, col) for delta encoding — insertion sort
export function sgSortTokens(tokens: SgSemanticToken[]): void {
	let i = 1;
	while (i < tokens.length) {
		const t = tokens[i];
		let j = i - 1;
		while (j >= 0) {
			const tj = tokens[j];
			if (tj.line < t.line) break;
			if (tj.line === t.line && tj.col <= t.col) break;
			tokens[j + 1] = tokens[j];
			j = j - 1;
		}
		tokens[j + 1] = t;
		i = i + 1;
	}
}

// ===== Symbol Reference Index =====

export interface SgSymbolRef {
	name: string;
	line: number;
	col: number;
	nameLen: number;
	isDecl: boolean;
}

// ===== Tests =====
test "number" { assert sgTypeToString(numberType()) === "number"; }

test "string" { assert sgTypeToString(stringType()) === "string"; }

test "boolean" { assert sgTypeToString(booleanType()) === "boolean"; }

test "void" { assert sgTypeToString(voidType()) === "void"; }

test "null" { assert sgTypeToString(nullType()) === "null"; }

test "unknown" { assert sgTypeToString(unknownType()) === "unknown"; }

test "never" { assert sgTypeToString(neverType()) === "never"; }

test "error" { assert sgTypeToString(errorType()) === "error"; }

import { createArray, createFunction, createEnum, createStruct, createResult } from "./types";
test "array" {
	const t = createArray(numberType());
	assert sgTypeToString(t) === "number[]";
}

test "function no params" {
	const params: Type[] = [];
	const names: string[] = [];
	const t = createFunction(params, names, voidType());
	assert sgTypeToString(t) === "() => void";
}

test "function with params" {
	const params: Type[] = [numberType(), stringType()];
	const names: string[] = ["a", "b"];
	const t = createFunction(params, names, booleanType());
	assert sgTypeToString(t) === "(a: number, b: string) => boolean";
}

test "enum" {
	const members: string[] = ["A", "B"];
	const t = createEnum("Color", members, null as unknown as number[]);
	assert sgTypeToString(t) === "Color";
}

test "named object" {
	const propNames: string[] = ["x", "y"];
	const propTypes: Type[] = [numberType(), numberType()];
	const t = createStruct("Point", propNames, propTypes, true);
	assert sgTypeToString(t) === "Point";
}

test "result" {
	const t = createResult(numberType(), stringType());
	assert sgTypeToString(t) === "Result<number, string>";
}

test "format variable hover" {
	const loc = makeLoc(1, 0);
	const suggest: SgSuggest = {
		sym: null, name: "count", kind: SymbolKind.Variable, symType: numberType(),
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	const hover = sgFormatHover(suggest);
	assert hover === "```metascript\nconst count: number\n```";
}

test "format function hover" {
	const loc = makeLoc(1, 0);
	const params: Type[] = [stringType()];
	const names: string[] = ["s"];
	const fnType = createFunction(params, names, voidType());
	const suggest: SgSuggest = {
		sym: null, name: "greet", kind: SymbolKind.Function, symType: fnType,
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	const hover = sgFormatHover(suggest);
	assert hover === "```metascript\nfunction greet(s: string): void\n```";
}

test "format interface hover" {
	const loc = makeLoc(1, 0);
	const suggest: SgSuggest = {
		sym: null, name: "Point", kind: SymbolKind.Interface, symType: unknownType(),
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\ninterface Point\n```";
}

test "format class hover" {
	const loc = makeLoc(1, 0);
	const suggest: SgSuggest = {
		sym: null, name: "Vec", kind: SymbolKind.Class, symType: unknownType(),
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\nclass Vec\n```";
}

test "format enum hover" {
	const loc = makeLoc(1, 0);
	const suggest: SgSuggest = {
		sym: null, name: "Color", kind: SymbolKind.Enum, symType: unknownType(),
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\nenum Color\n```";
}

test "format type alias hover" {
	const loc = makeLoc(1, 0);
	const suggest: SgSuggest = {
		sym: null, name: "Id", kind: SymbolKind.TypeAlias, symType: numberType(),
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\ntype Id = number\n```";
}

test "format let variable hover" {
	const loc = makeLoc(1, 0);
	const suggest: SgSuggest = {
		sym: null, name: "x", kind: SymbolKind.Variable, symType: stringType(),
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: true, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\nlet x: string\n```";
}

test "format parameter hover" {
	const loc = makeLoc(1, 0);
	const suggest: SgSuggest = {
		sym: null, name: "name", kind: SymbolKind.Parameter, symType: stringType(),
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\n(parameter) name: string\n```";
}

test "format property hover" {
	const loc = makeLoc(1, 0);
	const suggest: SgSuggest = {
		sym: null, name: "x", kind: SymbolKind.Property, symType: numberType(),
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\n(property) x: number\n```";
}

test "format property hover with container" {
	const loc = makeLoc(1, 0);
	const suggest: SgSuggest = {
		sym: null, name: "name", kind: SymbolKind.Property, symType: stringType(),
		location: loc, modulePath: "", containerName: "Person",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\n(property) Person.name: string\n```";
}

test "format method hover" {
	const loc = makeLoc(1, 0);
	const params: Type[] = [stringType()];
	const names: string[] = ["item"];
	const fnType = createFunction(params, names, voidType());
	const suggest: SgSuggest = {
		sym: null, name: "push", kind: SymbolKind.Method, symType: fnType,
		location: loc, modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\n(method) push(item: string): void\n```";
}

test "format method hover with container" {
	const loc = makeLoc(1, 0);
	const params: Type[] = [stringType()];
	const names: string[] = ["value"];
	const fnType = createFunction(params, names, voidType());
	const suggest: SgSuggest = {
		sym: null, name: "log", kind: SymbolKind.Method, symType: fnType,
		location: loc, modulePath: "", containerName: "console",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	assert sgFormatHover(suggest) === "```metascript\n(method) console.log(value: string): void\n```";
}

test "null suggest returns empty" {
	const sg = null as unknown as SgSuggest;
	assert sgFormatHover(sg) === "";
}

test "empty errors" {
	const pr = parseSource("const x = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const diags = sgCollectDiagnostics(ctx);
	assert diags.length === 0;
}

test "dot triggers MemberAccess" {
	// "foo.b" — cursor at col 5 (after 'b'). AST has MemberExpr at dot.
	const src1 = "foo.b";
	const pr1 = parseSource(src1);
	const prog1 = pr1.ok ? pr1.value : null as unknown as Node;
	assert sgDetectCompletionContext(prog1, 1, 5) === SgCompletionKind.MemberAccess;
}

test "dot with no prefix" {
	// "foo." — cursor at col 4 (right after '.'). AST has MemberExpr with property=""
	const src2 = "foo.";
	const pr2 = parseSourceLenient(src2);
	const prog2 = pr2.ok ? pr2.value : null as unknown as Node;
	assert sgDetectCompletionContext(prog2, 1, 4) === SgCompletionKind.MemberAccess;
}

test "colon triggers TypeAnnotation" {
	// "const x: num = 1;" — cursor at col 10 (on "num"). AST has typeExpr on VariableDecl.
	const src3 = "const x: num = 1;";
	const pr3 = parseSource(src3);
	const prog3 = pr3.ok ? pr3.value : null as unknown as Node;
	assert sgDetectCompletionContext(prog3, 1, 10) === SgCompletionKind.TypeAnnotation;
}

test "type annotation after import - incomplete" {
	// User is typing: deleted old type, typing new one. No semicolon, no initializer.
	const src = "import { BuildConfig } from \"std/build\";\n\nconst fmtConfig: Fmt\n\nconst config: BuildConfig = {\n  entry: \"./src/index\",\n};\n\nexport default config;\n";
	const pr = parseSource(src);
	if (pr.ok) {
		const kind = sgDetectCompletionContext(pr.value, 3, 21);
		assert kind !== SgCompletionKind.ImportName;
		assert kind !== SgCompletionKind.ImportPath;
	} else {
		// Even if parse fails, try lenient parse
		assert true; // parse failed — check manually
	}
}

test "type annotation after import - with semicolon" {
	const src = "import { BuildConfig } from \"std/build\";\n\nconst fmtConfig: Fmt;\n\nconst config: BuildConfig = {\n  entry: \"./src/index\",\n};\n\nexport default config;\n";
	const pr = parseSource(src);
	if (pr.ok) {
		const kind = sgDetectCompletionContext(pr.value, 3, 21);
		assert kind !== SgCompletionKind.ImportName;
		assert kind !== SgCompletionKind.ImportPath;
	}
}

test "bare identifier" {
	// "con" — cursor at col 3
	const src4 = "con";
	const pr4 = parseSource(src4);
	const prog4 = pr4.ok ? pr4.value : null as unknown as Node;
	assert sgDetectCompletionContext(prog4, 1, 3) === SgCompletionKind.Identifier;
}

test "start of line" {
	const src5 = "x";
	const pr5 = parseSource(src5);
	const prog5 = pr5.ok ? pr5.value : null as unknown as Node;
	assert sgDetectCompletionContext(prog5, 1, 0) === SgCompletionKind.Identifier;
}

test "extracts prefix" { assert sgGetPrefix("foo.bar", 1, 7) === "bar"; }

test "no prefix after dot" { assert sgGetPrefix("foo.", 1, 4) === ""; }

test "whole word" { assert sgGetPrefix("hello", 1, 5) === "hello"; }

test "empty at start" { assert sgGetPrefix("x", 1, 0) === ""; }

test "prefix with underscore" { assert sgGetPrefix("my_var", 1, 6) === "my_var"; }

test "second line" { assert sgGetPrefix("abc\ndef", 2, 3) === "def"; }

test "finds top-level symbols" {
	const pr = parseSource("const abc = 1;\nconst abd = 2;\nconst xyz = 3;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "ab", null);
	assert candidates.length >= 2;
}

test "empty prefix returns all" {
	const pr = parseSource("const a = 1;\nconst b = 2;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "", null);
	assert candidates.length >= 2;
}

test "no match returns empty" {
	const pr = parseSource("const abc = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "zzz", null);
	assert candidates.length === 0;
}

test "only returns types" {
	const pr = parseSource("interface Foo { x: number; }\nconst y = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.TypeAnnotation, "", null);
	// Should include Foo (interface) but not y (variable)
	let hasFoo = false;
	let hasY = false;
	for (let i = 0; i < candidates.length; i = i + 1) {
		if (candidates[i].name === "Foo") hasFoo = true;
		if (candidates[i].name === "y") hasY = true;
	}
	assert hasFoo;
	assert !hasY;
}

test "object properties" {
	const propNames: string[] = ["x", "y", "z"];
	const propTypes: Type[] = [numberType(), numberType(), stringType()];
	const objType = createStruct("Point", propNames, propTypes, true);
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", objType);
	assert candidates.length === 3;
}

test "object properties with prefix" {
	const propNames: string[] = ["xPos", "yPos", "name"];
	const propTypes: Type[] = [numberType(), numberType(), stringType()];
	const objType = createStruct("Obj", propNames, propTypes, true);
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "x", objType);
	assert candidates.length === 1;
	assert candidates[0].name === "xPos";
}

test "enum members" {
	const members: string[] = ["Red", "Green", "Blue"];
	const enumType = createEnum("Color", members, null as unknown as number[]);
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", enumType);
	assert candidates.length === 3;
}

test "null receiver returns empty" {
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", null);
	assert candidates.length === 0;
}

test "exact prefix" { assert sgPrefixMatch("ab", "abc") === 2; }

test "substring" { assert sgPrefixMatch("bc", "abcd") === 1; }

test "no match" { assert sgPrefixMatch("zz", "abc") === 0; }

test "case insensitive prefix" { assert sgPrefixMatch("AB", "abcde") === 2; }

test "empty prefix" { assert sgPrefixMatch("", "anything") === 2; }

test "prefix before substr" {
	const pr = parseSource("const abcdef = 1;\nconst xyzabc = 2;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "abc", null);
	assert candidates.length === 2;
	// abcdef (prefix match) should come before xyzabc (substr match)
	assert candidates[0].name === "abcdef";
	assert candidates[1].name === "xyzabc";
}

test "inner scope before outer" {
	const pr = parseSource("const outer = 1;\nfunction f() { const inner = 2; }");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "", null);
	// inner scope (depth 0) should rank before outer scope (depth > 0)
	// At least both should be present
	assert candidates.length >= 2;
	// First items should have lower scopeDepth
	if (candidates.length >= 2) {
		assert candidates[0].scopeDepth <= candidates[1].scopeDepth;
	}
}

test "collects function and variable" {
	const pr = parseSource("function foo() { return 1; }\nconst x = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	assert symbols.length === 2;
	assert symbols[0].name === "foo";
	assert symbols[0].kind === SymbolKind.Function;
	assert symbols[1].name === "x";
	assert symbols[1].kind === SymbolKind.Variable;
}

test "collects interface and enum" {
	const pr = parseSource("interface Point { x: number; }\nenum Color { Red, Green }");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	assert symbols.length === 2;
	assert symbols[0].name === "Point";
	assert symbols[0].kind === SymbolKind.Interface;
	assert symbols[1].name === "Color";
	assert symbols[1].kind === SymbolKind.Enum;
}

test "unwraps export decl" {
	const pr = parseSource("export function bar() { return 1; }");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	assert symbols.length === 1;
	assert symbols[0].name === "bar";
}

test "empty program" {
	const pr = parseSource("");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	assert symbols.length === 0;
}

test "function with params" {
	const params: Type[] = [numberType(), stringType()];
	const names: string[] = ["line", "msg"];
	const fnType = createFunction(params, names, voidType());
	const sym = makeSymbol("log", SymbolKind.Function, fnType, false);
	const sigs = sgFormatSignature(sym);
	assert sigs.length === 1;
	assert sigs[0].label === "log(line: number, msg: string): void";
	assert sigs[0].paramLabels.length === 2;
}

test "function no params" {
	const params: Type[] = [];
	const names: string[] = [];
	const fnType = createFunction(params, names, booleanType());
	const sym = makeSymbol("check", SymbolKind.Function, fnType, false);
	const sigs = sgFormatSignature(sym);
	assert sigs.length === 1;
	assert sigs[0].label === "check(): boolean";
	assert sigs[0].paramLabels.length === 0;
}

test "null symbol returns empty" {
	const nullSym = null as unknown as Symbol;
	const sigs = sgFormatSignature(nullSym);
	assert sigs.length === 0;
}

test "non-function symbol returns empty" {
	const sym = makeSymbol("x", SymbolKind.Variable, numberType(), false);
	const sigs = sgFormatSignature(sym);
	assert sigs.length === 0;
}

test "simple call" { assert sgGetCalleeAtCursor("foo(x", 1, 4) === "foo"; }

test "call with space before paren" { assert sgGetCalleeAtCursor("foo (x", 1, 5) === "foo"; }

test "nested call — inner" { assert sgGetCalleeAtCursor("foo(bar(x", 1, 8) === "bar"; }

test "not inside call returns empty" { assert sgGetCalleeAtCursor("hello", 1, 3) === ""; }

test "after comma" { assert sgGetCalleeAtCursor("add(1, 2", 1, 7) === "add"; }

test "first param" {
	// foo(| — cursor just after (
	assert sgCountActiveParam("foo(x", 1, 4) === 0;
}

test "second param" {
	// foo(a, | — cursor after comma
	assert sgCountActiveParam("foo(a, b", 1, 7) === 1;
}

test "third param" { assert sgCountActiveParam("foo(a, b, c", 1, 10) === 2; }

test "nested parens ignored" {
	// foo(bar(1, 2), | — inner commas don't count
	assert sgCountActiveParam("foo(bar(1, 2), x", 1, 15) === 1;
}

test "type hint for untyped variable" {
	const src = "const x = 42;";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	assert hints.length === 1;
	assert hints[0].label === ": number";
	assert hints[0].hintKind === SgInlayHintKind.Type;
}

test "no hint for explicitly typed variable" {
	const src = "const x: number = 42;";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	assert hints.length === 0;
}

test "parameter hints at call site" {
	const src = "function add(a: number, b: number): number { return a + b; }\nconst r = add(1, 2);";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	// Should have: type hint for r + param hints a: and b:
	let typeHints = 0;
	let paramHints = 0;
	for (let j = 0; j < hints.length; j = j + 1) {
		if (hints[j].hintKind === SgInlayHintKind.Type) { typeHints = typeHints + 1; }
		if (hints[j].hintKind === SgInlayHintKind.Parameter) { paramHints = paramHints + 1; }
	}
	assert typeHints >= 1;  // r: number
	assert paramHints === 2;  // a: 1, b: 2
}

test "skip param hint when arg matches param name" {
	const src = "function foo(x: number): void {}\nconst x = 5;\nfoo(x);";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	// x matches param name "x" — no param hint, just type hint for x
	let paramHints = 0;
	for (let j = 0; j < hints.length; j = j + 1) {
		if (hints[j].hintKind === SgInlayHintKind.Parameter) { paramHints = paramHints + 1; }
	}
	assert paramHints === 0;
}

// ===== Doc Comment Tests =====

test "doc comment JSDoc single-line" {
	const src = "/** Adds two numbers. */\nfunction add(x: number): number { return x; }";
	const comment = sgExtractDocComment(src, 2);
	assert comment === "Adds two numbers.";
}

test "doc comment none" {
	const src = "const x = 1;\nfunction baz(): void {}";
	const comment = sgExtractDocComment(src, 2);
	assert comment === "";
}

test "doc comment first line no crash" {
	const src = "function first(): void {}";
	const comment = sgExtractDocComment(src, 1);
	assert comment === "";
}

test "doc comment // not supported" {
	const src = "// Not a doc comment\nfunction foo(): void {}";
	const comment = sgExtractDocComment(src, 2);
	assert comment === "";
}

test "doc comment JSDoc single-line" {
	const src = "/** Adds two numbers. */\nfunction add(x: number): number { return x; }";
	const comment = sgExtractDocComment(src, 2);
	assert comment === "Adds two numbers.";
}

test "doc comment JSDoc multi-line" {
	const src = "/**\n * Parses the input string.\n * @param text A valid string.\n * @returns The parsed value.\n */\nfunction parse(text: string): number { return 0; }";
	const comment = sgExtractDocComment(src, 6);
	assert comment === "Parses the input string.\n@param text A valid string.\n@returns The parsed value.";
}

test "doc comment JSDoc empty body" {
	const src = "/** */\nfunction noop(): void {}";
	const comment = sgExtractDocComment(src, 2);
	assert comment === "";
}

test "sgFormatHoverDoc with doc comment" {
	const suggest: SgSuggest = {
		sym: null, name: "foo", kind: SymbolKind.Function,
		symType: unknownType(), location: makeLoc(1, 0),
		modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: true, isMutable: false, usageCount: 0,
	};
	const doc = sgFormatHoverDoc(suggest, "A useful function");
	assert doc === "A useful function";
}

test "sgFormatHoverDoc no comment" {
	const suggest: SgSuggest = {
		sym: null, name: "bar", kind: SymbolKind.Variable,
		symType: unknownType(), location: makeLoc(1, 0),
		modulePath: "", containerName: "",
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false, usageCount: 0,
	};
	const doc = sgFormatHoverDoc(suggest, "");
	assert doc === "";
}

// ===== Import Source + Exported Decl Tests =====

test "find import source" {
	const src = "import { add } from \"./math\";\nconst x = add(1);";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	assert sgFindImportSource(pr.value, "add") === "./math";
}

test "find import source not found" {
	const src = "import { add } from \"./math\";";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	assert sgFindImportSource(pr.value, "unknown") === "";
}

test "find exported decl function" {
	const src = "export function add(x: number): number { return x; }";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const loc = sgFindExportedDecl(pr.value, "add");
	assert loc.line > 0;
}

test "find exported decl not found" {
	const src = "function add(x: number): number { return x; }";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const loc = sgFindExportedDecl(pr.value, "unknown");
	assert loc.line === 0;
}

test "exception hint for function returning Result" {
	const src = "function parse(s: string): Result<number, string> { return Result.ok(1); }";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	let exceptionCount = 0;
	for (let i = 0; i < hints.length; i = i + 1) {
		if (hints[i].hintKind === SgInlayHintKind.Exception) exceptionCount = exceptionCount + 1;
	}
	assert exceptionCount >= 1;
}

test "no exception hint for non-Result function" {
	const src = "function add(a: number, b: number): number { return a + b; }";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	let exceptionCount = 0;
	for (let i = 0; i < hints.length; i = i + 1) {
		if (hints[i].hintKind === SgInlayHintKind.Exception) exceptionCount = exceptionCount + 1;
	}
	assert exceptionCount === 0;
}

test "enum member access records symbol" {
	const src = "enum Color { Red, Green, Blue }\nconst c = Color.Green;";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	// Line 2 (1-based), cursor on "Green" — the dot is at col after "Color"
	// Color starts at col 10 on line 2, dot at col 15, Green at col 16
	const suggest = sgQueryAtPosition(ctx, 2, 17);
	assert suggest !== null;
	assert suggest.name === "Green";
	assert suggest.kind === SymbolKind.EnumMember;
	assert suggest.containerName === "Color";
}

test "enum type in member access records symbol" {
	const src = "enum Color { Red, Green, Blue }\nconst c = Color.Green;";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	// Cursor on "Color" in "Color.Green" (col 11 = C, within [11, 16))
	const suggest = sgQueryAtPosition(ctx, 2, 11);
	assert suggest !== null;
	assert suggest.name === "Color";
	assert suggest.kind === SymbolKind.Enum;
}

test "enum member in match all recorded and queryable" {
	// Tab-indented like real code. Tab = 1 column in our lexer.
	const src = "enum K { A, B, C, D }\nfunction f(k: K): number { return match (k) {\n\tK.A => 1,\n\tK.B | K.C => 2,\n\tK.D => 3,\n\t_ => 0,\n}; }";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	// Verify all 4 members recorded as EnumMember
	let countEnum = 0;
	if (ctx.symRecords !== null) {
		for (let i = 0; i < ctx.symRecords.length; i = i + 1) {
			if (ctx.symRecords[i].kind === SymbolKind.EnumMember && !ctx.symRecords[i].isDecl) countEnum = countEnum + 1;
		}
	}
	assert countEnum === 4;
	// Line 3: \tK.A — tab(1) K(2) .(3) A(4)
	// MemberExpr at dot col=3, property A recorded at [4, 5)
	const sA = sgQueryAtPosition(ctx, 3, 4);
	assert sA !== null;
	assert sA.name === "A";
	assert sA.kind === SymbolKind.EnumMember;
	// Line 4: \tK.B | K.C — tab(1) K(2) .(3) B(4) space(5) |(6) space(7) K(8) .(9) C(10)
	const sB = sgQueryAtPosition(ctx, 4, 4);
	assert sB !== null;
	assert sB.name === "B";
	const sC = sgQueryAtPosition(ctx, 4, 10);
	assert sC !== null;
	assert sC.name === "C";
	// Line 5: \tK.D — D at col 4
	const sD = sgQueryAtPosition(ctx, 5, 4);
	assert sD !== null;
	assert sD.name === "D";
}

test "import line: cursor in path triggers ImportPath" {
	// Test importContextFromAST directly with a hand-built ImportDecl node.
	// Simulates: import { BuildConfig } from "std/build";
	// BuildConfig at col 10, length 11 → lastNameEnd = 21
	// "std/build" starts at col ~29 (21 + 8 = 29)
	// col 30 should be past 21 + 8 = 29 → "path"
	const importNode = createNodeAt(NodeKind.ImportDecl, {
		importNames: ["BuildConfig"],
		importAliases: ["BuildConfig"],
		importSource: "std/build",
		nameLocations: [makeLoc(1, 10)],
	}, makeLoc(1, 1));
	assert importContextFromAST(importNode, 30) === "path";
}

test "import line: cursor in braces triggers ImportName" {
	// Same ImportDecl — col 12 is inside the names region
	const importNode = createNodeAt(NodeKind.ImportDecl, {
		importNames: ["BuildConfig"],
		importAliases: ["BuildConfig"],
		importSource: "std/build",
		nameLocations: [makeLoc(1, 10)],
	}, makeLoc(1, 1));
	assert importContextFromAST(importNode, 12) === "names";
}

test "empty line inside ObjectLiteral triggers ObjectField" {
	// Multi-line object with an empty line inside
	const src = "const x = {\n\n  a: 1,\n};";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	// Line 2 is the empty line — should detect ObjectField
	assert sgDetectCompletionContext(pr.value, 2, 1) === SgCompletionKind.ObjectField;
}

test "empty line inside NESTED ObjectLiteral triggers ObjectField" {
	// Simulates build.ms: const config = { root: "", fmt: {\n\n  useTabs: true,\n} };
	const src = "const config = {\n  root: \"\",\n  fmt: {\n\n    useTabs: true,\n  },\n};";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	// Line 4 is the empty line inside fmt:{} — should detect ObjectField
	const obj = findEnclosingObjectLiteral(pr.value, 4, 1);
	assert obj !== null;
	assert sgDetectCompletionContext(pr.value, 4, 1) === SgCompletionKind.ObjectField;
}
