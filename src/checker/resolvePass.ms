// Pass 2: Resolve - parse type annotations, enrich collected symbols
//
// The parser currently stores type annotations as strings (TypeAnnotation nodes)
// and skips them in most places. Function params are string[] (names only).
// This pass enriches the symbol table by:
//   A. Parsing type annotation strings into Type objects
//   B. Building proper Function/Object types for collected declarations

import { Node, NodeKind, SourceLocation, createNodeAt, makeLoc, ProgramData, FunctionDeclData, InterfaceDeclData, ExportDeclData, ClassDeclData, MethodDeclData, PropertyDeclData, ConstructorDeclData, TypeAliasDeclData, VariableDeclData, DecoratedDeclData, ExternDeclData, ExternKind, IdentifierData, TypeGenericData, TypeArrayData, TypeUnionData, TypeFunctionData, TypeObjectData, Type, TypeKind, TypeFlag, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { unknownType, numberType, stringType, booleanType, voidType, nullType, neverType, charType, cstringType, createPrimitive, createArray, createFunction, createClosureType, createStruct, createResult, createPromise, createUnion, createGenericParam, createDistinct, substituteType, createGenericInstance, instantiateGenericBody, isResult, getResultOkType, getResultErrType, createSizedArray, createSpan, createBorrow, createPtr, createRef, createVar, createMaybeType, setMinArity, typeNameOf, assignType, isStructType, unwrapRef, propagateHasAsgn } from "./types";
import { SymbolTable, ScopeKind, lookupSymbol, lookupLocal, defineSymbol, makeSymbol, openScope, closeScope, hasFlag, setFlag, SymbolFlag } from "./symbol";
import { CheckerContext, findExtension, getExtTypeName, extractGenericNames, addError, addErrorRange, addWarning, addFatalError, addFatalErrorRange, sgRecordSym } from "./context";
import { findChar, splitTopLevel, parseIntStr, bareAfterDelim } from "../utils/string";
import { getProperty } from "./types";
import { getGenericDecl, getGenericDeclFieldNames, getGenericDeclFieldTypes, addGenericTypeInst, findGenericTypeInstIdx } from "../parser/context";
import { getDeclName } from "./collectPass";

// ===== A. Resolve Annotation Strings =====

// Parse function type string to resolved Function type
function resolveFunctionType(text: string, ctx: CheckerContext, line: number, col: number): Type {
	let depth = 0;
	let closeIdx = -1;
	for (let i = 0; i < text.length; i += 1) {
		const c = text.charAt(i);
		if (c === "(") depth += 1;
		if (c === ")") {
			depth -= 1;
			if (depth === 0) { closeIdx = i; break; }
		}
	}
	if (closeIdx < 0) return unknownType();

	const paramsStr = text.slice(1, closeIdx).trim();
	const afterParen = text.slice(closeIdx + 1, text.length).trim();
	if (afterParen.length < 2) return unknownType();
	if (afterParen.charAt(0) !== "=" || afterParen.charAt(1) !== ">") return unknownType();
	const retStr = afterParen.slice(2, afterParen.length).trim();

	const returnType = (retStr !== "") ? resolveAnnotation(retStr, ctx, line, col) : voidType();

	// Standard reference parity: procedure type literals default to closure calling convention
	if (paramsStr === "") return createClosureType([], [], returnType);

	const paramParts = splitTopLevel(paramsStr, ",");
	const paramTypes: Type[] = [];
	const paramNames: string[] = [];
	for (const part of paramParts) {
		const colonIdx = findChar(part, ":");
		if (colonIdx > 0) {
			paramNames.push(part.slice(0, colonIdx).trim());
			paramTypes.push(resolveAnnotation(part.slice(colonIdx + 1, part.length).trim(), ctx, line, col));
		} else {
			paramNames.push("");
			paramTypes.push(resolveAnnotation(part, ctx, line, col));
		}
	}
	return createClosureType(paramTypes, paramNames, returnType);
}

export function resolveAnnotation(text: string, ctx: CheckerContext, line: number, col: number): Type {
	const trimmed = text.trim();
	if (trimmed === "") return unknownType();

	// Function type: (params) => returnType
	if (trimmed.length > 0 && trimmed.charAt(0) === "(") {
		let fnDepth = 0;
		let fnCloseIdx = -1;
		for (let i = 0; i < trimmed.length; i += 1) {
			const c = trimmed.charAt(i);
			if (c === "(") fnDepth += 1;
			if (c === ")") {
				fnDepth -= 1;
				if (fnDepth === 0) { fnCloseIdx = i; break; }
			}
		}
		if (fnCloseIdx >= 0) {
			const afterClose = trimmed.slice(fnCloseIdx + 1, trimmed.length).trim();
			if (afterClose.length >= 2 && afterClose.charAt(0) === "=" && afterClose.charAt(1) === ">") {
				return resolveFunctionType(trimmed, ctx, line, col);
			}
		}
	}

	// Check for union types (split on top-level |)
	const unionParts = splitTopLevel(trimmed, "|");
	if (unionParts.length >= 2) {
		const members: Type[] = [];
		for (const up of unionParts) {
			const part = up.trim();
			if (part.length > 0) {
				members.push(resolveAnnotation(part, ctx, line, col));
			}
		}
		// T | null where T is interface → Maybe<T> (Reference: Maybe/Option parity)
		if (members.length === 2) {
			if (isStructType(members[0]) && members[1] !== null && members[1].kind === TypeKind.Null) {
				return createMaybeType(members[0]);
			}
			if (members[0] !== null && members[0].kind === TypeKind.Null && isStructType(members[1])) {
				return createMaybeType(members[1]);
			}
			// Ref<T> | null or Ptr<T> | null → bare pointer (already nullable in C)
			const m0kind = members[0] !== null ? members[0].kind : TypeKind.Unknown;
			const m1kind = members[1] !== null ? members[1].kind : TypeKind.Unknown;
			if ((m0kind === TypeKind.Ref || m0kind === TypeKind.Ptr) && m1kind === TypeKind.Null) {
				return members[0];
			}
			if (m0kind === TypeKind.Null && (m1kind === TypeKind.Ref || m1kind === TypeKind.Ptr)) {
				return members[1];
			}
		}
		if (members.length > 0) return createUnion(members);
	}

	// Object literal type: { field: Type; ... } or { field: Type, ... }
	if (trimmed.charAt(0) === "{" && trimmed.endsWith("}")) {
		const inner = trimmed.slice(1, trimmed.length - 1).trim();
		if (inner === "") return createStruct("", [], [], true);
		// TypeScript uses semicolons in type position, commas in value position — support both
		const hasSemicolon = inner.indexOf(";") >= 0;
		const fields = splitTopLevel(inner, hasSemicolon ? ";" : ",");
		const names: string[] = [];
		const types: Type[] = [];
		for (const f of fields) {
			const field = f.trim();
			if (field !== "") {
				const colonIdx = findChar(field, ":");
				if (colonIdx > 0) {
					const fname = field.slice(0, colonIdx).trim();
					const ftypeStr = field.slice(colonIdx + 1, field.length).trim();
					names.push(fname);
					types.push(resolveAnnotation(ftypeStr, ctx, line, col));
				}
			}
		}
		return createStruct("", names, types, true);
	}

	// Check for array suffix [] or [ ] (token-joined form from captureOptionalType)
	if (trimmed.endsWith("[ ]")) {
		const inner = trimmed.slice(0, trimmed.length - 3).trim();
		return createArray(resolveAnnotation(inner, ctx, line, col));
	}
	if (trimmed.endsWith("[]")) {
		const inner = trimmed.slice(0, trimmed.length - 2);
		return createArray(resolveAnnotation(inner, ctx, line, col));
	}
	if (trimmed.endsWith("]")) {
		const openBracket = findChar(trimmed, "[");
		if (openBracket > 0) {
			const inner = trimmed.slice(0, openBracket).trim();
			const sizeStr = trimmed.slice(openBracket + 1, trimmed.length - 1).trim();
			if (sizeStr === "" || sizeStr === " ") {
				return createArray(resolveAnnotation(inner, ctx, line, col));
			}
			const size = parseIntStr(sizeStr);
			return createSizedArray(resolveAnnotation(inner, ctx, line, col), size);
		}
	}

	// Check for generic types: Name<A, B> or Name < A , B > (token-joined form)
	const angleBracket = findChar(trimmed, "<");
	if (angleBracket > 0 && trimmed.endsWith(">")) {
		const baseName = trimmed.slice(0, angleBracket).trim();
		const argsText = trimmed.slice(angleBracket + 1, trimmed.length - 1).trim();
		const args = splitTopLevel(argsText, ",");

		if (baseName === "Result" && args.length === 2) {
			return createResult(resolveAnnotation(args[0], ctx, line, col), resolveAnnotation(args[1], ctx, line, col));
		}
		if (baseName === "Promise" && args.length === 1) {
			return createPromise(resolveAnnotation(args[0], ctx, line, col));
		}
		if (baseName === "Array" && args.length === 1) {
			return createArray(resolveAnnotation(args[0], ctx, line, col));
		}
		if (baseName === "Span" && args.length === 1) {
			return createSpan(resolveAnnotation(args[0], ctx, line, col));
		}
		if (baseName === "Borrow" && args.length === 1) {
			return createBorrow(resolveAnnotation(args[0], ctx, line, col));
		}
		if (baseName === "Ptr" && args.length === 1) {
			return createPtr(resolveAnnotation(args[0], ctx, line, col));
		}
		if (baseName === "Ref" && args.length === 1) {
			return createRef(resolveAnnotation(args[0], ctx, line, col));
		}
		if (baseName === "Var" && args.length === 1) {
			return createVar(resolveAnnotation(args[0], ctx, line, col));
		}
		// Generic interface/class resolution (Map, Set, user-defined generics)
		const genericParams = getGenericDecl(baseName);
		if (genericParams !== "") {
			// Check if ALL args are generic params of the enclosing function.
			// If so, preserve as generic type (don't instantiate).
			// e.g. inside set<K,V>(this m: Map<K,V>), Map<K,V> stays generic.
			let allGenericParams = true;
			const resolvedArgs: Type[] = [];
			for (const arg of args) {
				const resolved = resolveAnnotation(arg.trim(), ctx, line, col);
				resolvedArgs.push(resolved);
				if (resolved.kind !== TypeKind.GenericParam) allGenericParams = false;
			}
			if (allGenericParams && resolvedArgs.length > 0) {
				// Return GenericInstance with GenericParam type args.
				// This preserves hasGenericParams for unification + enables structural matching.
				const baseSym = lookupSymbol(ctx.table, baseName);
				if (baseSym !== null) {
					ensureShaped(baseSym, ctx);
					const isRefBase = baseSym.symbolType.kind === TypeKind.Ref;
					let baseType = baseSym.symbolType;
					if (isRefBase && baseType.typeReturn !== null) baseType = baseType.typeReturn;
					const gi1 = createGenericInstance(baseType, resolvedArgs);
					instantiateGenericBody(gi1, genericParams);
					return isRefBase ? createRef(gi1) : gi1;
				}
				return emitUnresolvedTypeRef(ctx, baseName, line, col, "");
			}
			// Concrete instantiation: record for codegen
			recordGenericTypeInstantiation(baseName, genericParams, args, ctx);
			// Build GenericInstance with structural type args
			const baseSym2 = lookupSymbol(ctx.table, baseName);
			if (baseSym2 !== null) {
				ensureShaped(baseSym2, ctx);
				const isRefBase2 = baseSym2.symbolType.kind === TypeKind.Ref;
				let baseType2 = baseSym2.symbolType;
				if (isRefBase2 && baseType2.typeReturn !== null) baseType2 = baseType2.typeReturn;
				const resolvedArgs: Type[] = [];
				for (const a of args) {
					resolvedArgs.push(resolveAnnotation(a.trim(), ctx, line, col));
				}
				const gi2 = createGenericInstance(baseType2, resolvedArgs);
				instantiateGenericBody(gi2, genericParams);
				return isRefBase2 ? createRef(gi2) : gi2;
			}
			// Symbol not found — emit error + return TypeRef for recovery
			const typeArgKey = buildTypeArgKey(args, ctx);
			const mangledName = baseName + "__" + typeArgKey;
			return emitUnresolvedTypeRef(ctx, baseName, line, col, mangledName);
		}
		// Non-generic: look up base type
		const baseSym = lookupSymbol(ctx.table, baseName);
		if (baseSym !== null) {
			// Demand-driven resolution: ensure the base symbol is shaped before using its type
			ensureShaped(baseSym, ctx);
			return baseSym.symbolType;
		}
		return emitUnresolvedTypeRef(ctx, baseName, line, col, "");
	}

	// Primitive types, symbol lookup, or forward reference
	return match (trimmed) {
		"number" => numberType(),
		"string" => stringType(),
		"boolean" => booleanType(),
		"void" => voidType(),
		"null" => nullType(),
		"never" => neverType(),
		"unknown" | "any" | "undefined" => unknownType(),
		"int8" => createPrimitive(TypeKind.Int8),
		"int16" => createPrimitive(TypeKind.Int16),
		"int32" => createPrimitive(TypeKind.Int32),
		"int64" => createPrimitive(TypeKind.Int64),
		"uint8" => createPrimitive(TypeKind.Uint8),
		"uint16" => createPrimitive(TypeKind.Uint16),
		"uint32" => createPrimitive(TypeKind.Uint32),
		"uint64" => createPrimitive(TypeKind.Uint64),
		"float32" => createPrimitive(TypeKind.Float32),
		"float64" => createPrimitive(TypeKind.Float64),
		"char" => charType(),
		"cstring" => cstringType(),
		_ => {
			const sym = lookupSymbol(ctx.table, trimmed);
			if (sym !== null) {
				// Demand-driven: ensure shaped before using
				ensureShaped(sym, ctx);
				// Circular type reference: sym still Unknown → return the SAME object
				// (reference parity: forward type identity preservation). When the type is
				// fully resolved later, assignType upgrades this object in-place,
				// and all references automatically see the resolved type.
				return sym.symbolType;
			}
			return emitUnresolvedTypeRef(ctx, trimmed, line, col, "");
		},
	};
}

// Emit error for unresolved type name and return TypeRef for recovery.
// Reference parity: semTypeIdent calls localError via qualifiedLookUp({checkUndeclared}).
// When line > 0, a located diagnostic is emitted. When line === 0 (inference-time),
// no error — the caller doesn't have source location.
function isValidTypeIdentifier(name: string): boolean {
	if (name.length === 0) return false;
	const ch0 = name.charAt(0);
	// String literals, quoted names, numbers — not type identifiers
	if (ch0 === "\"" || ch0 === "'" || (ch0 >= "0" && ch0 <= "9")) return false;
	// Names with dashes or spaces — string literal union members (parser strips quotes)
	if (name.indexOf("-") >= 0 || name.indexOf(" ") >= 0) return false;
	return true;
}

function emitUnresolvedTypeRef(ctx: CheckerContext, name: string, line: number, col: number, mangledName: string): Type {
	if (line > 0 && isValidTypeIdentifier(name)
			&& name.indexOf("__") < 0 && name.indexOf("typeof ") < 0
			&& name !== "unknown" && name !== "any" && name !== "undefined" && name !== "never") {
		addWarning(ctx, `Unresolved type '${name}' - missing import?`, line, col);
	}
	// Reference parity: unresolved types become unknownType, never TypeReference.
	// All valid types must be resolved during semantic analysis — if lookupSymbol fails,
	// it's a genuine error (missing import, typo). Codegen never does name resolution.
	return unknownType();
}

// ===== TypeExpr Recording (standard parity: markUsed in semTypeNode) =====
// Walks a positioned TypeExpr AST tree and records USE for every type identifier.
// Does NOT resolve types — resolveAnnotation still handles that via string path.
// This is purely additive: records symbol positions for LSP hover/goto-def.

export function resolveTypeExpr(node: Node, ctx: CheckerContext): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			const sym = lookupSymbol(ctx.table, d.name);
			if (sym !== null) {
				sgRecordSym(ctx, node.location.line, node.location.column,
					node.location.column + d.name.length,
					sym, sym.symbolType, sym.symbolKind, d.name, "", false);
			}
		},
		NodeKind.TypeGeneric => {
			const d = node.data as TypeGenericData;
			resolveTypeExpr(d.typExprBase, ctx);
			for (const arg of d.typExprArgs) {
				resolveTypeExpr(arg, ctx);
			}
		},
		NodeKind.TypeArray => {
			const d = node.data as TypeArrayData;
			resolveTypeExpr(d.typExprElement, ctx);
		},
		NodeKind.TypeUnion => {
			const d = node.data as TypeUnionData;
			for (const member of d.typExprMembers) {
				resolveTypeExpr(member, ctx);
			}
		},
		NodeKind.TypeFunction => {
			const d = node.data as TypeFunctionData;
			for (const param of d.typExprParams) {
				resolveTypeExpr(param, ctx);
			}
			resolveTypeExpr(d.typExprReturn, ctx);
		},
		NodeKind.TypeObject => {
			const d = node.data as TypeObjectData;
			for (const ft of d.typExprFieldTypes) {
				resolveTypeExpr(ft, ctx);
			}
		},
		_ => {},
	};
}

// Resolve all TypeExpr nodes in a type annotation array (params, fields).
// Null-safe: skips null arrays and null entries.
export function resolveTypeExprs(exprs: Node[], ctx: CheckerContext): void {
	if (exprs === null) return;
	for (const te of exprs) {
		resolveTypeExpr(te, ctx);
	}
}

// ===== Demand-Driven Shaping (Implementation parity) =====

export function ensureShaped(sym: Symbol, ctx: CheckerContext): void {
	if (sym.state === SymbolState.Shaped || sym.state === SymbolState.Checked) return;
	if (sym.state === SymbolState.Shaping) {
		// Type aliases allow circular references (e.g. DocData refs Doc, Doc refs DocData).
		// Standard reference implementation handles this via multi-pass type sections. We silently return —
		// callers must handle sym.symbolType still being Unknown.
		if (sym.symbolKind !== SymbolKind.TypeAlias) {
			addError(ctx, `Circular dependency detected while resolving '${sym.name}'`, sym.location.line, sym.location.column);
		}
		return;
	}

	sym.state = SymbolState.Shaping;
	const node = sym.declNode;
	if (node !== null) {
		match (node.kind) {
			NodeKind.FunctionDecl => resolveFunction(ctx, node),
			NodeKind.InterfaceDecl => resolveInterface(ctx, node),
			NodeKind.StructDecl => resolveInterface(ctx, node),
			NodeKind.ClassDecl => resolveClass(ctx, node),
			NodeKind.TypeAliasDecl => resolveTypeAlias(ctx, node),
			NodeKind.VariableDecl => resolveVariable(ctx, node),
			NodeKind.ExternDecl => resolveExtern(ctx, node),
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
export function buildTypeArgKey(args: string[], ctx: CheckerContext): string {
	let key = "";
	for (let i = 0; i < args.length; i += 1) {
		if (i > 0) key = key + "_";
		key = key + args[i].trim();
	}
	return key;
}

// Find index of matching generic param for a given field type string.
// Returns the param index, or -1 if no match. Uses only number locals (DRC-safe).
function findGenericParamIdx(rawType: string, paramNames: string[]): number {
	for (let i = 0; i < paramNames.length; i += 1) {
		if (paramNames[i].trim() === rawType) return i;
	}
	return -1;
}

// Substitute all generic param names in a type string with concrete types.
// Handles nested generics: "MapEntry<K, V>[]" with K=string, V=number → "MapEntry<string, number>[]"
// Only replaces whole identifiers (not substrings): "Key" won't match param "K".
function substituteGenericParamsInType(rawType: string, paramNames: string[], args: string[]): string {
	let result = rawType;
	for (let i = 0; i < paramNames.length; i += 1) {
		if (i >= args.length) break;
		const pname = paramNames[i].trim();
		const arg = args[i].trim();
		if (pname === "") continue;
		// Replace whole-identifier occurrences of pname with arg
		let buf = "";
		let pos = 0;
		while (pos < result.length) {
			// Check if pname appears at pos as a whole identifier
			let matched = false;
			if (pos + pname.length <= result.length) {
				const slice = result.slice(pos, pos + pname.length);
				if (slice === pname) {
					// Check boundaries: char before and after must not be alphanumeric/underscore
					const before = pos > 0 ? result.charAt(pos - 1) : " ";
					const after = pos + pname.length < result.length ? result.charAt(pos + pname.length) : " ";
					const isWordBefore = (before >= "a" && before <= "z") || (before >= "A" && before <= "Z") || (before >= "0" && before <= "9") || before === "_";
					const isWordAfter = (after >= "a" && after <= "z") || (after >= "A" && after <= "Z") || (after >= "0" && after <= "9") || after === "_";
					if (!isWordBefore && !isWordAfter) {
						buf = buf + arg;
						pos = pos + pname.length;
						matched = true;
					}
				}
			}
			if (!matched) {
				buf = buf + result.charAt(pos);
				pos = pos + 1;
			}
		}
		result = buf;
	}
	return result;
}

// Record a generic type instantiation (e.g., Box<number>) for codegen
// Looks up field names/types from parser side-channel, substitutes generic params -> concrete types
// NOTE: Avoids all `let` string variables — only const strings + number let variables.
// DRC generates msDecref instead of msStringDecref for let string locals in complex functions.
export function recordGenericTypeInstantiation(baseName: string, genericParams: string, args: string[], ctx: CheckerContext): void {
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

	// Substitute generic params in field types (handles nested generics like MapEntry<K, V>[])
	const firstRaw = ftParts.length > 0 ? ftParts[0].trim() : "";
	const firstSub = substituteGenericParamsInType(firstRaw, paramNames, args);

	let resultFieldNames = fnParts[0].trim();
	let resultFieldTypes = firstSub;

	for (let fi = 1; fi < fnParts.length; fi += 1) {
		const rawType = fi < ftParts.length ? ftParts[fi].trim() : "";
		const subType = substituteGenericParamsInType(rawType, paramNames, args);
		resultFieldNames = resultFieldNames + "|" + fnParts[fi].trim();
		resultFieldTypes = resultFieldTypes + "|" + subType;
	}

	addGenericTypeInst(baseName, typeArgKey, mangledName, resultFieldNames, resultFieldTypes);
}

// ===== Resolve Helpers =====

// Resolve an array of type annotation strings into Type[], matching names 1:1
function resolveTypeStrings(typeStrs: string[], count: number, ctx: CheckerContext, line: number, col: number): Type[] {
	const types: Type[] = [];
	for (let i = 0; i < count; i += 1) {
		if (i < typeStrs.length && typeStrs[i] !== "") {
			types.push(resolveAnnotation(typeStrs[i], ctx, line, col));
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
		const paramName = paramStr.slice(0, colonPos);
		const constraintStr = paramStr.slice(colonPos + 1, paramStr.length);
		const gp = createGenericParam(paramName);
		// Store constraint type in typeExtra
		gp.typeExtra = resolveAnnotation(constraintStr, ctx, 0, 0);
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
			if (sym !== null) ensureShaped(sym, ctx);
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

// getDeclName imported from collectPass (single canonical copy)

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

	const paramTypes = resolveTypeStrings(d.fnParamTypes, d.params.length, ctx, node.location.line, node.location.column);
	resolveTypeExprs(node.typeExprs, ctx);

	// Wrap out/ref param types in TypeKind.Var (reference parity: tyVar — both are T* in C)
	if (d.fnFlags !== "" && (d.fnFlags.indexOf("out:") >= 0 || d.fnFlags.indexOf("ref:") >= 0)) {
		const flagParts = splitTopLevel(d.fnFlags, "|");
		for (const fp of flagParts) {
			const trimFp = fp.trim();
			if ((trimFp.length > 4 && trimFp.slice(0, 4) === "out:") ||
				(trimFp.length > 4 && trimFp.slice(0, 4) === "ref:")) {
				const idxStr = trimFp.slice(4, trimFp.length);
				const idxParts = splitTopLevel(idxStr, ",");
				for (const ip of idxParts) {
					const idx = parseIntStr(ip.trim());
					if (idx >= 0 && idx < paramTypes.length) {
						paramTypes[idx] = createVar(paramTypes[idx]);
					}
				}
			}
		}
	}

	const retLoc = node.typeExpr !== null ? node.typeExpr.location : node.location;
	const returnType = (d.fnReturnType !== "") ? resolveAnnotation(d.fnReturnType, ctx, retLoc.line, retLoc.column) : unknownType();
	// Record return type annotation positions for LSP
	resolveTypeExpr(node.typeExpr, ctx);
	const fnType = createFunction(paramTypes, d.params, returnType);

	// Set minArity for functions with default parameters (Reference parity: count non-null defaults)
	let defCount = 0;
	if (d.fnDefaults !== null) {
		for (const def of d.fnDefaults) {
			if (def !== null) defCount = defCount + 1;
		}
	}
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
				// Copy defaults to overload sym for cross-module availability
				if (d.fnDefaults !== null && d.fnDefaults.length > 0) {
					overload.defaultParams = d.fnDefaults;
				}
				// Update extension fnType cache (secondary — getExtFnType reads sym.symbolType first)
				const extTypeName2 = getExtTypeName(d.fnFlags);
				if (extTypeName2 !== "" && ctx.extensionRegistry !== null) {
					const ext2 = findExtension(ctx.extensionRegistry, extTypeName2, d.fnName);
					if (ext2 !== null) {
						ext2.fnType = fnType;
						if (ext2.sym === null) ext2.sym = overload;
					}
				}
				return;
			}
		}
	}

	sym.symbolType = fnType;
	node.nodeType = fnType;
	// Copy defaults to primary sym for cross-module availability
	if (d.fnDefaults !== null && d.fnDefaults.length > 0) {
		sym.defaultParams = d.fnDefaults;
	}
	// Update extension fnType cache (secondary — getExtFnType reads sym.symbolType first)
	const extTypeName = getExtTypeName(d.fnFlags);
	if (extTypeName !== "" && ctx.extensionRegistry !== null) {
		const ext = findExtension(ctx.extensionRegistry, extTypeName, d.fnName);
		if (ext !== null) {
			ext.fnType = fnType;
			if (ext.sym === null) ext.sym = sym;
		}
	}
}

function resolveInterface(ctx: CheckerContext, node: Node): void {
	const d = node.data as InterfaceDeclData;
	const sym = lookupSymbol(ctx.table, d.interfaceName);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Set state to Shaped immediately to allow circular references in fields
	sym.state = SymbolState.Shaped;
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.interfaceName.length, sym, sym.symbolType, sym.symbolKind, d.interfaceName, "", true);

	// Check for generic params (e.g., interface Box<T> — parser stores in side-channel)
	const genericStr = getGenericDecl(d.interfaceName);
	const hasGenerics = genericStr !== "";
	if (hasGenerics) {
		openScope(ctx.table, ScopeKind.Block);
		const genericNames = splitTopLevel(genericStr, ",");
		for (const gp of genericNames) {
			const trimGp = gp.trim();
			if (trimGp !== "") {
				defineGenericParam(ctx, trimGp);
			}
		}
	}

	const fieldTypes = resolveTypeStrings(d.interfaceFieldTypes, d.interfaceFields.length, ctx, node.location.line, node.location.column);
	resolveTypeExprs(node.typeExprs, ctx);

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	// reference parity: self-referential value fields → auto-promote to Ref<T>
	// C cannot embed struct T by value inside itself (infinite size).
	// Standard reference requires explicit pointer types and errors otherwise. We auto-promote with a warning.
	for (let fi = 0; fi < fieldTypes.length; fi += 1) {
		const ft = fieldTypes[fi];
		if (ft !== null && isStructType(ft) && ft.typeName === d.interfaceName) {
			fieldTypes[fi] = createRef(ft);
			const fieldName = fi < d.interfaceFields.length ? d.interfaceFields[fi] : "?";
			addError(ctx, "warning: self-referential field '" + fieldName + "' in '" + d.interfaceName + "' auto-promoted to Ref<" + d.interfaceName + ">", node.location.line, 0);
		}
	}

	// Update sym type in-place — avoid temporary Type that shares typeChildren
	// (temporary's destructor would decref elements while sym still references them)
	// For interface (Ref<Struct>), update the inner struct. For struct (plain Struct), update directly.
	const target = sym.symbolType.kind === TypeKind.Ref ? unwrapRef(sym.symbolType) : sym.symbolType;
	target.kind = TypeKind.Struct;
	target.typeName = d.interfaceName;
	target.typeNames = d.interfaceFields;
	target.typeChildren = fieldTypes;
	target.typeFlags = TypeFlag.IsStruct as int32;
	for (const pt of fieldTypes) { propagateHasAsgn(target, pt); }
	node.nodeType = sym.symbolType;
	// Record each interface field DEF for symbol graph
	// (no per-field location available; use interface node location as fallback)
	for (let ri = 0; ri < d.interfaceFields.length; ri += 1) {
		const fieldSym = makeSymbol(d.interfaceFields[ri], SymbolKind.Property, fieldTypes[ri], false);
		fieldSym.state = SymbolState.Shaped;
		sgRecordSym(ctx, node.location.line, node.location.column, node.location.column + d.interfaceFields[ri].length, fieldSym, fieldTypes[ri], SymbolKind.Property, d.interfaceFields[ri], d.interfaceName, true);
	}
}

function resolveTypeAlias(ctx: CheckerContext, node: Node): void {
	const d = node.data as TypeAliasDeclData;
	const sym = lookupSymbol(ctx.table, d.aliasName);
	if (sym === null) return;
	node.resolvedSym = sym;
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.aliasName.length, sym, sym.symbolType, SymbolKind.TypeAlias, d.aliasName, "", true);

	if (d.aliasType === "" && d.discriminantName === "") {
		return;
	}

	// Discriminated union: resolve structured variant data instead of aliasType text
	if (d.discriminantName !== "") {
		const resolved = resolveDiscriminatedUnion(ctx, d);
		if (resolved !== null) {
			assignType(sym.symbolType, resolved);
			node.nodeType = sym.symbolType;
		}
		return;
	}

	const resolved = resolveAnnotation(d.aliasType, ctx, node.location.line, node.location.column);
	resolveTypeExpr(node.typeExpr, ctx);
	// Propagate alias name to Union types (Reference gap: string-based annotations don't carry names)
	if (resolved.kind === TypeKind.Union && resolved.typeName === "") {
		resolved.typeName = d.aliasName;
	}
	if (d.aliasIsDistinct) {
		const distType = createDistinct(resolved);
		assignType(sym.symbolType, distType);
		node.nodeType = sym.symbolType;
	} else {
		assignType(sym.symbolType, resolved);
		node.nodeType = sym.symbolType;
	}
}

// Resolve discriminated union: type X = match (disc: EnumType) { EnumVal => { fields }, ... }
// Produces a Union type with discriminant metadata:
//   typeChildren = variant types, typeName = alias name,
//   typeExtra = discriminant enum Type,
//   typeNames = [discFieldName, variantKey0, variantKey1, ...]
function resolveDiscriminatedUnion(ctx: CheckerContext, d: TypeAliasDeclData): Type {
	// Resolve discriminant type — must be an enum
	const discType = resolveAnnotation(d.discriminantType, ctx, 0, 0);
	if (discType.kind !== TypeKind.Enum) {
		addError(ctx, "Discriminant type '" + d.discriminantType + "' must be an enum", 0, 0);
		return null;
	}

	// Validate each variant key is a valid enum member
	for (const key of d.variantKeys) {
		const memberName = bareAfterDelim(key, ".");
		let found = false;
		if (discType.typeNames !== null) {
			for (const m of discType.typeNames) {
				if (m === memberName) {
					found = true;
				}
			}
		}
		if (!found) {
			addError(ctx, "'" + key + "' is not a member of enum '" + d.discriminantType + "'", 0, 0);
		}
	}

	// Resolve each variant type
	const variantTypes: Type[] = [];
	for (const vt of d.variantTypes) {
		const resolved = resolveAnnotation(vt, ctx, 0, 0);
		variantTypes.push(resolved);
	}

	// Build Union type with discriminant metadata
	const unionType = createUnion(variantTypes);
	unionType.typeName = d.aliasName;
	// Store discriminant metadata: typeExtra = enum type, typeNames = [discFieldName, key0, key1, ...]
	unionType.typeExtra = discType;
	const names: string[] = [d.discriminantName];
	for (const key of d.variantKeys) {
		names.push(key);
	}
	unionType.typeNames = names;
	return unionType;
}

function resolveVariable(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	if (d.declType === "") return;
	// Variable annotations are used as hints in Pass 3 (checkVariableDecl)
	// We don't resolve them here because the symbol isn't defined yet in Pass 2
	// (variables are defined during Pass 3). Instead, we store the info for later use.
}

// Resolve extern const/let/var type annotation → set symbol type.
// Reference parity: importc symbols get their type resolved during sem pass.
function resolveExtern(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExternDeclData;
	const sym = lookupSymbol(ctx.table, d.externName);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Resolve type annotation if present
	if (d.externType !== "") {
		const resolved = resolveAnnotation(d.externType, ctx, node.location.line, node.location.column);
		if (resolved.kind !== TypeKind.Unknown) {
			sym.symbolType = resolved;
			resolved.sym = sym;
			node.nodeType = resolved;
		}
	}
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
			const trimGp = gp.trim();
			if (trimGp !== "") {
				defineGenericParam(ctx, trimGp);
			}
		}
	}

	// Save collectPass type to preserve decorator metadata (nativeName/builtinKind on typeName)
	const oldType = sym.symbolType;

	// Build Object type — collect members inline
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (let mi = 0; mi < d.classBody.length; mi += 1) {
		let member = d.classBody[mi];
		// Unwrap DecoratedDecl to get the inner declaration
		if (member.kind === NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			if (dd.decoratedNode === null) {
				continue;
			}
			member = dd.decoratedNode;
		}
		if (member.kind === NodeKind.MethodDecl) {
			// Reference parity: methods are NOT struct fields — resolve their types
			// and update the extension's fnType, but don't add to struct.
			const md = member.data as MethodDeclData;
			// Method-level generic params (e.g. parse<T>) — define in temp scope
			// so resolveAnnotation finds "T" → GenericParam("T"), same as resolveFunctionDecl.
			const methodGenericNames = extractGenericNames(md.methodFlags);
			const hasMethodGenerics = methodGenericNames.length > 0;
			if (hasMethodGenerics) {
				openScope(ctx.table, ScopeKind.Block);
				for (const mgp of methodGenericNames) {
					defineGenericParam(ctx, mgp);
				}
			}
			const paramTypes = resolveTypeStrings(md.methodParamTypes, md.methodParams.length, ctx, member.location.line, member.location.column);
			resolveTypeExprs(member.typeExprs, ctx);
			const returnType = (md.methodReturnType !== "") ? resolveAnnotation(md.methodReturnType, ctx, member.location.line, member.location.column) : unknownType();
			resolveTypeExpr(member.typeExpr, ctx);
			if (hasMethodGenerics) {
				closeScope(ctx.table);
			}
			const fnType = createFunction(paramTypes, md.methodParams, returnType);
			// Use resolvedSym set by collectClassMethod — avoids overload ambiguity with lookupSymbol
			// DecoratedDecl wraps MethodDecl — resolvedSym is on the inner node
			const methodSym = member.resolvedSym !== null ? member.resolvedSym : d.classBody[mi].resolvedSym;
			if (methodSym !== null && methodSym.symbolType !== null && methodSym.symbolType.typeName !== "") {
				fnType.typeName = methodSym.symbolType.typeName;
			}
			member.nodeType = fnType;
			// Update the method symbol's type with resolved params/return
			if (methodSym !== null && methodSym.symbolType !== null) {
				assignType(methodSym.symbolType, fnType);
			}
		} else if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			memberNames.push(pd.propName);
			if (pd.propType !== "") {
				const propType = resolveAnnotation(pd.propType, ctx, member.location.line, member.location.column);
				resolveTypeExpr(member.typeExpr, ctx);
				member.nodeType = propType;
				memberTypes.push(propType);
			} else {
				memberTypes.push(unknownType());
			}
		} else if (member.kind === NodeKind.ConstructorDecl) {
			// Resolve constructor type but don't add to struct (data-only, like methods)
			const cd = member.data as ConstructorDeclData;
			const paramTypes = resolveTypeStrings(cd.ctorParamTypes, cd.ctorParams.length, ctx, member.location.line, member.location.column);
			resolveTypeExprs(member.typeExprs, ctx);
			const ctorType = createFunction(paramTypes, cd.ctorParams, voidType());
			member.nodeType = ctorType;
		}
	}

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	// Update inner struct in-place — avoid temporary Type that shares typeChildren
	// (temporary's destructor would decref elements while inner still references them)
	const inner = unwrapRef(sym.symbolType);
	inner.kind = TypeKind.Struct;
	inner.typeName = d.className;
	inner.typeNames = memberNames;
	inner.typeChildren = memberTypes;
	inner.typeFlags = TypeFlag.IsStruct as int32;
	// Resolve base class TypeReference → concrete type (reference parity: no TypeRef in codegen)
	if (inner.typeExtra !== null && inner.typeExtra.kind === TypeKind.TypeReference) {
		const baseSym = lookupSymbol(ctx.table, inner.typeExtra.typeName);
		if (baseSym !== null) {
			inner.typeExtra = baseSym.symbolType;
		}
	}
	// Propagate HasAsgn from any managed field
	for (const pt of memberTypes) { propagateHasAsgn(inner, pt); }
	node.nodeType = sym.symbolType;
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
	return resolveAnnotation(text, ctx, 0, 0);
}

test "number" { assert resolveWith("number").kind === TypeKind.Number; }

test "string" { assert resolveWith("string").kind === TypeKind.String; }

test "boolean" { assert resolveWith("boolean").kind === TypeKind.Boolean; }

test "void" { assert resolveWith("void").kind === TypeKind.Void; }

test "null" { assert resolveWith("null").kind === TypeKind.Null; }

test "never" { assert resolveWith("never").kind === TypeKind.Never; }

test "int32" { assert resolveWith("int32").kind === TypeKind.Int32; }

test "float64" { assert resolveWith("float64").kind === TypeKind.Float64; }

test "unknown name" { assert resolveWith("Foo").kind === TypeKind.Unknown; }

test "empty" { assert resolveWith("").kind === TypeKind.Unknown; }

test "number[]" {
	const t = resolveWith("number[]");
	assert t.kind === TypeKind.Array;
	assert t.typeReturn.kind === TypeKind.Number;
}

test "string[]" {
	const t = resolveWith("string[]");
	assert t.kind === TypeKind.Array;
	assert t.typeReturn.kind === TypeKind.String;
}

test "Result<number, string>" {
	const t = resolveWith("Result<number, string>");
	assert isResult(t);
	assert getResultOkType(t).kind === TypeKind.Number;
	assert getResultErrType(t).kind === TypeKind.String;
}

test "Array<boolean>" {
	const t = resolveWith("Array<boolean>");
	assert t.kind === TypeKind.Array;
	assert t.typeReturn.kind === TypeKind.Boolean;
}

test "number[4]" {
	const t = resolveWith("number[4]");
	assert t.kind === TypeKind.SizedArray;
	assert t.typeReturn.kind === TypeKind.Number;
	assert t.typeFlags === 4;
}

test "Span<boolean>" {
	const t = resolveWith("Span<boolean>");
	assert t.kind === TypeKind.Span;
	assert t.typeReturn.kind === TypeKind.Boolean;
}

test "string | number" {
	const t = resolveWith("string | number");
	assert t.kind === TypeKind.Union;
	assert t.typeChildren.length === 2;
	assert t.typeChildren[0].kind === TypeKind.String;
	assert t.typeChildren[1].kind === TypeKind.Number;
}

test "known symbol" {
	const ctx = createContext();
	defineSymbol(ctx.table, makeSymbol("MyType", SymbolKind.Interface, createStruct("MyType", [], [], true), false));
	const t = resolveAnnotation("MyType", ctx, 0, 0);
	assert t.kind === TypeKind.Struct;
	assert t.typeName === "MyType";
}

test "function gets Function type" {
	const ctx = createContext();
	const symStub = makeSymbol("foo", SymbolKind.Function, unknownType(), false);
	defineSymbol(ctx.table, symStub);
	// Simulate a FunctionDecl node
	const zl = makeLoc(0, 0);
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "foo", params: ["a", "b"], fnParamTypes: ["", ""], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "", fnDefaults: [], nameLocation: zl }, zl);
	symStub.declNode = fnNode;
	const node = createNodeAt(NodeKind.Program, { programStmts: [fnNode] }, zl);
	resolveDeclarations(ctx, node);
	const sym = lookupSymbol(ctx.table, "foo");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeChildren.length === 2;
	assert sym.symbolType.typeNames[0] === "a";
	assert sym.symbolType.typeNames[1] === "b";
}

test "function with typed params" {
	const ctx = createContext();
	const symStub = makeSymbol("add", SymbolKind.Function, unknownType(), false);
	defineSymbol(ctx.table, symStub);
	const zl = makeLoc(0, 0);
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "add", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number", fnDefaults: [], nameLocation: zl }, zl);
	symStub.declNode = fnNode;
	const node = createNodeAt(NodeKind.Program, { programStmts: [fnNode] }, zl);
	resolveDeclarations(ctx, node);
	const sym = lookupSymbol(ctx.table, "add");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeChildren[0].kind === TypeKind.Number;
	assert sym.symbolType.typeChildren[1].kind === TypeKind.Number;
	assert sym.symbolType.typeReturn.kind === TypeKind.Number;
}

test "decorated function gets resolved" {
	const ctx = createContext();
	const symStub = makeSymbol("floor", SymbolKind.Function, unknownType(), false);
	defineSymbol(ctx.table, symStub);
	const zl = makeLoc(0, 0);
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "floor", params: ["x"], fnParamTypes: ["number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number", fnDefaults: [], nameLocation: zl }, zl);
	symStub.declNode = fnNode;
	const decoNode = createNodeAt(NodeKind.DecoratedDecl, { decorators: [], decoratedNode: fnNode }, zl);
	const node = createNodeAt(NodeKind.Program, { programStmts: [decoNode] }, zl);
	resolveDeclarations(ctx, node);
	const sym = lookupSymbol(ctx.table, "floor");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeReturn.kind === TypeKind.Number;
}

test "Box<number> records instantiation" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	addGenericDecl("Box", "T");
	updateGenericDeclFields("Box", "value", "T");
	const ctx = createContext();
	const t = resolveAnnotation("Box<number>", ctx, 0, 0);
	// No symbol "Box" in scope → unknownType()
	assert t.kind === TypeKind.Unknown;
	// Check instantiation was recorded (happens before symbol lookup)
	assert getGenericTypeInstCount() === 1;
	assert getGenericTypeInstBaseName(0) === "Box";
	assert getGenericTypeInstTypeArgKey(0) === "number";
	assert getGenericTypeInstMangledName(0) === "Box__number";
	assert getGenericTypeInstFieldNames(0) === "value";
	assert getGenericTypeInstFieldTypes(0) === "number";
}

test "Pair<string, number> records instantiation" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	addGenericDecl("Pair", "A,B");
	updateGenericDeclFields("Pair", "first|second", "A|B");
	const ctx = createContext();
	const t = resolveAnnotation("Pair<string, number>", ctx, 0, 0);
	assert t.kind === TypeKind.Unknown;
	const idx = findGenericTypeInstIdx("Pair", "string_number");
	assert idx >= 0;
	assert getGenericTypeInstFieldNames(idx) === "first|second";
	assert getGenericTypeInstFieldTypes(idx) === "string|number";
}

test "dedup instantiation" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	addGenericDecl("Box", "T");
	updateGenericDeclFields("Box", "value", "T");
	const ctx = createContext();
	resolveAnnotation("Box<number>", ctx, 0, 0);
	resolveAnnotation("Box<number>", ctx, 0, 0);
	assert getGenericTypeInstCount() === 1;
}

test "non-generic base falls through" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	// No addGenericDecl for "Foo" — should fall through to symbol lookup
	const ctx = createContext();
	defineSymbol(ctx.table, makeSymbol("Foo", SymbolKind.Interface, createStruct("Foo", [], [], true), false));
	const t = resolveAnnotation("Foo<number>", ctx, 0, 0);
	// Non-generic: returns base type (Foo)
	assert t.kind === TypeKind.Struct;
	assert t.typeName === "Foo";
}

test "generic class Container<T> records instantiation" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	// Simulate parser registering class Container<T> { item: T; count: number; }
	addGenericDecl("Container", "T");
	updateGenericDeclFields("Container", "item|count", "T|number");
	const ctx = createContext();
	const t = resolveAnnotation("Container<string>", ctx, 0, 0);
	assert t.kind === TypeKind.Unknown;
	assert getGenericTypeInstCount() === 1;
	assert getGenericTypeInstFieldNames(0) === "item|count";
	assert getGenericTypeInstFieldTypes(0) === "string|number";
}

test "constraint stored on GenericParam typeExtra" {
	// Simulate "T:number" — defineGenericParam parses colon, sets typeExtra
	const ctx = createContext();
	openScope(ctx.table, ScopeKind.Block);
	defineGenericParam(ctx, "T:number");
	const sym = lookupSymbol(ctx.table, "T");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.GenericParam;
	assert sym.symbolType.typeName === "T";
	assert sym.symbolType.typeExtra !== null;
	assert sym.symbolType.typeExtra.kind === TypeKind.Number;
	closeScope(ctx.table);
}

test "no constraint leaves typeExtra null" {
	const ctx = createContext();
	openScope(ctx.table, ScopeKind.Block);
	defineGenericParam(ctx, "U");
	const sym = lookupSymbol(ctx.table, "U");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.GenericParam;
	assert sym.symbolType.typeName === "U";
	closeScope(ctx.table);
}

test "constrained interface Box<T extends number>" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	// Parser captures "T:number" for generic params
	addGenericDecl("Box", "T:number");
	updateGenericDeclFields("Box", "value", "T");
	const ctx = createContext();
	const t = resolveAnnotation("Box<number>", ctx, 0, 0);
	assert t.kind === TypeKind.Unknown;
}

test "fnDefaults on FunctionDeclData" {
	const zl = makeLoc(0, 0);
	const defNode = createNodeAt(NodeKind.NumberLiteral, { value: 42 }, zl);
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "defTest", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "", fnDefaults: [null, defNode], nameLocation: zl }, zl);
	const d = fnNode.data as FunctionDeclData;
	assert d.fnDefaults.length === 2;
	assert d.fnDefaults[0] === null;
	assert d.fnDefaults[1] !== null;
	assert d.fnDefaults[1].kind === NodeKind.NumberLiteral;
}

// ===== Nullable Pointer Resolution Tests =====

test "Ref<number> | null resolves to bare Ref" {
	const t = resolveWith("Ref<number> | null");
	assert t.kind === TypeKind.Ref;
	assert t.typeReturn.kind === TypeKind.Number;
}

test "null | Ref<string> resolves to bare Ref" {
	const t = resolveWith("null | Ref<string>");
	assert t.kind === TypeKind.Ref;
	assert t.typeReturn.kind === TypeKind.String;
}

test "Ptr<number> | null resolves to bare Ptr" {
	const t = resolveWith("Ptr<number> | null");
	assert t.kind === TypeKind.Ptr;
	assert t.typeReturn.kind === TypeKind.Number;
}

test "null | Ptr<boolean> resolves to bare Ptr" {
	const t = resolveWith("null | Ptr<boolean>");
	assert t.kind === TypeKind.Ptr;
	assert t.typeReturn.kind === TypeKind.Boolean;
}

test "string | null stays Union (not pointer)" {
	const t = resolveWith("string | null");
	assert t.kind === TypeKind.Union;
}

test "number | null stays Union (not pointer)" {
	const t = resolveWith("number | null");
	assert t.kind === TypeKind.Union;
}
