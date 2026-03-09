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
	unknownType, numberType, stringType, booleanType, voidType, nullType, neverType, charType, cstringType,
	createPrimitive, createArray, createFunction, createClosureType, createStruct,
	createResult, createTypeRef, createUnion, createGenericParam, createDistinct,
	createSizedArray, createSpan, createBorrow, createPtr, createRef, createVar, createMaybeType, createMap, createSet,
	setMinArity, typeNameOf, assignType, isInterfaceType, unwrapRef,
} from "./types";
import { Symbol, SymbolKind, SymbolTable, ScopeKind, lookupSymbol, lookupLocal, defineSymbol, makeSymbol, openScope, closeScope, SymbolState, hasFlag, setFlag, SymbolFlag } from "./symbol";
import { CheckerContext, findExtension, getExtTypeName, extractGenericNames, addError } from "./context";
import { trimStr, sliceStr, findChar, charAt, splitTopLevel, parseIntStr, bareAfterDelim } from "../utils/string";
import { getProperty } from "./types";
import { getGenericDecl, getGenericDeclFieldNames, getGenericDeclFieldTypes, addGenericTypeInst, findGenericTypeInstIdx } from "../parser/context";
import { getDeclName } from "./collectPass";

// ===== A. Resolve Annotation Strings =====

// Parse function type string to resolved Function type
function resolveFunctionType(text: string, ctx: CheckerContext): Type {
	let depth = 0;
	let closeIdx = -1;
	for (let i = 0; i < text.length; i += 1) {
		const c = charAt(text, i);
		if (c === "(") depth += 1;
		if (c === ")") {
			depth -= 1;
			if (depth === 0) { closeIdx = i; break; }
		}
	}
	if (closeIdx < 0) return createTypeRef(text);

	const paramsStr = trimStr(sliceStr(text, 1, closeIdx));
	const afterParen = trimStr(sliceStr(text, closeIdx + 1, text.length));
	if (afterParen.length < 2) return createTypeRef(text);
	if (charAt(afterParen, 0) !== "=" || charAt(afterParen, 1) !== ">") return createTypeRef(text);
	const retStr = trimStr(sliceStr(afterParen, 2, afterParen.length));

	const returnType = (retStr !== "") ? resolveAnnotation(retStr, ctx) : voidType();

	// Standard reference parity: procedure type literals default to closure calling convention
	if (paramsStr === "") return createClosureType([], [], returnType);

	const paramParts = splitTopLevel(paramsStr, ",");
	const paramTypes: Type[] = [];
	const paramNames: string[] = [];
	for (const part of paramParts) {
		const colonIdx = findChar(part, ":");
		if (colonIdx > 0) {
			paramNames.push(trimStr(sliceStr(part, 0, colonIdx)));
			paramTypes.push(resolveAnnotation(trimStr(sliceStr(part, colonIdx + 1, part.length)), ctx));
		} else {
			paramNames.push("");
			paramTypes.push(resolveAnnotation(part, ctx));
		}
	}
	return createClosureType(paramTypes, paramNames, returnType);
}

export function resolveAnnotation(text: string, ctx: CheckerContext): Type {
	const trimmed = trimStr(text);
	if (trimmed === "") return unknownType();

	// Function type: (params) => returnType
	if (trimmed.length > 0 && charAt(trimmed, 0) === "(") {
		let fnDepth = 0;
		let fnCloseIdx = -1;
		for (let i = 0; i < trimmed.length; i += 1) {
			const c = charAt(trimmed, i);
			if (c === "(") fnDepth += 1;
			if (c === ")") {
				fnDepth -= 1;
				if (fnDepth === 0) { fnCloseIdx = i; break; }
			}
		}
		if (fnCloseIdx >= 0) {
			const afterClose = trimStr(sliceStr(trimmed, fnCloseIdx + 1, trimmed.length));
			if (afterClose.length >= 2 && charAt(afterClose, 0) === "=" && charAt(afterClose, 1) === ">") {
				return resolveFunctionType(trimmed, ctx);
			}
		}
	}

	// Check for union types (split on top-level |)
	const unionParts = splitTopLevel(trimmed, "|");
	if (unionParts.length >= 2) {
		const members: Type[] = [];
		let ui = 0;
		while (ui < unionParts.length) {
			const part = trimStr(unionParts[ui]);
			if (part.length > 0) {
				members.push(resolveAnnotation(part, ctx));
			}
			ui += 1;
		}
		// T | null where T is interface → Maybe<T> (Reference: Maybe/Option parity)
		if (members.length === 2) {
			if (isInterfaceType(members[0]) && members[1] !== null && members[1].kind === TypeKind.Null) {
				return createMaybeType(members[0]);
			}
			if (members[0] !== null && members[0].kind === TypeKind.Null && isInterfaceType(members[1])) {
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

	// Object literal type: { field: Type, ... }
	if (charAt(trimmed, 0) === "{" && trimmed.endsWith("}")) {
		const inner = trimStr(sliceStr(trimmed, 1, trimmed.length - 1));
		if (inner === "") return createStruct("", [], [], true);
		const fields = splitTopLevel(inner, ",");
		const names: string[] = [];
		const types: Type[] = [];
		let fi = 0;
		while (fi < fields.length) {
			const field = trimStr(fields[fi]);
			if (field !== "") {
				const colonIdx = findChar(field, ":");
				if (colonIdx > 0) {
					const fname = trimStr(sliceStr(field, 0, colonIdx));
					const ftypeStr = trimStr(sliceStr(field, colonIdx + 1, field.length));
					names.push(fname);
					types.push(resolveAnnotation(ftypeStr, ctx));
				}
			}
			fi = fi + 1;
		}
		return createStruct("", names, types, true);
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
			const size = parseIntStr(sizeStr);
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
		if (baseName === "Borrow" && args.length === 1) {
			return createBorrow(resolveAnnotation(args[0], ctx));
		}
		if (baseName === "Ptr" && args.length === 1) {
			return createPtr(resolveAnnotation(args[0], ctx));
		}
		if (baseName === "Ref" && args.length === 1) {
			return createRef(resolveAnnotation(args[0], ctx));
		}
		if (baseName === "Var" && args.length === 1) {
			return createVar(resolveAnnotation(args[0], ctx));
		}
		if (baseName === "Map" && args.length === 2) {
			const keyType = resolveAnnotation(args[0], ctx);
			const valType = resolveAnnotation(args[1], ctx);
			if (keyType.kind !== TypeKind.String && keyType.kind !== TypeKind.Number && keyType.kind !== TypeKind.Unknown) {
				addError(ctx, "Only string or number keys are supported for Map in the C backend. Got: " + typeNameOf(keyType), 0, 0);
			}
			return createMap(keyType, valType);
		}
		if (baseName === "Set" && args.length === 1) {
			const elemType = resolveAnnotation(args[0], ctx);
			if (elemType.kind !== TypeKind.String && elemType.kind !== TypeKind.Number && elemType.kind !== TypeKind.Unknown) {
				addError(ctx, "Only string or number elements are supported for Set in the C backend. Got: " + typeNameOf(elemType), 0, 0);
			}
			return createSet(elemType);
		}
		if (baseName === "Record" && args.length === 2) {
			const keyType = resolveAnnotation(args[0], ctx);
			const valType = resolveAnnotation(args[1], ctx);
			if (keyType.kind !== TypeKind.String && keyType.kind !== TypeKind.Number && keyType.kind !== TypeKind.Unknown) {
				addError(ctx, "Only string or number keys are supported for Map in the C backend. Got: " + typeNameOf(keyType), 0, 0);
			}
			return createMap(keyType, valType);
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
			createTypeRef(trimmed);
		},
	};
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
export function buildTypeArgKey(args: string[], ctx: CheckerContext): string {
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

	const paramTypes = resolveTypeStrings(d.fnParamTypes, d.params.length, ctx);

	// Wrap out param types in TypeKind.Var (reference parity: tyVar)
	if (d.fnFlags !== "" && d.fnFlags.indexOf("out:") >= 0) {
		const flagParts = splitTopLevel(d.fnFlags, "|");
		for (const fp of flagParts) {
			const trimFp = trimStr(fp);
			if (trimFp.length > 4 && sliceStr(trimFp, 0, 4) === "out:") {
				const idxStr = sliceStr(trimFp, 4, trimFp.length);
				const idxParts = splitTopLevel(idxStr, ",");
				for (const ip of idxParts) {
					const idx = parseIntStr(trimStr(ip));
					if (idx >= 0 && idx < paramTypes.length) {
						paramTypes[idx] = createVar(paramTypes[idx]);
					}
				}
			}
		}
	}

	const returnType = (d.fnReturnType !== "") ? resolveAnnotation(d.fnReturnType, ctx) : unknownType();
	const fnType = createFunction(paramTypes, d.params, returnType);

	// Set minArity for functions with default parameters
	let defCount = 0;
	if (d.fnDefaults !== null) {
		let di = 0;
		while (di < d.fnDefaults.length) {
			if (d.fnDefaults[di] !== "") defCount = defCount + 1;
			di = di + 1;
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
					overload.defaultParamText = d.fnDefaults;
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
		sym.defaultParamText = d.fnDefaults;
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

	// reference parity: self-referential value fields → auto-promote to Ref<T>
	// C cannot embed struct T by value inside itself (infinite size).
	// Standard reference requires explicit pointer types and errors otherwise. We auto-promote with a warning.
	let fi = 0;
	while (fi < fieldTypes.length) {
		const ft = fieldTypes[fi];
		if (ft !== null && isInterfaceType(ft) && ft.typeName === d.interfaceName) {
			fieldTypes[fi] = createRef(ft);
			const fieldName = fi < d.interfaceFields.length ? d.interfaceFields[fi] : "?";
			addError(ctx, "warning: self-referential field '" + fieldName + "' in '" + d.interfaceName + "' auto-promoted to Ref<" + d.interfaceName + ">", node.location.line, 0);
		}
		fi += 1;
	}

	const ifaceType = createStruct(d.interfaceName, d.interfaceFields, fieldTypes, true);
	assignType(sym.symbolType, ifaceType);
	node.nodeType = sym.symbolType;
}

function resolveTypeAlias(ctx: CheckerContext, node: Node): void {
	const d = node.data as TypeAliasDeclData;
	const sym = lookupSymbol(ctx.table, d.aliasName);
	if (sym === null) return;
	node.resolvedSym = sym;

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

	const resolved = resolveAnnotation(d.aliasType, ctx);
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
	const discType = resolveAnnotation(d.discriminantType, ctx);
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
		const resolved = resolveAnnotation(vt, ctx);
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
			const paramTypes = resolveTypeStrings(md.methodParamTypes, md.methodParams.length, ctx);
			const returnType = (md.methodReturnType !== "") ? resolveAnnotation(md.methodReturnType, ctx) : unknownType();
			if (hasMethodGenerics) {
				closeScope(ctx.table);
			}
			const fnType = createFunction(paramTypes, md.methodParams, returnType);
			// Use resolvedSym set by collectClassMethod — avoids overload ambiguity with lookupSymbol
			const methodSym = d.classBody[mi].resolvedSym;
			if (methodSym !== null && methodSym.symbolType.typeName !== "") {
				fnType.typeName = methodSym.symbolType.typeName;
			}
			member.nodeType = fnType;
			// Update the method symbol's type with resolved params/return
			if (methodSym !== null) {
				assignType(methodSym.symbolType, fnType);
			}
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
			// Resolve constructor type but don't add to struct (data-only, like methods)
			const cd = member.data as ConstructorDeclData;
			const paramTypes = resolveTypeStrings(cd.ctorParamTypes, cd.ctorParams.length, ctx);
			const ctorType = createFunction(paramTypes, cd.ctorParams, voidType());
			member.nodeType = ctorType;
		}
	}

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	const classType = createStruct(d.className, memberNames, memberTypes, true);
	// Preserve typeExtra (base class info set by collectPass)
	// sym.symbolType is Ref(Object) from collectPass — update the inner Object, not the Ref
	const inner = unwrapRef(sym.symbolType);
	if (inner.typeExtra !== null) {
		classType.typeExtra = inner.typeExtra;
	}
	assignType(inner, classType);
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
	return resolveAnnotation(text, ctx);
}

test "number" { assert resolveWith("number").kind === TypeKind.Number; }

test "string" { assert resolveWith("string").kind === TypeKind.String; }

test "boolean" { assert resolveWith("boolean").kind === TypeKind.Boolean; }

test "void" { assert resolveWith("void").kind === TypeKind.Void; }

test "null" { assert resolveWith("null").kind === TypeKind.Null; }

test "never" { assert resolveWith("never").kind === TypeKind.Never; }

test "int32" { assert resolveWith("int32").kind === TypeKind.Int32; }

test "float64" { assert resolveWith("float64").kind === TypeKind.Float64; }

test "unknown name" { assert resolveWith("Foo").kind === TypeKind.TypeReference; }

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
	assert t.kind === TypeKind.Result;
	assert t.typeReturn.kind === TypeKind.Number;
	assert t.typeExtra.kind === TypeKind.String;
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

test "Map<string, number>" {
	const t = resolveWith("Map<string, number>");
	assert t.kind === TypeKind.Map;
	assert t.typeReturn.kind === TypeKind.String;
	assert t.typeExtra.kind === TypeKind.Number;
}

test "Record<string, number> desugars to Map" {
	const t = resolveWith("Record<string, number>");
	assert t.kind === TypeKind.Map;
	assert t.typeReturn.kind === TypeKind.String;
	assert t.typeExtra.kind === TypeKind.Number;
}

test "Record<string, boolean> value type" {
	const t = resolveWith("Record<string, boolean>");
	assert t.kind === TypeKind.Map;
	assert t.typeExtra.kind === TypeKind.Boolean;
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
	const t = resolveAnnotation("MyType", ctx);
	assert t.kind === TypeKind.Struct;
	assert t.typeName === "MyType";
}

test "function gets Function type" {
	const ctx = createContext();
	const symStub = makeSymbol("foo", SymbolKind.Function, unknownType(), false);
	defineSymbol(ctx.table, symStub);
	// Simulate a FunctionDecl node
	const zl: SourceLocation = { line: 0, column: 0 };
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "foo", params: ["a", "b"], fnParamTypes: ["", ""], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "", fnDefaults: [] }, zl);
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
	const zl: SourceLocation = { line: 0, column: 0 };
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "add", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number", fnDefaults: [] }, zl);
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
	const zl: SourceLocation = { line: 0, column: 0 };
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "floor", params: ["x"], fnParamTypes: ["number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number", fnDefaults: [] }, zl);
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
	// Simulate parser registering interface Box<T> { value: T; }
	addGenericDecl("Box", "T");
	updateGenericDeclFields("Box", "value", "T");
	// Resolve Box<number> — should record instantiation
	const ctx = createContext();
	const t = resolveAnnotation("Box<number>", ctx);
	assert t.kind === TypeKind.TypeReference;
	assert t.typeName === "Box__number";
	// Check instantiation was recorded
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
	const t = resolveAnnotation("Pair<string, number>", ctx);
	assert t.kind === TypeKind.TypeReference;
	assert t.typeName === "Pair__string,number";
	const idx = findGenericTypeInstIdx("Pair", "string,number");
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
	resolveAnnotation("Box<number>", ctx);
	resolveAnnotation("Box<number>", ctx);
	assert getGenericTypeInstCount() === 1;
}

test "non-generic base falls through" {
	resetGenericDeclStore();
	resetGenericTypeInsts();
	// No addGenericDecl for "Foo" — should fall through to symbol lookup
	const ctx = createContext();
	defineSymbol(ctx.table, makeSymbol("Foo", SymbolKind.Interface, createStruct("Foo", [], [], true), false));
	const t = resolveAnnotation("Foo<number>", ctx);
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
	const t = resolveAnnotation("Container<string>", ctx);
	assert t.kind === TypeKind.TypeReference;
	assert t.typeName === "Container__string";
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
	const t = resolveAnnotation("Box<number>", ctx);
	assert t.kind === TypeKind.TypeReference;
	assert t.typeName === "Box__number";
}

test "fnDefaults on FunctionDeclData" {
	const zl: SourceLocation = { line: 0, column: 0 };
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "defTest", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "", fnDefaults: ["", "42"] }, zl);
	const d = fnNode.data as FunctionDeclData;
	assert d.fnDefaults.length === 2;
	assert d.fnDefaults[0] === "";
	assert d.fnDefaults[1] === "42";
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
