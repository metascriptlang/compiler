// Pass 2: Resolve - parse type annotations, enrich collected symbols
//
// The parser currently stores type annotations as strings (TypeAnnotation nodes)
// and skips them in most places. Function params are string[] (names only).
// This pass enriches the symbol table by:
//   A. Parsing type annotation strings into Type objects
//   B. Building proper Function/Object types for collected declarations

import { Node, NodeKind, createNodeAt, makeLoc, ProgramData, FunctionDeclData, InterfaceDeclData, ExportDeclData, ClassDeclData, ActorDeclData, MethodDeclData, PropertyDeclData, ConstructorDeclData, TypeAliasDeclData, VariableDeclData, DecoratedDeclData, ExternDeclData, IdentifierData, MemberExprData, TypeGenericData, TypeArrayData, TypeUnionData, TypeFunctionData, TypeObjectData, ObjectLiteralData, TypeAssertionData, DeclKind, Type, TypeKind, TypeFlag, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { unknownType, getSysType, numberType, stringType, booleanType, voidType, nullType, neverType, charType, cstringType, createPrimitive, createStringLiteral, createBooleanLiteral, createEnumLiteral, createArray, createFunction, createClosureType, createStruct, createResult, createPromise, createIterator, createUnion, createGenericParam, createDistinct, createGenericInstance, instantiateGenericBody, isResult, getResultOkType, getResultErrType, createSizedArray, createSpan, createBorrow, createPtr, createRef, createVar, createMaybeType, setMinArity, assignType, isStructType, unwrapRef, propagateToOwner, createConditionalType, evaluateConditionalType, typeDisplayName, emptyType, createTuple, findSharedBooleanDiscriminant, findSharedStringDiscriminant } from "./types";
import { ScopeKind, lookupSymbol, defineSymbol, makeSymbol, openScope, closeScope, markUsed } from "./symbol";
import { CheckerContext, findExtension, getExtTypeName, extractGenericNames, addError, addWarning, sgRecordSym } from "./context";
import { findChar, splitTopLevel, parseIntStr, bareAfterDelim } from "../utils/string";
import { getGenericDecl, getGenericDeclFieldNames, getGenericDeclFieldTypes, addGenericTypeInst, findGenericTypeInstIdx } from "../parser/context";
import { getDeclName } from "./collectPass";
import { isAssignable as isAssignableCheck } from "./compat";

// ===== A. Resolve Annotation Strings =====

// Tier 3: find a keyword string at top level (not inside brackets/parens/braces/angles).
function findTopLevelKeyword(text: string, keyword: string): number {
	let depth = 0;
	for (let i = 0; i <= text.length - keyword.length; i += 1) {
		const c = text.charAt(i);
		if (c === "(" || c === "[" || c === "{" || c === "<") depth += 1;
		if (c === ")" || c === "]" || c === "}" || c === ">") depth -= 1;
		if (depth === 0 && text.slice(i, i + keyword.length) === keyword) return i;
	}
	return -1;
}

// Tier 3: find a single character at top level (not inside brackets/parens/braces/angles).
function findTopLevelChar(text: string, ch: string): number {
	let depth = 0;
	for (let i = 0; i < text.length; i += 1) {
		const c = text.charAt(i);
		if (c === "(" || c === "[" || c === "{" || c === "<") depth += 1;
		if (c === ")" || c === "]" || c === "}" || c === ">") depth -= 1;
		if (depth === 0 && c === ch) return i;
	}
	return -1;
}

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
	let trimmed = text.trim();
	if (trimmed === "") return unknownType();
	// Strip outer parens that wrap the entire expression (not function type form `(...) => ...`).
	// `(T | null)`, `(A & B)`, etc. — needed when `(...)` surrounds the type before an array
	// suffix `[]` strips down to the parenthesised form. Without this, splitTopLevel("|") sees
	// `|` inside parens (depth > 0) and skips union detection.
	while (trimmed.length >= 2 && trimmed.charAt(0) === "(" && trimmed.charAt(trimmed.length - 1) === ")") {
		// Verify the outer parens match (depth returns to 0 only at the final char) AND that
		// this isn't a function type form `(params) => ret` (those reach the `=>` branch below).
		let depth = 0;
		let closesAtEnd = true;
		let isFnForm = false;
		for (let i = 0; i < trimmed.length; i += 1) {
			const c = trimmed.charAt(i);
			if (c === "(") depth = depth + 1;
			if (c === ")") {
				depth = depth - 1;
				if (depth === 0 && i < trimmed.length - 1) {
					closesAtEnd = false;
					const after = trimmed.slice(i + 1, trimmed.length).trim();
					if (after.length >= 2 && after.charAt(0) === "=" && after.charAt(1) === ">") isFnForm = true;
					break;
				}
			}
		}
		if (!closesAtEnd || isFnForm) break;
		trimmed = trimmed.slice(1, trimmed.length - 1).trim();
	}

	// Tier 3: infer X — produce a GenericParam placeholder for conditional type unification
	if (trimmed.length > 6 && trimmed.slice(0, 6) === "infer ") {
		const inferName = trimmed.slice(6, trimmed.length).trim();
		if (inferName !== "") return createGenericParam(inferName);
	}

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

	// Tier 3: Conditional type: T extends U ? A : B
	// Detect " extends " at top level (not inside brackets/parens).
	const extendsIdx = findTopLevelKeyword(trimmed, " extends ");
	if (extendsIdx >= 0) {
		const checkPart = trimmed.slice(0, extendsIdx).trim();
		const afterExtends = trimmed.slice(extendsIdx + 9, trimmed.length).trim();
		// Find top-level '?' in the remainder
		const qIdx = findTopLevelChar(afterExtends, "?");
		if (qIdx >= 0) {
			const constraintPart = afterExtends.slice(0, qIdx).trim();
			const afterQ = afterExtends.slice(qIdx + 1, afterExtends.length).trim();
			// Find top-level ':' in the remainder (after '?')
			const colonIdx = findTopLevelChar(afterQ, ":");
			if (colonIdx >= 0) {
				const truePart = afterQ.slice(0, colonIdx).trim();
				const falsePart = afterQ.slice(colonIdx + 1, afterQ.length).trim();
				const checkType = resolveAnnotation(checkPart, ctx, line, col);
				const extendsType = resolveAnnotation(constraintPart, ctx, line, col);
				const trueType = resolveAnnotation(truePart, ctx, line, col);
				const falseType = resolveAnnotation(falsePart, ctx, line, col);
				const cond = createConditionalType(checkType, extendsType, trueType, falseType);
				return evaluateConditionalType(cond);
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
		// T | null where T is value-type struct → Maybe<T> (struct has no null sentinel,
		// so it needs a wrapper). Ref<T> | null and Ptr<T> | null stay as Union — codegen
		// collapses them to bare pointer at emit time (the null pointer IS the sentinel),
		// while the type checker keeps the union so flow narrowing can distinguish
		// `Foo` from `Foo | null`.
		if (members.length === 2) {
			if (isStructType(members[0]) && members[1] !== null && members[1].kind === TypeKind.Null) {
				return createMaybeType(members[0]);
			}
			if (members[0] !== null && members[0].kind === TypeKind.Null && isStructType(members[1])) {
				return createMaybeType(members[1]);
			}
		}
		if (members.length > 0) return createUnion(members);
	}

	// String literal type: "north" → StringLiteral("north") (TypeScript parity)
	if (trimmed.length >= 2 && trimmed.charAt(0) === "\"" && trimmed.charAt(trimmed.length - 1) === "\"") {
		return createStringLiteral(trimmed.slice(1, trimmed.length - 1));
	}

	// Boolean literal type: `true` / `false` → BooleanLiteral (TypeScript parity)
	// Required for discriminated union narrowing on boolean discriminants
	// (e.g. `type Result<T,E> = { ok: true, value: T } | { ok: false, error: E }`).
	if (trimmed === "true") return createBooleanLiteral(true);
	if (trimmed === "false") return createBooleanLiteral(false);

	// Object literal type: { field: Type; ... } or { field: Type, ... }
	// Also handles index signature: { [key: K]: V } → normalized to Map<K, V>.
	// Ordered `Map` is the target (not HashMap) because JS object literals preserve
	// insertion order — the semantic match for `{ [key: K]: V }` sugar.
	if (trimmed.charAt(0) === "{" && trimmed.endsWith("}")) {
		const inner = trimmed.slice(1, trimmed.length - 1).trim();
		if (inner === "") return createStruct("", [], [], true);

		// Index signature: { [name: K]: V } is syntactic sugar for Map<K, V> (ordered).
		// After normalization, both syntaxes produce identical Type structs.
		// See docs/PACKAGE.md and the index signature impl plan.
		if (inner.charAt(0) === "[") {
			// Find the BALANCED closing `]` — the key type may contain its own
			// brackets (e.g. `{ [key: number[]]: V }`), so a naive findChar("]")
			// would stop at the wrong bracket.
			let bracketDepth = 0;
			let closeBracket = -1;
			let bi = 0;
			while (bi < inner.length) {
				const c = inner.charAt(bi);
				if (c === "[") { bracketDepth = bracketDepth + 1; }
				else if (c === "]") {
					bracketDepth = bracketDepth - 1;
					if (bracketDepth === 0) { closeBracket = bi; bi = inner.length; }
				}
				bi = bi + 1;
			}
			if (closeBracket > 0) {
				// Find the FIRST colon (inside [...], between name and key type)
				const nameColon = findChar(inner, ":");
				if (nameColon > 0 && nameColon < closeBracket) {
					const keyType = inner.slice(nameColon + 1, closeBracket).trim();
					// Everything after `]` should be `: V` (with optional trailing ;)
					let afterBracket = inner.slice(closeBracket + 1, inner.length).trim();
					// Strip trailing semicolon(s)
					while (afterBracket.length > 0 && afterBracket.charAt(afterBracket.length - 1) === ";") {
						afterBracket = afterBracket.slice(0, afterBracket.length - 1).trim();
					}
					if (afterBracket.length > 0 && afterBracket.charAt(0) === ":") {
						const valueType = afterBracket.slice(1, afterBracket.length).trim();
						if (keyType !== "" && valueType !== "") {
							// Rewrite to Map<K, V> (ordered) and recurse — reuses all generic resolution.
							const mapAnnotation = "Map<" + keyType + ", " + valueType + ">";
							return resolveAnnotation(mapAnnotation, ctx, line, col);
						}
					}
				}
			}
		}

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

	// Tuple type: [T, U, ...] — bracket at start AND end, distinct from `T[]` array suffix.
	// This is checked BEFORE array suffixes because those forms have a base type before the `[`.
	if (trimmed.charAt(0) === "[" && trimmed.endsWith("]")) {
		const tupleInner = trimmed.slice(1, trimmed.length - 1).trim();
		if (tupleInner !== "") {
			const elements = splitTopLevel(tupleInner, ",");
			// Single element with no comma is ambiguous with `[N]` size, but standalone
			// `[N]` isn't valid TS — we treat it as a 1-element tuple. `[T]` works.
			const tupleTypes: Type[] = [];
			for (const e of elements) {
				const t = e.trim();
				if (t !== "") tupleTypes.push(resolveAnnotation(t, ctx, line, col));
			}
			if (tupleTypes.length > 0) return createTuple(tupleTypes);
		}
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
		if (baseName === "Iterator" && args.length === 1) {
			return createIterator(resolveAnnotation(args[0], ctx, line, col));
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
			// e.g. inside set<K,V>(this m: HashMap<K,V>), HashMap<K,V> stays generic.
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
					markUsed(baseSym);
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
			// Concrete instantiation: record for codegen + produce concrete type.
			// Reference parity (handleGenericInvocation):
			// both type annotations and `new` expressions go through the same
			// instantiation path, producing the same concrete type.
			recordGenericTypeInstantiation(baseName, genericParams, args, ctx);
			// Build GenericInstance with structural type args
			const baseSym2 = lookupSymbol(ctx.table, baseName);
			if (baseSym2 !== null) {
				markUsed(baseSym2);
				ensureShaped(baseSym2, ctx);
				const isRefBase2 = baseSym2.symbolType.kind === TypeKind.Ref;
				let baseType2 = baseSym2.symbolType;
				if (isRefBase2 && baseType2.typeReturn !== null) baseType2 = baseType2.typeReturn;
				const resolvedArgs: Type[] = [];
				for (const a of args) {
					resolvedArgs.push(resolveAnnotation(a.trim(), ctx, line, col));
				}
				// Gap 5: validate generic constraints at instantiation.
				// genericParams = "T:Comparable,U" — params with optional :Constraint suffix.
				const paramList = splitTopLevel(genericParams, ",");
				for (let ci = 0; ci < paramList.length; ci += 1) {
					if (ci >= resolvedArgs.length) break;
					const paramStr = paramList[ci].trim();
					const colonPos = findChar(paramStr, ":");
					if (colonPos > 0) {
						const constraintName = paramStr.slice(colonPos + 1, paramStr.length).trim();
						const constraintType = resolveAnnotation(constraintName, ctx, line, col);
						if (constraintType.kind !== TypeKind.Unknown
								&& resolvedArgs[ci].kind !== TypeKind.Unknown
								&& resolvedArgs[ci].kind !== TypeKind.GenericParam
								&& !isAssignableCheck(resolvedArgs[ci], constraintType)) {
							const paramName = paramStr.slice(0, colonPos).trim();
							addError(ctx, `Type '${typeDisplayName(resolvedArgs[ci])}' does not satisfy constraint '${constraintName}' for type parameter '${paramName}' in '${baseName}'`, line, col);
						}
					}
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
			markUsed(baseSym);
			// Demand-driven resolution: ensure the base symbol is shaped before using its type
			ensureShaped(baseSym, ctx);
			return baseSym.symbolType;
		}
		return emitUnresolvedTypeRef(ctx, baseName, line, col, "");
	}

	// Enum literal type: K.A — qualified name referring to a specific enum member.
	// Split on the LAST `.` so nested module paths resolve correctly.
	// Skip if the annotation contains compound-type tokens — those shapes are handled
	// by earlier branches (generics, arrays, objects, function types).
	const hasCompoundToken = trimmed.indexOf("(") >= 0
		|| trimmed.indexOf("<") >= 0
		|| trimmed.indexOf("[") >= 0
		|| trimmed.indexOf("{") >= 0;
	if (!hasCompoundToken && trimmed.indexOf(".") >= 0) {
		let lastDot = -1;
		for (let i = 0; i < trimmed.length; i += 1) {
			if (trimmed.charAt(i) === ".") lastDot = i;
		}
		if (lastDot > 0 && lastDot < trimmed.length - 1) {
			const enumName = trimmed.slice(0, lastDot).trim();
			const memberName = trimmed.slice(lastDot + 1, trimmed.length).trim();
			if (enumName !== "" && memberName !== "") {
				const enumSym = lookupSymbol(ctx.table, enumName);
				if (enumSym !== null && enumSym.symbolType !== null && enumSym.symbolType.kind === TypeKind.Enum) {
					markUsed(enumSym);
					ensureShaped(enumSym, ctx);
					const enumType = enumSym.symbolType;
					// Verify member exists
					let found = false;
					for (const m of enumType.typeNames) {
						if (m === memberName) { found = true; break; }
					}
					if (found) return createEnumLiteral(enumType, memberName);
					if (line > 0) {
						addWarning(ctx, `Enum '${enumName}' has no member '${memberName}'`, line, col);
					}
					return unknownType();
				}
			}
		}
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
				markUsed(sym);
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
			// Index signature (for LSP symbol recording): walk key and value types too
			if (d.typExprIndexKey !== null) { resolveTypeExpr(d.typExprIndexKey, ctx); }
			if (d.typExprIndexValue !== null) { resolveTypeExpr(d.typExprIndexValue, ctx); }
		},
		NodeKind.MemberExpr => {
			// Tier 1: enum literal type position — `K.A` produces a MemberExpr.
			// Walk the object (the enum name) and record the member position so LSP
			// can offer hover/goto-def for both the enum and its specific member.
			const md = node.data as MemberExprData;
			resolveTypeExpr(md.object, ctx);
			if (md.object !== null && md.object.kind === NodeKind.Identifier) {
				const enumName = (md.object.data as IdentifierData).name;
				const enumSym = lookupSymbol(ctx.table, enumName);
				if (enumSym !== null && enumSym.symbolType !== null && enumSym.symbolType.kind === TypeKind.Enum) {
					// Record the member position. The dot is 1 column wide.
					const memberCol = md.object.location.column + enumName.length + 1;
					const memberSym = makeSymbol(md.property, SymbolKind.EnumMember, enumSym.symbolType, false);
					memberSym.modulePath = enumSym.modulePath;
					memberSym.location = enumSym.location;
					sgRecordSym(ctx, node.location.line, memberCol, memberCol + md.property.length,
						memberSym, enumSym.symbolType, SymbolKind.EnumMember, md.property, enumName, false);
				}
			}
		},
		// This function is ONLY called on nodes from the typeExpr side channel,
		// which by construction only contains type-expression shapes (Identifier +
		// TypeGeneric/Array/Union/Function/Object). Any other NodeKind here is a
		// no-op: there is nothing to record for LSP. When adding a NEW type-expr
		// kind (e.g. TypeIntersection), add it to the match ABOVE — the wildcard
		// will silently drop it otherwise.
		_ => {},
	};
}

// Resolve all TypeExpr nodes in a type annotation array (params, fields).
// Null-safe: skips null arrays and null entries.
export function resolveTypeExprs(exprs: (Node | null)[], ctx: CheckerContext): void {
	if (exprs === null) return;
	for (const te of exprs) {
		if (te === null) continue;
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
			NodeKind.ActorDecl => resolveActor(ctx, node),
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
export function defineGenericParam(ctx: CheckerContext, paramStr: string): void {
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

// findPredicateInfix — locate the ` is ` keyword in a function return
// annotation so we can split the parameter name from the predicate target
// type. Returns the index of the `i` of "is", or -1 if no top-level predicate
// exists. Only a leading `<ident> is ` pattern qualifies — we check that the
// prefix is an identifier-shaped token (no whitespace, no dots, no colons)
// so we never misread constructs like `Result< is Whatever >` (impossible but
// covered defensively).
function findPredicateInfix(text: string): int32 {
	// Accept only the canonical shape: `<ident> is <type>`.
	const idxSp = findChar(text, " ");
	if (idxSp <= 0) return -1;
	if (idxSp + 3 >= text.length) return -1;
	if (text.charAt(idxSp + 1) !== "i") return -1;
	if (text.charAt(idxSp + 2) !== "s") return -1;
	if (text.charAt(idxSp + 3) !== " ") return -1;
	// Prefix must be a bare identifier (letters/digits/underscore).
	let i: int32 = 0;
	while (i < idxSp) {
		const c = text.charAt(i);
		const isLetter = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
		const isDigit = c >= "0" && c <= "9";
		const isUnder = c === "_";
		if (!isLetter && !isDigit && !isUnder) return -1;
		i = i + 1;
	}
	return (idxSp + 1) as int32;
}

function resolveFunction(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	// Use resolvedSym set by collectPass (preserves overloadIdx for overloaded functions).
	let sym = node.resolvedSym;
	if (sym === null) {
		sym = lookupSymbol(ctx.table, d.fnName);
		if (sym === null) return;
		node.resolvedSym = sym;
	}

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
	// Type predicate detection: fnReturnType is `"<paramName> is <typeText>"`
	// (see captureOptionalType in parser/util.ms). Split once, resolve the
	// target type, set the function's actual return type to `boolean`, and
	// stash a sentinel on the function Type's `typeExtra` slot — flow.ms
	// narrowType reads this to narrow callers in conditions.
	let returnType: Type;
	let predicateSentinel: Type | null = null;
	if (d.fnReturnType !== "") {
		// Assertion function: `asserts paramName is Type` — strip `asserts `
		// prefix and handle as a predicate with void return type and a distinct
		// sentinel marker ("asserts:" prefix on typeName).
		let predSource = d.fnReturnType;
		let isAssertion = false;
		if (predSource.length > 8 && predSource.slice(0, 8) === "asserts ") {
			predSource = predSource.slice(8, predSource.length);
			isAssertion = true;
		}
		const predIdx = findPredicateInfix(predSource);
		if (predIdx > 0) {
			const paramName = predSource.slice(0, predIdx - 1).trim();
			const targetText = predSource.slice(predIdx + 3, predSource.length).trim();
			const targetType = resolveAnnotation(targetText, ctx, retLoc.line, retLoc.column);
			// Predicates return boolean; assertions return void (they throw on failure).
			returnType = isAssertion ? voidType() : booleanType();
			// Sentinel: kind=Unknown on Function.typeExtra. typeName holds the
			// parameter name (prefixed with "asserts:" for assertion functions).
			// typeReturn holds the narrowing target type.
			predicateSentinel = emptyType();
			predicateSentinel.kind = TypeKind.Unknown;
			predicateSentinel.typeName = isAssertion ? `asserts:${paramName}` : paramName;
			predicateSentinel.typeReturn = targetType;
		} else {
			returnType = resolveAnnotation(d.fnReturnType, ctx, retLoc.line, retLoc.column);
		}
	} else {
		returnType = unknownType();
	}
	// Record return type annotation positions for LSP
	resolveTypeExpr(node.typeExpr, ctx);
	const fnType = createFunction(paramTypes, d.params, returnType);
	if (predicateSentinel !== null) {
		fnType.typeExtra = predicateSentinel;
	}

	// Set minArity for functions with default parameters (Reference parity: count non-null defaults)
	let defCount = 0;
	if (d.fnDefaults !== null) {
		for (const def of d.fnDefaults) {
			if (def !== null) defCount = defCount + 1;
		}
	}
	// Rest param is optional (accepts 0+ args) — reduces min arity
	const hasRestParam = d.params.length > 0
		&& d.params[d.params.length - 1].length > 3
		&& d.params[d.params.length - 1].slice(0, 3) === "...";
	if (defCount > 0 || hasRestParam) {
		const restReduction = hasRestParam ? 1 : 0;
		setMinArity(fnType, d.params.length - defCount - restReduction);
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
						// Reference parity: sym is the single source of truth for the type.
						// Only set fnType as fallback when sym is not available.
						if (ext2.sym === null) {
							ext2.fnType = fnType;
							ext2.sym = overload;
						}
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
	// Reference parity: sym is the single source of truth for the type.
	// Only set fnType as fallback when sym is not available. Never store the same Type
	// in both fnType and sym.symbolType — that causes double-decref on ExtensionMethod destruction.
	const extTypeName = getExtTypeName(d.fnFlags);
	if (extTypeName !== "" && ctx.extensionRegistry !== null) {
		const ext = findExtension(ctx.extensionRegistry, extTypeName, d.fnName);
		if (ext !== null) {
			if (ext.sym === null) {
				ext.fnType = fnType;
				ext.sym = sym;
			}
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
	for (const pt of fieldTypes) { propagateToOwner(target, pt); }
	node.nodeType = sym.symbolType;
	// Record each interface field DEF for symbol graph.
	// Parser stores per-field source locations in node.paramLocations (repurposed field).
	// Falls back to node.location if paramLocations is missing (e.g., macro-generated nodes).
	for (let ri = 0; ri < d.interfaceFields.length; ri += 1) {
		const fieldSym = makeSymbol(d.interfaceFields[ri], SymbolKind.Property, fieldTypes[ri], false);
		fieldSym.state = SymbolState.Shaped;
		let fieldLine = node.location.line;
		let fieldCol = node.location.column;
		if (node.paramLocations !== null && ri < node.paramLocations.length) {
			const fl = node.paramLocations[ri];
			fieldLine = fl.line;
			fieldCol = fl.column;
		}
		sgRecordSym(ctx, fieldLine, fieldCol, fieldCol + d.interfaceFields[ri].length, fieldSym, fieldTypes[ri], SymbolKind.Property, d.interfaceFields[ri], d.interfaceName, true);
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
		// Tier 3: open generic param scope for `type MyData<T, E> = match (...) { ... }`
		// so variant field annotations (e.g. `value: T`) can resolve T as a GenericParam
		// instead of Unknown. Without this, instantiated generic match-types lose their
		// type parameters and field access returns Unknown.
		const hasGenericAliasDU = d.aliasGenericParams !== null && d.aliasGenericParams !== "";
		if (hasGenericAliasDU) {
			openScope(ctx.table, ScopeKind.Block);
			const paramList = splitTopLevel(d.aliasGenericParams, ",");
			for (const p of paramList) {
				defineGenericParam(ctx, p.trim());
			}
		}
		const resolved = resolveDiscriminatedUnion(ctx, d);
		if (hasGenericAliasDU) {
			closeScope(ctx.table);
		}
		if (resolved !== null) {
			assignType(sym.symbolType, resolved);
			node.nodeType = sym.symbolType;
		}
		return;
	}

	// Tier 3: generic type alias — define generic param symbols in a nested scope
	// so the body can reference them (e.g. type Box<T> = { value: T }).
	const hasGenericAlias = d.aliasGenericParams !== null && d.aliasGenericParams !== "";
	if (hasGenericAlias) {
		openScope(ctx.table, ScopeKind.Block);
		const paramList = splitTopLevel(d.aliasGenericParams, ",");
		for (const p of paramList) {
			defineGenericParam(ctx, p.trim());
		}
	}

	const resolved = resolveAnnotation(d.aliasType, ctx, node.location.line, node.location.column);
	resolveTypeExpr(node.typeExpr, ctx);

	if (hasGenericAlias) {
		closeScope(ctx.table);
	}

	// Propagate alias name to Union types (Reference gap: string-based annotations don't carry names)
	if (resolved.kind === TypeKind.Union && resolved.typeName === "") {
		resolved.typeName = d.aliasName;
	}
	// Tier 3: for generic aliases, stamp the typeName so instantiation can reference the alias
	if (hasGenericAlias && resolved.typeName === "") {
		resolved.typeName = d.aliasName;
	}
	// TypeScript-parity auto-detection of boolean-discriminator DUs:
	// `type R = { ok: true, ... } | { ok: false, ... }`. Stamp the discriminator
	// metadata so codegen and narrowing treat it as discriminated. String-literal
	// DUs (`{ kind: "circle" } | { kind: "square" }`) are handled by the existing
	// `findSharedStringDiscriminant` path used directly by checkExprPass — those
	// tests rely on the un-stamped Union shape, so don't auto-stamp them here.
	if (resolved.kind === TypeKind.Union
		&& (resolved.typeNames === null || resolved.typeNames.length === 0)
		&& resolved.typeExtra === null) {
		const boolDisc = findSharedBooleanDiscriminant(resolved);
		if (boolDisc !== "") {
			resolved.typeNames = [boolDisc];
			resolved.typeExtra = booleanType();
		}
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
function resolveDiscriminatedUnion(ctx: CheckerContext, d: TypeAliasDeclData): Type | null {
	// Resolve discriminant type — must be an enum or boolean.
	// Boolean disc is the natural fit for two-variant unions like
	// `type Result<T,E> = match (ok: boolean) { true => {...}, false => {...} }`.
	const discType = resolveAnnotation(d.discriminantType, ctx, 0, 0);
	const isBooleanDisc = discType.kind === TypeKind.Boolean;
	if (discType.kind !== TypeKind.Enum && !isBooleanDisc) {
		addError(ctx, "Discriminant type '" + d.discriminantType + "' must be an enum or boolean", 0, 0);
		return null;
	}

	if (isBooleanDisc) {
		// Boolean disc requires exactly the keys "true" and "false".
		for (const key of d.variantKeys) {
			if (key !== "true" && key !== "false") {
				addError(ctx, "Variant key '" + key + "' must be 'true' or 'false' for boolean discriminator", 0, 0);
			}
		}
	} else {
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
	}

	// Resolve each variant type.
	// - Enum disc: stamp variant with `<alias>.<key>` (dotted form). The dot
	//   serves dual purpose: error messages display `MyData.Ok`, and
	//   `variantStructCName` excludes dotted names from direct C use (falls
	//   back to synthetic `<Union>_v<N>` which matches the typedef emitted
	//   by `genUnionType`).
	// - Boolean disc: variants stay anonymous. Inject the disc field as
	//   `BooleanLiteral` so `r.ok` member access reads through overlapping
	//   variant memory (`v<N>.<disc>`).
	const variantTypes: Type[] = [];
	for (let vi = 0; vi < d.variantTypes.length; vi += 1) {
		const resolved = resolveAnnotation(d.variantTypes[vi], ctx, 0, 0);
		if (resolved !== null && resolved.kind === TypeKind.Struct && vi < d.variantKeys.length) {
			if (isBooleanDisc) {
				const discValue = d.variantKeys[vi] === "true";
				const discFieldType = createBooleanLiteral(discValue);
				const newNames: string[] = [d.discriminantName];
				for (const n of resolved.typeNames) newNames.push(n);
				const newChildren: Type[] = [discFieldType];
				for (const c of resolved.typeChildren) newChildren.push(c);
				resolved.typeNames = newNames;
				resolved.typeChildren = newChildren;
			} else {
				const bareKey = bareAfterDelim(d.variantKeys[vi], ".");
				resolved.typeName = d.aliasName + "." + bareKey;
			}
		}
		variantTypes.push(resolved);
	}

	// Build Union type with discriminant metadata.
	// typeExtra = discriminant type (Enum or Boolean primitive)
	// typeNames = [discFieldName, key0, key1, ...]
	const unionType = createUnion(variantTypes);
	unionType.typeName = d.aliasName;
	unionType.typeExtra = isBooleanDisc ? booleanType() : discType;
	const names: string[] = [d.discriminantName];
	for (const key of d.variantKeys) {
		names.push(key);
	}
	unionType.typeNames = names;
	return unionType;
}

function resolveVariable(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	if (d.declType !== "") return;
	// No annotation: for const object literals, infer struct type from field names.
	// This gives cross-module exports a meaningful type (not unknown) for LSP hover/completion.
	// Full inference happens in Pass 3; this is a lightweight early approximation.
	if (d.declKind === DeclKind.Const && d.initializer !== null && d.initializer.kind === NodeKind.ObjectLiteral) {
		const sym = lookupSymbol(ctx.table, d.declName);
		if (sym !== null && sym.symbolType.kind === TypeKind.Unknown) {
			const objData = d.initializer.data as ObjectLiteralData;
			const fieldNames: string[] = [];
			const fieldTypes: Type[] = [];
			for (let fi = 0; fi < objData.keys.length; fi += 1) {
				fieldNames.push(objData.keys[fi]);
				// Values are literals — resolve their types if annotated (e.g., 0x0001 as uint32)
				const valNode = objData.properties[fi];
				if (valNode !== null && valNode.kind === NodeKind.TypeAssertion) {
					const ta = valNode.data as TypeAssertionData;
					const resolved = resolveAnnotation(ta.asType, ctx, node.location.line, node.location.column);
					fieldTypes.push(resolved);
				} else {
					fieldTypes.push(unknownType());
				}
			}
			sym.symbolType = createStruct("", fieldNames, fieldTypes, true);
		}
	}
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

function resolveConstructorType(member: Node, sym: Symbol, ctx: CheckerContext): void {
	const cd = member.data as ConstructorDeclData;
	const paramTypes = resolveTypeStrings(cd.ctorParamTypes, cd.ctorParams.length, ctx, member.location.line, member.location.column);
	resolveTypeExprs(member.typeExprs, ctx);
	member.nodeType = createFunction(paramTypes, cd.ctorParams, voidType());
	if (cd.ctorDefaults !== null && cd.ctorDefaults.length > 0) {
		sym.defaultParams = cd.ctorDefaults;
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
			if (pd.propIsStatic) {
				// Resolve static property type and update the staticFields symbol
				let staticType = unknownType();
				if (pd.propType !== "") {
					staticType = resolveAnnotation(pd.propType, ctx, member.location.line, member.location.column);
					resolveTypeExpr(member.typeExpr, ctx);
				}
				member.nodeType = staticType;
				// Find matching staticFields entry and set its type
				for (const sf of sym.staticFields) {
					if (sf.name === d.className + "." + pd.propName) {
						sf.symbolType = staticType;
						sf.state = SymbolState.Shaped;
					}
				}
			} else {
				memberNames.push(pd.propName);
				if (pd.propType !== "") {
					const propType = resolveAnnotation(pd.propType, ctx, member.location.line, member.location.column);
					resolveTypeExpr(member.typeExpr, ctx);
					member.nodeType = propType;
					memberTypes.push(propType);
				} else {
					memberTypes.push(unknownType());
				}
			}
		} else if (member.kind === NodeKind.ConstructorDecl) {
			resolveConstructorType(member, sym, ctx);
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
	for (const pt of memberTypes) { propagateToOwner(inner, pt); }
	node.nodeType = sym.symbolType;
}

function resolveActor(ctx: CheckerContext, node: Node): void {
	const d = node.data as ActorDeclData;
	const sym = lookupSymbol(ctx.table, d.actorName);
	if (sym === null) return;
	node.resolvedSym = sym;
	sym.state = SymbolState.Shaped;

	// Check for generic params
	const genericStr = getGenericDecl(d.actorName);
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

	// Build struct type — collect instance properties and resolve methods
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (let mi = 0; mi < d.actorBody.length; mi += 1) {
		let member = d.actorBody[mi];
		if (member.kind === NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			if (dd.decoratedNode === null) continue;
			member = dd.decoratedNode;
		}
		if (member.kind === NodeKind.MethodDecl) {
			const md = member.data as MethodDeclData;
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
			const methodSym = member.resolvedSym !== null ? member.resolvedSym : d.actorBody[mi].resolvedSym;
			if (methodSym !== null && methodSym.symbolType !== null && methodSym.symbolType.typeName !== "") {
				fnType.typeName = methodSym.symbolType.typeName;
			}
			member.nodeType = fnType;
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
			resolveConstructorType(member, sym, ctx);
		}
	}

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	// pid field: the actor's runtime identity (int64 — pointer cast to integer)
	memberNames.push("pid");
	memberTypes.push(getSysType(TypeKind.Int64));

	// Update inner struct in-place
	const inner = unwrapRef(sym.symbolType);
	inner.kind = TypeKind.Struct;
	inner.typeName = d.actorName;
	inner.typeNames = memberNames;
	inner.typeChildren = memberTypes;
	inner.typeFlags = TypeFlag.IsStruct as int32;
	for (const pt of memberTypes) { propagateToOwner(inner, pt); }
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
	assert t.typeReturn !== null && t.typeReturn.kind === TypeKind.Number;
}

test "string[]" {
	const t = resolveWith("string[]");
	assert t.kind === TypeKind.Array;
	assert t.typeReturn !== null && t.typeReturn.kind === TypeKind.String;
}

test "Result<number, string>" {
	const t = resolveWith("Result<number, string>");
	assert isResult(t);
	const ok = getResultOkType(t);
	assert ok !== null && ok.kind === TypeKind.Number;
	const err = getResultErrType(t);
	assert err !== null && err.kind === TypeKind.String;
}

test "Array<boolean>" {
	const t = resolveWith("Array<boolean>");
	assert t.kind === TypeKind.Array;
	assert t.typeReturn !== null && t.typeReturn.kind === TypeKind.Boolean;
}

test "number[4]" {
	const t = resolveWith("number[4]");
	assert t.kind === TypeKind.SizedArray;
	assert t.typeReturn !== null && t.typeReturn.kind === TypeKind.Number;
	assert t.typeFlags === 4;
}

test "Span<boolean>" {
	const t = resolveWith("Span<boolean>");
	assert t.kind === TypeKind.Span;
	assert t.typeReturn !== null && t.typeReturn.kind === TypeKind.Boolean;
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
	const ret1 = sym.symbolType.typeReturn;
	assert ret1 !== null && ret1.kind === TypeKind.Number;
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
	const ret = sym.symbolType.typeReturn;
	assert ret !== null && ret.kind === TypeKind.Number;
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
	const ext = sym.symbolType.typeExtra;
	assert ext !== null && ext.kind === TypeKind.Number;
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
	const defNode = createNodeAt(NodeKind.NumberLiteral, { value: 42, isFloat: false }, zl);
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "defTest", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "", fnDefaults: [null, defNode], nameLocation: zl }, zl);
	const d = fnNode.data as FunctionDeclData;
	assert d.fnDefaults.length === 2;
	assert d.fnDefaults[0] === null;
	assert d.fnDefaults[1] !== null;
	assert d.fnDefaults[1].kind === NodeKind.NumberLiteral;
}

// ===== Nullable Pointer Resolution Tests =====

test "Ref<number> | null stays Union(Ref, Null)" {
	const t = resolveWith("Ref<number> | null");
	assert t.kind === TypeKind.Union;
	assert t.typeChildren.length === 2;
	assert t.typeChildren[0].kind === TypeKind.Ref;
	const inner0 = t.typeChildren[0].typeReturn;
	assert inner0 !== null && inner0.kind === TypeKind.Number;
	assert t.typeChildren[1].kind === TypeKind.Null;
}

test "null | Ref<string> stays Union(Null, Ref)" {
	const t = resolveWith("null | Ref<string>");
	assert t.kind === TypeKind.Union;
	assert t.typeChildren.length === 2;
	assert t.typeChildren[0].kind === TypeKind.Null;
	assert t.typeChildren[1].kind === TypeKind.Ref;
	const inner1 = t.typeChildren[1].typeReturn;
	assert inner1 !== null && inner1.kind === TypeKind.String;
}

test "Ptr<number> | null stays Union(Ptr, Null)" {
	const t = resolveWith("Ptr<number> | null");
	assert t.kind === TypeKind.Union;
	assert t.typeChildren.length === 2;
	assert t.typeChildren[0].kind === TypeKind.Ptr;
	const inner0 = t.typeChildren[0].typeReturn;
	assert inner0 !== null && inner0.kind === TypeKind.Number;
	assert t.typeChildren[1].kind === TypeKind.Null;
}

test "null | Ptr<boolean> stays Union(Null, Ptr)" {
	const t = resolveWith("null | Ptr<boolean>");
	assert t.kind === TypeKind.Union;
	assert t.typeChildren.length === 2;
	assert t.typeChildren[0].kind === TypeKind.Null;
	assert t.typeChildren[1].kind === TypeKind.Ptr;
	const inner1 = t.typeChildren[1].typeReturn;
	assert inner1 !== null && inner1.kind === TypeKind.Boolean;
}

test "string | null stays Union (not pointer)" {
	const t = resolveWith("string | null");
	assert t.kind === TypeKind.Union;
}

test "number | null stays Union (not pointer)" {
	const t = resolveWith("number | null");
	assert t.kind === TypeKind.Union;
}
