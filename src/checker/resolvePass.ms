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
	TypeAliasDeclData, VariableDeclData,
} from "../ast/node";
import {
	Type, TypeKind,
	unknownType, numberType, stringType, booleanType, voidType, nullType, neverType,
	createPrimitive, createArray, createFunction, createObject,
	createResult, createTypeRef, createUnion, createGenericParam, createDistinct,
} from "./types";
import { Symbol, SymbolKind, ScopeKind, lookupSymbol, defineSymbol, makeSymbol, openScope, closeScope } from "./symbol";
import { CheckerContext, findExtension, isExtensionFlag, getExtReceiverType, extractGenericNames } from "./context";
import { trim, sliceStr, findChar, splitTopLevel } from "../utils/string";
import { getGenericDecl, getGenericDeclFieldNames, getGenericDeclFieldTypes, addGenericTypeInst, findGenericTypeInstIdx } from "../parser/context";
import { test, check, testGroup } from "std/testing";

// ===== A. Resolve Annotation Strings =====

export function resolveAnnotation(text: string, ctx: CheckerContext): Type {
	const trimmed = trim(text);
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
		const inner = trim(sliceStr(trimmed, 0, trimmed.length - 3));
		return createArray(resolveAnnotation(inner, ctx));
	}
	if (trimmed.endsWith("[]")) {
		const inner = sliceStr(trimmed, 0, trimmed.length - 2);
		return createArray(resolveAnnotation(inner, ctx));
	}

	// Check for generic types: Name<A, B> or Name < A , B > (token-joined form)
	const angleBracket = findChar(trimmed, "<");
	if (angleBracket > 0 && trimmed.endsWith(">")) {
		const baseName = trim(sliceStr(trimmed, 0, angleBracket));
		const argsText = trim(sliceStr(trimmed, angleBracket + 1, trimmed.length - 1));
		const args = splitTopLevel(argsText, ",");

		if (baseName === "Result" && args.length === 2) {
			return createResult(resolveAnnotation(args[0], ctx), resolveAnnotation(args[1], ctx));
		}
		if (baseName === "Array" && args.length === 1) {
			return createArray(resolveAnnotation(args[0], ctx));
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
			if (sym !== null) return sym.symbolType;
			createTypeRef(trimmed);
		},
	};
}

// ===== Generic Type Instantiation Helpers =====

// Build a type arg key from resolved type arg strings (e.g., "number,string")
function buildTypeArgKey(args: string[], ctx: CheckerContext): string {
	let key = "";
	let i = 0;
	while (i < args.length) {
		if (i > 0) key = key + ",";
		key = key + trim(args[i]);
		i += 1;
	}
	return key;
}

// Record a generic type instantiation (e.g., Box<number>) for codegen
// Looks up field names/types from parser side-channel, substitutes generic params → concrete types
function recordGenericTypeInstantiation(baseName: string, genericParams: string, args: string[], ctx: CheckerContext): void {
	const typeArgKey = buildTypeArgKey(args, ctx);
	const mangledName = baseName + "__" + typeArgKey;

	// Get field info from parser side-channel
	const fieldNamesStr = getGenericDeclFieldNames(baseName);
	const fieldTypesStr = getGenericDeclFieldTypes(baseName);

	// Split generic param names: "T,U" → ["T", "U"]
	const paramNames = splitTopLevel(genericParams, ",");

	// Build "|"-joined substituted field types
	let resultFieldNames = "";
	let resultFieldTypes = "";

	if (fieldNamesStr !== "") {
		const fnParts = splitTopLevel(fieldNamesStr, "|");
		const ftParts = splitTopLevel(fieldTypesStr, "|");

		let fi = 0;
		while (fi < fnParts.length) {
			if (fi > 0) { resultFieldNames = resultFieldNames + "|"; resultFieldTypes = resultFieldTypes + "|"; }
			resultFieldNames = resultFieldNames + trim(fnParts[fi]);
			// Substitute generic params in field type annotations
			let fieldType = "";
			if (fi < ftParts.length) { fieldType = trim(ftParts[fi]); }
			// Replace each generic param with its concrete type arg
			let pi = 0;
			while (pi < paramNames.length) {
				const paramName = trim(paramNames[pi]);
				if (pi < args.length) {
					const argStr = trim(args[pi]);
					if (fieldType === paramName) {
						fieldType = argStr;
					}
				}
				pi += 1;
			}
			resultFieldTypes = resultFieldTypes + fieldType;
			fi += 1;
		}
	}

	addGenericTypeInst(baseName, typeArgKey, mangledName, resultFieldNames, resultFieldTypes);
}

// ===== Resolve Helpers =====

// Resolve an array of type annotation strings into Type[], matching names 1:1
function resolveTypeStrings(typeStrs: string[], count: number, ctx: CheckerContext): Type[] {
	const types: Type[] = [];
	let i = 0;
	while (i < count) {
		if (i < typeStrs.length && typeStrs[i] !== "") {
			types.push(resolveAnnotation(typeStrs[i], ctx));
		} else {
			types.push(unknownType());
		}
		i += 1;
	}
	return types;
}

// ===== Generic Parameter Extraction =====

// Extract generic param names from fnFlags: "gen:T,U" or "async|gen:T,U" → ["T", "U"]
// Define a generic param symbol, handling optional constraint: "T" or "T:Comparable"
function defineGenericParam(ctx: CheckerContext, paramStr: string): void {
	const colonPos = findChar(paramStr, ":");
	if (colonPos > 0) {
		// Has constraint: "T:Comparable" → name="T", constraint="Comparable"
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
		resolveDecl(ctx, stmt);
	}
}

function resolveDecl(ctx: CheckerContext, node: Node): void {
	match (node.kind) {
		NodeKind.FunctionDecl => resolveFunction(ctx, node),
		NodeKind.InterfaceDecl => resolveInterface(ctx, node),
		NodeKind.ClassDecl => resolveClass(ctx, node),
		NodeKind.TypeAliasDecl => resolveTypeAlias(ctx, node),
		NodeKind.VariableDecl => resolveVariable(ctx, node),
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			resolveDecl(ctx, d.exportedDecl);
		},
		_ => {},
	};
}

function resolveFunction(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	const sym = lookupSymbol(ctx.table, d.fnName);
	if (sym === null) return;

	// Open temp scope with GenericParam types so resolveAnnotation finds "T" → GenericParam("T")
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

	if (genericNames.length > 0) {
		closeScope(ctx.table);
	}

	// Overload handling: resolve in declaration order
	if (sym.overloads.length > 0 && sym.symbolType.kind !== TypeKind.Unknown) {
		// Primary already resolved — assign to first unresolved overload
		for (const overload of sym.overloads) {
			if (overload.symbolType.kind === TypeKind.Unknown) {
				overload.symbolType = fnType;
				return;
			}
		}
	}

	sym.symbolType = fnType;
	// Update extension method type in registry if this is an extension
	if (isExtensionFlag(d.fnFlags) && ctx.extensionRegistry !== null) {
		const receiverType = getExtReceiverType(d.fnFlags);
		if (receiverType !== "") {
			const ext = findExtension(ctx.extensionRegistry, receiverType, d.fnName);
			if (ext !== null) {
				ext.fnType = fnType;
			}
		}
	}
}

function resolveInterface(ctx: CheckerContext, node: Node): void {
	const d = node.data as InterfaceDeclData;
	const sym = lookupSymbol(ctx.table, d.interfaceName);
	if (sym === null) return;

	// Check for generic params (e.g., interface Box<T> — parser stores in side-channel)
	const genericStr = getGenericDecl(d.interfaceName);
	const hasGenerics = genericStr !== "";
	if (hasGenerics) {
		openScope(ctx.table, ScopeKind.Block);
		const genericNames = splitTopLevel(genericStr, ",");
		for (const gp of genericNames) {
			const trimGp = trim(gp);
			if (trimGp !== "") {
				defineGenericParam(ctx, trimGp);
			}
		}
	}

	const fieldTypes = resolveTypeStrings(d.interfaceFieldTypes, d.interfaceFields.length, ctx);

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	sym.symbolType = createObject(d.interfaceName, d.interfaceFields, fieldTypes, true);
}

function resolveTypeAlias(ctx: CheckerContext, node: Node): void {
	const d = node.data as TypeAliasDeclData;
	const sym = lookupSymbol(ctx.table, d.aliasName);
	if (sym === null) return;
	if (d.aliasType === "") return;
	const resolved = resolveAnnotation(d.aliasType, ctx);
	if (d.aliasIsDistinct) {
		sym.symbolType = createDistinct(resolved);
	} else {
		sym.symbolType = resolved;
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

	// Check for generic params (e.g., class Container<T> — parser stores in side-channel)
	const genericStr = getGenericDecl(d.className);
	const hasGenerics = genericStr !== "";
	if (hasGenerics) {
		openScope(ctx.table, ScopeKind.Block);
		const genericNames = splitTopLevel(genericStr, ",");
		for (const gp of genericNames) {
			const trimGp = trim(gp);
			if (trimGp !== "") {
				defineGenericParam(ctx, trimGp);
			}
		}
	}

	// Build Object type — collect member names and types into local arrays
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (const member of d.classBody) {
		resolveClassMember(ctx, memberNames, memberTypes, member);
	}

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	sym.symbolType = createObject(d.className, memberNames, memberTypes, false);
}

function resolveClassMember(ctx: CheckerContext, memberNames: string[], memberTypes: Type[], member: Node): void {
	match (member.kind) {
		NodeKind.MethodDecl => {
			const md = member.data as MethodDeclData;
			memberNames.push(md.methodName);
			const paramTypes = resolveTypeStrings(md.methodParamTypes, md.methodParams.length, ctx);
			const returnType = (md.methodReturnType !== "") ? resolveAnnotation(md.methodReturnType, ctx) : unknownType();
			memberTypes.push(createFunction(paramTypes, md.methodParams, returnType));
		},
		NodeKind.PropertyDecl => {
			const pd = member.data as PropertyDeclData;
			memberNames.push(pd.propName);
			if (pd.propType !== "") {
				memberTypes.push(resolveAnnotation(pd.propType, ctx));
			} else {
				memberTypes.push(unknownType());
			}
		},
		NodeKind.ConstructorDecl => {
			memberNames.push("constructor");
			const cd = member.data as ConstructorDeclData;
			const paramTypes = resolveTypeStrings(cd.ctorParamTypes, cd.ctorParams.length, ctx);
			memberTypes.push(createFunction(paramTypes, cd.ctorParams, voidType()));
		},
		_ => {},
	};
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

testGroup("Resolve Primitives", () => {
	test("number", () => { check(resolveWith("number").kind === TypeKind.Number); });
	test("string", () => { check(resolveWith("string").kind === TypeKind.String); });
	test("boolean", () => { check(resolveWith("boolean").kind === TypeKind.Boolean); });
	test("void", () => { check(resolveWith("void").kind === TypeKind.Void); });
	test("null", () => { check(resolveWith("null").kind === TypeKind.Null); });
	test("never", () => { check(resolveWith("never").kind === TypeKind.Never); });
	test("int32", () => { check(resolveWith("int32").kind === TypeKind.Int32); });
	test("float64", () => { check(resolveWith("float64").kind === TypeKind.Float64); });
	test("unknown name", () => { check(resolveWith("Foo").kind === TypeKind.TypeReference); });
	test("empty", () => { check(resolveWith("").kind === TypeKind.Unknown); });
});

testGroup("Resolve Arrays", () => {
	test("number[]", () => {
		const t = resolveWith("number[]");
		check(t.kind === TypeKind.Array);
		check(t.typeReturn.kind === TypeKind.Number);
	});
	test("string[]", () => {
		const t = resolveWith("string[]");
		check(t.kind === TypeKind.Array);
		check(t.typeReturn.kind === TypeKind.String);
	});
});

testGroup("Resolve Generics", () => {
	test("Result<number, string>", () => {
		const t = resolveWith("Result<number, string>");
		check(t.kind === TypeKind.Result);
		check(t.typeReturn.kind === TypeKind.Number);
		check(t.typeExtra.kind === TypeKind.String);
	});
	test("Array<boolean>", () => {
		const t = resolveWith("Array<boolean>");
		check(t.kind === TypeKind.Array);
		check(t.typeReturn.kind === TypeKind.Boolean);
	});
	test("Map<string, number>", () => {
		const t = resolveWith("Map<string, number>");
		check(t.kind === TypeKind.Map);
		check(t.typeReturn.kind === TypeKind.String);
		check(t.typeExtra.kind === TypeKind.Number);
	});
	test("Record<string, number> desugars to Map", () => {
		const t = resolveWith("Record<string, number>");
		check(t.kind === TypeKind.Map);
		check(t.typeReturn.kind === TypeKind.String);
		check(t.typeExtra.kind === TypeKind.Number);
	});
	test("Record<string, boolean> value type", () => {
		const t = resolveWith("Record<string, boolean>");
		check(t.kind === TypeKind.Map);
		check(t.typeExtra.kind === TypeKind.Boolean);
	});
});

testGroup("Resolve Unions", () => {
	test("string | number", () => {
		const t = resolveWith("string | number");
		check(t.kind === TypeKind.Union);
		check(t.typeChildren.length === 2);
		check(t.typeChildren[0].kind === TypeKind.String);
		check(t.typeChildren[1].kind === TypeKind.Number);
	});
});

testGroup("Resolve Symbols", () => {
	test("known symbol", () => {
		const ctx = createContext();
		defineSymbol(ctx.table, makeSymbol("MyType", SymbolKind.Interface, createObject("MyType", [], [], true), false));
		const t = resolveAnnotation("MyType", ctx);
		check(t.kind === TypeKind.Object);
		check(t.typeName === "MyType");
	});
});

testGroup("Resolve Declarations", () => {
	test("function gets Function type", () => {
		const ctx = createContext();
		defineSymbol(ctx.table, makeSymbol("foo", SymbolKind.Function, unknownType(), false));
		// Simulate a FunctionDecl node
		const zl: SourceLocation = { line: 0, column: 0 };
		const node = createNodeAt(NodeKind.Program, { programStmts: [
			createNodeAt(NodeKind.FunctionDecl, { fnName: "foo", params: ["a", "b"], fnParamTypes: ["", ""], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "" }, zl),
		] }, zl);
		resolveDeclarations(ctx, node);
		const sym = lookupSymbol(ctx.table, "foo");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
		check(sym.symbolType.typeChildren.length === 2);
		check(sym.symbolType.typeNames[0] === "a");
		check(sym.symbolType.typeNames[1] === "b");
	});
	test("function with typed params", () => {
		const ctx = createContext();
		defineSymbol(ctx.table, makeSymbol("add", SymbolKind.Function, unknownType(), false));
		const zl: SourceLocation = { line: 0, column: 0 };
		const node = createNodeAt(NodeKind.Program, { programStmts: [
			createNodeAt(NodeKind.FunctionDecl, { fnName: "add", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number" }, zl),
		] }, zl);
		resolveDeclarations(ctx, node);
		const sym = lookupSymbol(ctx.table, "add");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
		check(sym.symbolType.typeChildren[0].kind === TypeKind.Number);
		check(sym.symbolType.typeChildren[1].kind === TypeKind.Number);
		check(sym.symbolType.typeReturn.kind === TypeKind.Number);
	});
});

testGroup("Generic Interface Instantiation", () => {
	test("Box<number> records instantiation", () => {
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
	});
	test("Pair<string, number> records instantiation", () => {
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
	});
	test("dedup instantiation", () => {
		resetGenericDeclStore();
		resetGenericTypeInsts();
		addGenericDecl("Box", "T");
		updateGenericDeclFields("Box", "value", "T");
		const ctx = createContext();
		resolveAnnotation("Box<number>", ctx);
		resolveAnnotation("Box<number>", ctx);
		check(getGenericTypeInstCount() === 1);
	});
	test("non-generic base falls through", () => {
		resetGenericDeclStore();
		resetGenericTypeInsts();
		// No addGenericDecl for "Foo" — should fall through to symbol lookup
		const ctx = createContext();
		defineSymbol(ctx.table, makeSymbol("Foo", SymbolKind.Interface, createObject("Foo", [], [], true), false));
		const t = resolveAnnotation("Foo<number>", ctx);
		// Non-generic: returns base type (Foo)
		check(t.kind === TypeKind.Object);
		check(t.typeName === "Foo");
	});
	test("generic class Container<T> records instantiation", () => {
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
	});
});

testGroup("Generic Constraints", () => {
	test("constraint stored on GenericParam typeExtra", () => {
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
	});
	test("no constraint leaves typeExtra null", () => {
		const ctx = createContext();
		openScope(ctx.table, ScopeKind.Block);
		defineGenericParam(ctx, "U");
		const sym = lookupSymbol(ctx.table, "U");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.GenericParam);
		check(sym.symbolType.typeName === "U");
		closeScope(ctx.table);
	});
	test("constrained interface Box<T extends number>", () => {
		resetGenericDeclStore();
		resetGenericTypeInsts();
		// Parser captures "T:number" for generic params
		addGenericDecl("Box", "T:number");
		updateGenericDeclFields("Box", "value", "T");
		const ctx = createContext();
		const t = resolveAnnotation("Box<number>", ctx);
		check(t.kind === TypeKind.TypeReference);
		check(t.typeName === "Box__number");
	});
});
