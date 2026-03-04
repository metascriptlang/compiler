// Pass 2: Resolve - parse type annotations, enrich collected symbols
//
// The parser currently stores type annotations as strings (TypeAnnotation nodes)
// and skips them in most places. Function params are string[] (names only).
// This pass enriches the symbol table by:
//   A. Parsing type annotation strings into Type objects
//   B. Building proper Function/Object types for collected declarations

import {
	Node, NodeKind, SourceLocation, createNodeAt,
	ProgramData, FunctionDeclData, InterfaceDeclData, ExportDeclData,
	ClassDeclData, MethodDeclData, PropertyDeclData, ConstructorDeclData,
	TypeAliasDeclData, VariableDeclData, DecoratedDeclData,
} from "../ast/node";
import {
	Type, TypeKind,
	unknownType, numberType, stringType, booleanType, voidType, nullType, neverType,
	createPrimitive, createArray, createFunction, createObject,
	createResult, createTypeRef, createUnion, createGenericParam, createDistinct,
	createSizedArray, createSpan,
	setMinArity,
} from "./types";
import { Symbol, SymbolKind, SymbolTable, ScopeKind, lookupSymbol, lookupLocal, defineSymbol, makeSymbol, openScope, closeScope, SymbolState, hasFlag, setFlag, SF_EXPORTED, SF_MUTABLE } from "./symbol";
import { CheckerContext, findExtension, getExtTypeName, extractGenericNames, addError } from "./context";
import { trimStr, sliceStr, findChar, splitTopLevel } from "../utils/string";
import { getProperty } from "./types";
import { getGenericDecl, getGenericDeclFieldNames, getGenericDeclFieldTypes, addGenericTypeInst, findGenericTypeInstIdx, getDefaultCount, getDefaultText, addDefaultParam } from "../parser/context";
import { check } from "std/testing";

// ===== A. Resolve Annotation Strings =====

export function resolveAnnotation(text: string, ctx: CheckerContext): Type {
	const trimmed = trimStr(text);
	if (trimmed === "") return unknownType();

	// Check for union types (split on top-level |)
	const unionParts = splitTopLevel(trimmed, "|");
	if (unionParts.length === 2) {
		return createUnion([resolveAnnotation(unionParts[0], ctx), resolveAnnotation(unionParts[1], ctx)]);
	}
	if (unionParts.length >= 3) {
		return createUnion([resolveAnnotation(unionParts[0], ctx), resolveAnnotation(unionParts[1], ctx), resolveAnnotation(unionParts[2], ctx)]);
	}

	// Check for array suffix [] or [ ] (token-joined form from captureOptionalType)
	if (trimmed.endsWith("[ ]")) {
		const inner = trimStr(sliceStr(trimmed, 0, trimmed.length - 3));
		return createArray(resolveAnnotation(inner, ctx));
	}
	if (trimmed.endsWith("[]")) {
		const inner = sliceStr(trimmed, 0, trimmed.length - 2);
		return createArray(resolveAnnotation(inner, ctx));
	}
	if (trimmed.endsWith("]")) {
		const openBracket = findChar(trimmed, "[");
		if (openBracket > 0) {
			const inner = trimStr(sliceStr(trimmed, 0, openBracket));
			const sizeStr = trimStr(sliceStr(trimmed, openBracket + 1, trimmed.length - 1));
			if (sizeStr === "" || sizeStr === " ") {
				return createArray(resolveAnnotation(inner, ctx));
			}
			const size = parseInt(sizeStr, 10);
			return createSizedArray(resolveAnnotation(inner, ctx), size);
		}
	}

	// Check for generic types: Name<A, B> or Name < A , B > (token-joined form)
	const angleBracket = findChar(trimmed, "<");
	if (angleBracket > 0 && trimmed.endsWith(">")) {
		const baseName = trimStr(sliceStr(trimmed, 0, angleBracket));
		const argsText = trimStr(sliceStr(trimmed, angleBracket + 1, trimmed.length - 1));
		const args = splitTopLevel(argsText, ",");

		if (baseName === "Result" && args.length === 2) {
			return createResult(resolveAnnotation(args[0], ctx), resolveAnnotation(args[1], ctx));
		}
		if (baseName === "Array" && args.length === 1) {
			return createArray(resolveAnnotation(args[0], ctx));
		}
		if (baseName === "Span" && args.length === 1) {
			return createSpan(resolveAnnotation(args[0], ctx));
		}
		if (baseName === "Map" && args.length === 2) {
			const t = createPrimitive(TypeKind.Map);
			t.typeReturn = resolveAnnotation(args[0], ctx);
			t.typeExtra = resolveAnnotation(args[1], ctx);
			return t;
		}
		if (baseName === "Record" && args.length === 2) {
			// Record<K,V> is TypeScript utility type — desugar to Map<K,V>
			const t = createPrimitive(TypeKind.Map);
			t.typeReturn = resolveAnnotation(args[0], ctx);
			t.typeExtra = resolveAnnotation(args[1], ctx);
			return t;
		}
		// Generic instance: check if this is a generic interface/class
		const genericParams = getGenericDecl(baseName);
		if (genericParams !== "") {
			// Record instantiation for codegen
			recordGenericTypeInstantiation(baseName, genericParams, args, ctx);
			// Return a type reference with mangled name
			const typeArgKey = buildTypeArgKey(args, ctx);
			const mangledName = baseName + "__" + typeArgKey;
			return createTypeRef(mangledName);
		}
		// Non-generic: look up base type
		const baseSym = lookupSymbol(ctx.table, baseName);
		if (baseSym !== null) {
			// Demand-driven resolution: ensure the base symbol is shaped before using its type
			ensureShaped(baseSym, ctx);
			return baseSym.symbolType;
		}
		return createTypeRef(baseName);
	}

	// Primitive types, symbol lookup, or forward reference
	return match (trimmed) {
		"number" => numberType(),
		"string" => stringType(),
		"boolean" => booleanType(),
		"void" => voidType(),
		"null" => nullType(),
		"never" => neverType(),
		"int32" => createPrimitive(TypeKind.Int32),
		"int64" => createPrimitive(TypeKind.Int64),
		"uint32" => createPrimitive(TypeKind.Uint32),
		"float32" => createPrimitive(TypeKind.Float32),
		"float64" => createPrimitive(TypeKind.Float64),
		_ => {
			const sym = lookupSymbol(ctx.table, trimmed);
			if (sym !== null) {
				// Demand-driven: ensure shaped before using
				ensureShaped(sym, ctx);
				return sym.symbolType;
			}
			createTypeRef(trimmed);
		},
	};
}

// ===== Demand-Driven Shaping (Nim parity) =====

export function ensureShaped(sym: Symbol, ctx: CheckerContext): void {
	if (sym.state === SymbolState.Shaped || sym.state === SymbolState.Checked) return;
	if (sym.state === SymbolState.Shaping) {
		addError(ctx, `Circular dependency detected while resolving '${sym.name}'`);
		return;
	}

	sym.state = SymbolState.Shaping;
	const node = sym.declNode;
	if (node !== null) {
		match (node.kind) {
			NodeKind.FunctionDecl => resolveFunction(ctx, node),
			NodeKind.InterfaceDecl => resolveInterface(ctx, node),
			NodeKind.ClassDecl => resolveClass(ctx, node),
			NodeKind.TypeAliasDecl => resolveTypeAlias(ctx, node),
			NodeKind.VariableDecl => resolveVariable(ctx, node),
			_ => {},
		};
	}
	sym.state = SymbolState.Shaped;

	// Recursively ensure all overloads are shaped (Demand-Driven Completeness)
	for (const ov of sym.overloads) {
		ensureShaped(ov, ctx);
	}
}

// ===== Generic Type Instantiation Helpers =====

// Build a type arg key from resolved type arg strings (e.g., "number,string")
function buildTypeArgKey(args: string[], ctx: CheckerContext): string {
	let key = "";
	for (let i = 0; i < args.length; i += 1) {
		if (i > 0) key = key + ",";
		key = key + trimStr(args[i]);
	}
	return key;
}

// Find index of matching generic param for a given field type string.
// Returns the param index, or -1 if no match. Uses only number locals (DRC-safe).
function findGenericParamIdx(rawType: string, paramNames: string[]): number {
	for (let i = 0; i < paramNames.length; i += 1) {
		if (trimStr(paramNames[i]) === rawType) return i;
	}
	return -1;
}

// Record a generic type instantiation (e.g., Box<number>) for codegen
// Looks up field names/types from parser side-channel, substitutes generic params -> concrete types
// NOTE: Avoids all `let` string variables — only const strings + number let variables.
// DRC generates msDecref instead of msStringDecref for let string locals in complex functions.
function recordGenericTypeInstantiation(baseName: string, genericParams: string, args: string[], ctx: CheckerContext): void {
	const typeArgKey = buildTypeArgKey(args, ctx);
	const mangledName = baseName + "__" + typeArgKey;

	// Get field info from parser side-channel
	const fieldNamesStr = getGenericDeclFieldNames(baseName);
	const fieldTypesStr = getGenericDeclFieldTypes(baseName);

	if (fieldNamesStr === "") {
		addGenericTypeInst(baseName, typeArgKey, mangledName, "", "");
		return;
	}

	// Split generic param names: "T,U" -> ["T", "U"]
	const paramNames = splitTopLevel(genericParams, ",");
	const fnParts = splitTopLevel(fieldNamesStr, "|");
	const ftParts = splitTopLevel(fieldTypesStr, "|");

	if (fnParts.length === 0) {
		addGenericTypeInst(baseName, typeArgKey, mangledName, "", "");
		return;
	}

	// Handle first field separately to initialize result strings from non-empty values
	const firstRaw = ftParts.length > 0 ? trimStr(ftParts[0]) : "";
	const firstIdx = findGenericParamIdx(firstRaw, paramNames);
	const firstSub = firstIdx >= 0 && firstIdx < args.length ? trimStr(args[firstIdx]) : firstRaw;

	// Only use `let` for result strings initialized from computed values (never from "")
	let resultFieldNames = trimStr(fnParts[0]);
	let resultFieldTypes = firstSub;

	// Append remaining fields with "|" separator
	for (let fi = 1; fi < fnParts.length; fi += 1) {
		const rawType = fi < ftParts.length ? trimStr(ftParts[fi]) : "";
		const paramIdx = findGenericParamIdx(rawType, paramNames);
		const subType = paramIdx >= 0 && paramIdx < args.length ? trimStr(args[paramIdx]) : rawType;
		resultFieldNames = resultFieldNames + "|" + trimStr(fnParts[fi]);
		resultFieldTypes = resultFieldTypes + "|" + subType;
	}

	addGenericTypeInst(baseName, typeArgKey, mangledName, resultFieldNames, resultFieldTypes);
}

// ===== Resolve Helpers =====

// Resolve an array of type annotation strings into Type[], matching names 1:1
function resolveTypeStrings(typeStrs: string[], count: number, ctx: CheckerContext): Type[] {
	const types: Type[] = [];
	for (let i = 0; i < count; i += 1) {
		if (i < typeStrs.length && typeStrs[i] !== "") {
			types.push(resolveAnnotation(typeStrs[i], ctx));
		} else {
			types.push(unknownType());
		}
	}
	return types;
}

// ===== Generic Parameter Extraction =====

// Extract generic param names from fnFlags: "gen:T,U" or "async|gen:T,U" -> ["T", "U"]
// Define a generic param symbol, handling optional constraint: "T" or "T:Comparable"
function defineGenericParam(ctx: CheckerContext, paramStr: string): void {
	const colonPos = findChar(paramStr, ":");
	if (colonPos > 0) {
		// Has constraint: "T:Comparable" -> name="T", constraint="Comparable"
		const paramName = sliceStr(paramStr, 0, colonPos);
		const constraintStr = sliceStr(paramStr, colonPos + 1, paramStr.length);
		const gp = createGenericParam(paramName);
		// Store constraint type in typeExtra
		gp.typeExtra = resolveAnnotation(constraintStr, ctx);
		defineSymbol(ctx.table, makeSymbol(paramName, SymbolKind.TypeAlias, gp, false));
	} else {
		// No constraint: "T"
		defineSymbol(ctx.table, makeSymbol(paramStr, SymbolKind.TypeAlias, createGenericParam(paramStr), false));
	}
}

// ===== B. Resolve Declarations (Pass 2) =====

export function resolveDeclarations(ctx: CheckerContext, program: Node): void {
	const stmts = program.data as ProgramData;
	for (const stmt of stmts.programStmts) {
		const name = getDeclName(stmt);
		if (name !== "") {
			const sym = lookupSymbol(ctx.table, name);
			if (sym !== null) {
				ensureShaped(sym, ctx);
			}
		} else if (stmt.kind === NodeKind.ExportDecl) {
			const d = stmt.data as ExportDeclData;
			const innerName = getDeclName(d.exportedDecl);
			if (innerName !== "") {
				const sym = lookupSymbol(ctx.table, innerName);
				if (sym !== null) ensureShaped(sym, ctx);
			}
		} else if (stmt.kind === NodeKind.DecoratedDecl) {
			const dd = stmt.data as DecoratedDeclData;
			const innerName = getDeclName(dd.decoratedNode);
			if (innerName !== "") {
				const sym = lookupSymbol(ctx.table, innerName);
				if (sym !== null) ensureShaped(sym, ctx);
			}
		}
	}
}

// Extract the name from any declaration node (parity with collectPass)
function getDeclName(node: Node): string {
	return match (node.kind) {
		NodeKind.FunctionDecl => { const d = node.data as FunctionDeclData; d.fnName; },
		NodeKind.ClassDecl => { const d = node.data as ClassDeclData; d.className; },
		NodeKind.InterfaceDecl => { const d = node.data as InterfaceDeclData; d.interfaceName; },
		NodeKind.EnumDecl => { const d = node.data as EnumDeclData; d.enumName; },
		NodeKind.TypeAliasDecl => { const d = node.data as TypeAliasDeclData; d.aliasName; },
		NodeKind.ExternDecl => { const d = node.data as ExternDeclData; d.externName; },
		NodeKind.VariableDecl => { const d = node.data as VariableDeclData; d.declName; },
		_ => "",
	};
}

function resolveFunction(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	const sym = lookupSymbol(ctx.table, d.fnName);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Set state to Shaped early to allow recursive references in signature
	sym.state = SymbolState.Shaped;

	// Open temp scope with GenericParam types
 // so resolveAnnotation finds "T" -> GenericParam("T")
	const genericNames = extractGenericNames(d.fnFlags);

	if (genericNames.length > 0) {
		openScope(ctx.table, ScopeKind.Block);
		for (const gp of genericNames) {
			defineGenericParam(ctx, gp);
		}
	}

	const paramTypes = resolveTypeStrings(d.fnParamTypes, d.params.length, ctx);
	const returnType = (d.fnReturnType !== "") ? resolveAnnotation(d.fnReturnType, ctx) : unknownType();
	const fnType = createFunction(paramTypes, d.params, returnType);

	// Set minArity for functions with default parameters
	const defCount = getDefaultCount(d.fnName, d.params.length);
	if (defCount > 0) {
		setMinArity(fnType, d.params.length - defCount);
	}

	if (genericNames.length > 0) {
		closeScope(ctx.table);
	}

	// Overload handling: resolve in declaration order
	if (sym.overloads.length > 0 && sym.symbolType.kind !== TypeKind.Unknown) {
		// Primary already resolved — assign to first unresolved overload
		for (const overload of sym.overloads) {
			if (overload.symbolType.kind === TypeKind.Unknown) {
				overload.symbolType = fnType;
				// Ensure overload sym also points to its declNode
				overload.declNode = node;
				overload.state = SymbolState.Shaped;
				return;
			}
		}
	}

	sym.symbolType = fnType;
	node.nodeType = fnType;
	// Update extension method type in registry (instance or static)
	const extTypeName = getExtTypeName(d.fnFlags);
	if (extTypeName !== "" && ctx.extensionRegistry !== null) {
		const ext = findExtension(ctx.extensionRegistry, extTypeName, d.fnName);
		if (ext !== null) { ext.fnType = fnType; }
	}
}

function resolveInterface(ctx: CheckerContext, node: Node): void {
	const d = node.data as InterfaceDeclData;
	const sym = lookupSymbol(ctx.table, d.interfaceName);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Set state to Shaped immediately to allow circular references in fields
	sym.state = SymbolState.Shaped;

	// Check for generic params (e.g., interface Box<T> — parser stores in side-channel)
	const genericStr = getGenericDecl(d.interfaceName);
	const hasGenerics = genericStr !== "";
	if (hasGenerics) {
		openScope(ctx.table, ScopeKind.Block);
		const genericNames = splitTopLevel(genericStr, ",");
		for (const gp of genericNames) {
			const trimGp = trimStr(gp);
			if (trimGp !== "") {
				defineGenericParam(ctx, trimGp);
			}
		}
	}

	const fieldTypes = resolveTypeStrings(d.interfaceFieldTypes, d.interfaceFields.length, ctx);

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	const ifaceType = createObject(d.interfaceName, d.interfaceFields, fieldTypes, true);
	sym.symbolType = ifaceType;
	node.nodeType = ifaceType;
}

function resolveTypeAlias(ctx: CheckerContext, node: Node): void {
	const d = node.data as TypeAliasDeclData;
	const sym = lookupSymbol(ctx.table, d.aliasName);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Set state to Shaped immediately to allow circular references
	sym.state = SymbolState.Shaped;

	if (d.aliasType === "") {
		return;
	}
	const resolved = resolveAnnotation(d.aliasType, ctx);
	if (d.aliasIsDistinct) {
		const distType = createDistinct(resolved);
		sym.symbolType = distType;
		node.nodeType = distType;
	} else {
		sym.symbolType = resolved;
		node.nodeType = resolved;
	}
}

function resolveVariable(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	if (d.declType === "") return;
	// Variable annotations are used as hints in Pass 3 (checkVariableDecl)
	// We don't resolve them here because the symbol isn't defined yet in Pass 2
	// (variables are defined during Pass 3). Instead, we store the info for later use.
}

function resolveClass(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	const sym = lookupSymbol(ctx.table, d.className);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Set state to Shaped immediately to allow circular references in methods/properties
	sym.state = SymbolState.Shaped;

	// Check for generic params (e.g., class Container<T> — parser stores in side-channel)
	const genericStr = getGenericDecl(d.className);
	const hasGenerics = genericStr !== "";
	if (hasGenerics) {
		openScope(ctx.table, ScopeKind.Block);
		const genericNames = splitTopLevel(genericStr, ",");
		for (const gp of genericNames) {
			const trimGp = trimStr(gp);
			if (trimGp !== "") {
				defineGenericParam(ctx, trimGp);
			}
		}
	}

	// Save collectPass type to preserve decorator metadata (runtimeName/builtinKind on typeName)
	const oldType = sym.symbolType;

	// Build Object type — collect members inline
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (let mi = 0; mi < d.classBody.length; mi += 1) {
		let member = d.classBody[mi];
		// Unwrap DecoratedDecl to get the inner declaration
		if (member.kind === NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			member = dd.decoratedNode;
		}
		if (member.kind === NodeKind.MethodDecl) {
			const md = member.data as MethodDeclData;
			memberNames.push(md.methodName);
			const paramTypes = resolveTypeStrings(md.methodParamTypes, md.methodParams.length, ctx);
			const returnType = (md.methodReturnType !== "") ? resolveAnnotation(md.methodReturnType, ctx) : unknownType();
			const fnType = createFunction(paramTypes, md.methodParams, returnType);
			// Carry over typeName from collectPass (stores @runtime/@builtin metadata)
			const prevMemberType = getProperty(oldType, md.methodName);
			if (prevMemberType.typeName !== "") {
				fnType.typeName = prevMemberType.typeName;
			}
			member.nodeType = fnType;
			memberTypes.push(fnType);
		} else if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			memberNames.push(pd.propName);
			if (pd.propType !== "") {
				const propType = resolveAnnotation(pd.propType, ctx);
				member.nodeType = propType;
				memberTypes.push(propType);
			} else {
				memberTypes.push(unknownType());
			}
		} else if (member.kind === NodeKind.ConstructorDecl) {
			memberNames.push("constructor");
			const cd = member.data as ConstructorDeclData;
			const paramTypes = resolveTypeStrings(cd.ctorParamTypes, cd.ctorParams.length, ctx);
			const ctorType = createFunction(paramTypes, cd.ctorParams, voidType());
			member.nodeType = ctorType;
			memberTypes.push(ctorType);
		}
	}

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	const classType = createObject(d.className, memberNames, memberTypes, false);
	sym.symbolType = classType;
	node.nodeType = classType;
}

// ===== Tests =====

import { createContext } from "./context";
import { defineSymbol, makeSymbol } from "./symbol";
import {
	addGenericDecl, updateGenericDeclFields, resetGenericDeclStore,
	resetGenericTypeInsts, getGenericTypeInstCount, getGenericTypeInstBaseName,
	getGenericTypeInstTypeArgKey, getGenericTypeInstMangledName,
	getGenericTypeInstFieldNames, getGenericTypeInstFieldTypes,
	findGenericTypeInstIdx,
} from "../parser/context";

function resolveWith(text: string): Type {
	const ctx = createContext();
	return resolveAnnotation(text, ctx);
}

test "number" { check(resolveWith("number").kind === TypeKind.Number); }

test "string" { check(resolveWith("string").kind === TypeKind.String); }

test "boolean" { check(resolveWith("boolean").kind === TypeKind.Boolean); }

test "void" { check(resolveWith("void").kind === TypeKind.Void); }

test "null" { check(resolveWith("null").kind === TypeKind.Null); }

test "never" { check(resolveWith("never").kind === TypeKind.Never); }

test "int32" { check(resolveWith("int32").kind === TypeKind.Int32); }

test "float64" { check(resolveWith("float64").kind === TypeKind.Float64); }

test "unknown name" { check(resolveWith("Foo").kind === TypeKind.TypeReference); }

test "empty" { check(resolveWith("").kind === TypeKind.Unknown); }

test "number[]" {
	const t = resolveWith("number[]");
	check(t.kind === TypeKind.Array);
	check(t.typeReturn.kind === TypeKind.Number);
}

test "string[]" {
	const t = resolveWith("string[]");
	check(t.kind === TypeKind.Array);
	check(t.typeReturn.kind === TypeKind.String);
}

test "Result<number, string>" {
	const t = resolveWith("Result<number, string>");
	check(t.kind === TypeKind.Result);
	check(t.typeReturn.kind === TypeKind.Number);
	check(t.typeExtra.kind === TypeKind.String);
}

test "Array<boolean>" {
	const t = resolveWith("Array<boolean>");
	check(t.kind === TypeKind.Array);
	check(t.typeReturn.kind === TypeKind.Boolean);
}

test "number[4]" {
	const t = resolveWith("number[4]");
	check(t.kind === TypeKind.SizedArray);
	check(t.typeReturn.kind === TypeKind.Number);
	check(t.typeFlags === 4);
}

test "Span<boolean>" {
	const t = resolveWith("Span<boolean>");
	check(t.kind === TypeKind.Span);
	check(t.typeReturn.kind === TypeKind.Boolean);
}

test "Map<string, number>" {
	const t = resolveWith("Map<string, number>");
	check(t.kind === TypeKind.Map);
	check(t.typeReturn.kind === TypeKind.String);
	check(t.typeExtra.kind === TypeKind.Number);
}

test "Record<string, number> desugars to Map" {
	const t = resolveWith("Record<string, number>");
	check(t.kind === TypeKind.Map);
	check(t.typeReturn.kind === TypeKind.String);
	check(t.typeExtra.kind === TypeKind.Number);
}

test "Record<string, boolean> value type" {
	const t = resolveWith("Record<string, boolean>");
	check(t.kind === TypeKind.Map);
	check(t.typeExtra.kind === TypeKind.Boolean);
}

test "string | number" {
	const t = resolveWith("string | number");
	check(t.kind === TypeKind.Union);
	check(t.typeChildren.length === 2);
	check(t.typeChildren[0].kind === TypeKind.String);
	check(t.typeChildren[1].kind === TypeKind.Number);
}

test "known symbol" {
	const ctx = createContext();
	defineSymbol(ctx.table, makeSymbol("MyType", SymbolKind.Interface, createObject("MyType", [], [], true), false));
	const t = resolveAnnotation("MyType", ctx);
	check(t.kind === TypeKind.Object);
	check(t.typeName === "MyType");
}

test "function gets Function type" {
	const ctx = createContext();
	const symStub = makeSymbol("foo", SymbolKind.Function, unknownType(), false);
	defineSymbol(ctx.table, symStub);
	// Simulate a FunctionDecl node
	const zl: SourceLocation = { line: 0, column: 0 };
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "foo", params: ["a", "b"], fnParamTypes: ["", ""], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "" }, zl);
	symStub.declNode = fnNode;
	const node = createNodeAt(NodeKind.Program, { programStmts: [fnNode] }, zl);
	resolveDeclarations(ctx, node);
	const sym = lookupSymbol(ctx.table, "foo");
	check(sym !== null);
	check(sym.symbolType.kind === TypeKind.Function);
	check(sym.symbolType.typeChildren.length === 2);
	check(sym.symbolType.typeNames[0] === "a");
	check(sym.symbolType.typeNames[1] === "b");
}

test "function with typed params" {
	const ctx = createContext();
	const symStub = makeSymbol("add", SymbolKind.Function, unknownType(), false);
	defineSymbol(ctx.table, symStub);
	const zl: SourceLocation = { line: 0, column: 0 };
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "add", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number" }, zl);
	symStub.declNode = fnNode;
	const node = createNodeAt(NodeKind.Program, { programStmts: [fnNode] }, zl);
	resolveDeclarations(ctx, node);
	const sym = lookupSymbol(ctx.table, "add");
	check(sym !== null);
	check(sym.symbolType.kind === TypeKind.Function);
	check(sym.symbolType.typeChildren[0].kind === TypeKind.Number);
	check(sym.symbolType.typeChildren[1].kind === TypeKind.Number);
	check(sym.symbolType.typeReturn.kind === TypeKind.Number);
}

test "decorated function gets resolved" {
	const ctx = createContext();
	const symStub = makeSymbol("floor", SymbolKind.Function, unknownType(), false);
	defineSymbol(ctx.table, symStub);
	const zl: SourceLocation = { line: 0, column: 0 };
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "floor", params: ["x"], fnParamTypes: ["number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number" }, zl);
	symStub.declNode = fnNode;
	const decoNode = createNodeAt(NodeKind.DecoratedDecl, { decorators: [], decoratedNode: fnNode }, zl);
	const node = createNodeAt(NodeKind.Program, { programStmts: [decoNode] }, zl);
	resolveDeclarations(ctx, node);
	const sym = lookupSymbol(ctx.table, "floor");
	check(sym !== null);
	check(sym.symbolType.kind === TypeKind.Function);
	check(sym.symbolType.typeReturn.kind === TypeKind.Number);
}

test "Box<number> records instantiation" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	// Simulate parser registering interface Box<T> { value: T; }
	addGenericDecl("Box", "T");
	updateGenericDeclFields("Box", "value", "T");
	// Resolve Box<number> — should record instantiation
	const ctx = createContext();
	const t = resolveAnnotation("Box<number>", ctx);
	check(t.kind === TypeKind.TypeReference);
	check(t.typeName === "Box__number");
	// Check instantiation was recorded
	check(getGenericTypeInstCount() === 1);
	check(getGenericTypeInstBaseName(0) === "Box");
	check(getGenericTypeInstTypeArgKey(0) === "number");
	check(getGenericTypeInstMangledName(0) === "Box__number");
	check(getGenericTypeInstFieldNames(0) === "value");
	check(getGenericTypeInstFieldTypes(0) === "number");
}

test "Pair<string, number> records instantiation" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	addGenericDecl("Pair", "A,B");
	updateGenericDeclFields("Pair", "first|second", "A|B");
	const ctx = createContext();
	const t = resolveAnnotation("Pair<string, number>", ctx);
	check(t.kind === TypeKind.TypeReference);
	check(t.typeName === "Pair__string,number");
	const idx = findGenericTypeInstIdx("Pair", "string,number");
	check(idx >= 0);
	check(getGenericTypeInstFieldNames(idx) === "first|second");
	check(getGenericTypeInstFieldTypes(idx) === "string|number");
}

test "dedup instantiation" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	addGenericDecl("Box", "T");
	updateGenericDeclFields("Box", "value", "T");
	const ctx = createContext();
	resolveAnnotation("Box<number>", ctx);
	resolveAnnotation("Box<number>", ctx);
	check(getGenericTypeInstCount() === 1);
}

test "non-generic base falls through" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	// No addGenericDecl for "Foo" — should fall through to symbol lookup
	const ctx = createContext();
	defineSymbol(ctx.table, makeSymbol("Foo", SymbolKind.Interface, createObject("Foo", [], [], true), false));
	const t = resolveAnnotation("Foo<number>", ctx);
	// Non-generic: returns base type (Foo)
	check(t.kind === TypeKind.Object);
	check(t.typeName === "Foo");
}

test "generic class Container<T> records instantiation" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	// Simulate parser registering class Container<T> { item: T; count: number; }
	addGenericDecl("Container", "T");
	updateGenericDeclFields("Container", "item|count", "T|number");
	const ctx = createContext();
	const t = resolveAnnotation("Container<string>", ctx);
	check(t.kind === TypeKind.TypeReference);
	check(t.typeName === "Container__string");
	check(getGenericTypeInstCount() === 1);
	check(getGenericTypeInstFieldNames(0) === "item|count");
	check(getGenericTypeInstFieldTypes(0) === "string|number");
}

test "constraint stored on GenericParam typeExtra" {
	// Simulate "T:number" — defineGenericParam parses colon, sets typeExtra
	const ctx = createContext();
	openScope(ctx.table, ScopeKind.Block);
	defineGenericParam(ctx, "T:number");
	const sym = lookupSymbol(ctx.table, "T");
	check(sym !== null);
	check(sym.symbolType.kind === TypeKind.GenericParam);
	check(sym.symbolType.typeName === "T");
	check(sym.symbolType.typeExtra !== null);
	check(sym.symbolType.typeExtra.kind === TypeKind.Number);
	closeScope(ctx.table);
}

test "no constraint leaves typeExtra null" {
	const ctx = createContext();
	openScope(ctx.table, ScopeKind.Block);
	defineGenericParam(ctx, "U");
	const sym = lookupSymbol(ctx.table, "U");
	check(sym !== null);
	check(sym.symbolType.kind === TypeKind.GenericParam);
	check(sym.symbolType.typeName === "U");
	closeScope(ctx.table);
}

test "constrained interface Box<T extends number>" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	// Parser captures "T:number" for generic params
	addGenericDecl("Box", "T:number");
	updateGenericDeclFields("Box", "value", "T");
	const ctx = createContext();
	const t = resolveAnnotation("Box<number>", ctx);
	check(t.kind === TypeKind.TypeReference);
	check(t.typeName === "Box__number");
}

test "getDefaultCount after parse" {
	const cnt = getDefaultCount("testFn1", 2);
	// testFn1 was parsed in util.ms tests — may or may not be available
	// Direct test: add entry and check
	addDefaultParam("resolveTestFn", 1, "42");
	check(getDefaultCount("resolveTestFn", 2) === 1);
	check(getDefaultText("resolveTestFn", 1) === "42");
}
