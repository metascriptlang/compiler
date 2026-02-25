// Pass 2: Resolve - parse type annotations, enrich collected symbols
//
// The parser currently stores type annotations as strings (TypeAnnotation nodes)
// and skips them in most places. Function params are string[] (names only).
// This pass enriches the symbol table by:
//   A. Parsing type annotation strings into Type objects
//   B. Building proper Function/Object types for collected declarations

import {
	Node, NodeKind,
	ProgramData, FunctionDeclData, InterfaceDeclData, ExportDeclData,
	ClassDeclData, MethodDeclData, PropertyDeclData, ConstructorDeclData,
} from "../ast/node";
import {
	Type, TypeKind,
	unknownType, numberType, stringType, booleanType, voidType, nullType, neverType,
	createPrimitive, createArray, createFunction, createObject, createEnum,
	createResult, createTypeRef, createUnion, createRef, createPtr,
} from "./types";
import { Symbol, SymbolKind, lookupSymbol } from "./symbol";
import { CheckerContext } from "./context";
import { trim, charAt, sliceStr, endsWith, findChar, splitTopLevel } from "../utils/string";
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
	if (unionParts.length === 3) {
		return createUnion([resolveAnnotation(unionParts[0], ctx), resolveAnnotation(unionParts[1], ctx), resolveAnnotation(unionParts[2], ctx)]);
	}
	if (unionParts.length > 3) {
		return createUnion([resolveAnnotation(unionParts[0], ctx), resolveAnnotation(unionParts[1], ctx), resolveAnnotation(unionParts[2], ctx)]);
	}

	// Check for array suffix []
	if (endsWith(trimmed, "[]")) {
		const inner = sliceStr(trimmed, 0, trimmed.length - 2);
		return createArray(resolveAnnotation(inner, ctx));
	}

	// Check for generic types: Name<A, B>
	const angleBracket = findChar(trimmed, "<");
	if (angleBracket > 0 && endsWith(trimmed, ">")) {
		const baseName = sliceStr(trimmed, 0, angleBracket);
		const argsText = sliceStr(trimmed, angleBracket + 1, trimmed.length - 1);
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
		// Generic instance: look up base type
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

	const paramTypes = resolveTypeStrings(d.fnParamTypes, d.params.length, ctx);
	const returnType = (d.fnReturnType !== "") ? resolveAnnotation(d.fnReturnType, ctx) : unknownType();
	sym.symbolType = createFunction(paramTypes, d.params, returnType);
}

function resolveInterface(ctx: CheckerContext, node: Node): void {
	const d = node.data as InterfaceDeclData;
	const sym = lookupSymbol(ctx.table, d.interfaceName);
	if (sym === null) return;

	const fieldTypes = resolveTypeStrings(d.interfaceFieldTypes, d.interfaceFields.length, ctx);
	sym.symbolType = createObject(d.interfaceName, d.interfaceFields, fieldTypes, true);
}

function resolveClass(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	const sym = lookupSymbol(ctx.table, d.className);
	if (sym === null) return;

	// Build Object type — collect member names and types into local arrays
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (const member of d.classBody) {
		resolveClassMember(ctx, memberNames, memberTypes, member);
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
			memberTypes.push(unknownType());
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
import { createSymbolTable, defineSymbol, makeSymbol } from "./symbol";

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
		const node: Node = {
			kind: NodeKind.Program,
			location: { line: 0, column: 0 },
			data: { programStmts: [{
				kind: NodeKind.FunctionDecl,
				location: { line: 0, column: 0 },
				data: { fnName: "foo", params: ["a", "b"], fnParamTypes: ["", ""], fnBody: { kind: NodeKind.BlockStmt, location: { line: 0, column: 0 }, data: { statements: [] } }, fnFlags: "", fnReturnType: "" },
			}] },
		};
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
		const node: Node = {
			kind: NodeKind.Program,
			location: { line: 0, column: 0 },
			data: { programStmts: [{
				kind: NodeKind.FunctionDecl,
				location: { line: 0, column: 0 },
				data: { fnName: "add", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: { kind: NodeKind.BlockStmt, location: { line: 0, column: 0 }, data: { statements: [] } }, fnFlags: "", fnReturnType: "number" },
			}] },
		};
		resolveDeclarations(ctx, node);
		const sym = lookupSymbol(ctx.table, "add");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
		check(sym.symbolType.typeChildren[0].kind === TypeKind.Number);
		check(sym.symbolType.typeChildren[1].kind === TypeKind.Number);
		check(sym.symbolType.typeReturn.kind === TypeKind.Number);
	});
});
