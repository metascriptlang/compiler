// Pass 2: Resolve - parse type annotations, enrich collected symbols
//
// The parser currently stores type annotations as strings (TypeAnnotation nodes)
// and skips them in most places. Function params are string[] (names only).
// This pass enriches the symbol table by:
//   A. Parsing type annotation strings into Type objects
//   B. Building proper Function/Object types for collected declarations

import { Node, NodeKind } from "../ast/node";
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

// ===== B. Resolve Declarations (Pass 2) =====

export function resolveDeclarations(ctx: CheckerContext, program: Node): void {
	const stmts = program.data as { programStmts: Node[] };
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
			const d = node.data as { exportedDecl: Node };
			resolveDecl(ctx, d.exportedDecl);
		},
		_ => {},
	};
}

function resolveFunction(ctx: CheckerContext, node: Node): void {
	const d = node.data as { fnName: string, params: string[], fnBody: Node, fnFlags: string };
	const sym = lookupSymbol(ctx.table, d.fnName);
	if (sym === null) return;

	// Build proper Function type with param names and unknown types
	const paramTypes: Type[] = [];
	for (const param of d.params) {
		paramTypes.push(unknownType());
	}
	sym.symbolType = createFunction(paramTypes, d.params, unknownType());
}

function resolveInterface(ctx: CheckerContext, node: Node): void {
	const d = node.data as { interfaceName: string, interfaceFields: string[] };
	const sym = lookupSymbol(ctx.table, d.interfaceName);
	if (sym === null) return;

	// Build Object type with field names and unknown types
	const fieldTypes: Type[] = [];
	for (const field of d.interfaceFields) {
		fieldTypes.push(unknownType());
	}
	sym.symbolType = createObject(d.interfaceName, d.interfaceFields, fieldTypes, true);
}

function resolveClass(ctx: CheckerContext, node: Node): void {
	const d = node.data as { className: string, classExtends: string, classBody: Node[] };
	const sym = lookupSymbol(ctx.table, d.className);
	if (sym === null) return;

	// Collect method and property names + types from class body
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (const member of d.classBody) {
		match (member.kind) {
			NodeKind.MethodDecl => {
				const md = member.data as { methodName: string, methodParams: string[], methodBody: Node, methodIsStatic: boolean, methodFlags: string };
				memberNames.push(md.methodName);
				const mParamTypes: Type[] = [];
				for (const p of md.methodParams) {
					mParamTypes.push(unknownType());
				}
				memberTypes.push(createFunction(mParamTypes, md.methodParams, unknownType()));
			},
			NodeKind.PropertyDecl => {
				const pd = member.data as { propName: string, propIsStatic: boolean };
				memberNames.push(pd.propName);
				memberTypes.push(unknownType());
			},
			NodeKind.ConstructorDecl => {
				memberNames.push("constructor");
				const cd = member.data as { ctorParams: string[], ctorBody: Node };
				const cParamTypes: Type[] = [];
				for (const p of cd.ctorParams) {
					cParamTypes.push(unknownType());
				}
				memberTypes.push(createFunction(cParamTypes, cd.ctorParams, voidType()));
			},
			_ => {},
		};
	}
	sym.symbolType = createObject(d.className, memberNames, memberTypes, false);
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
				data: { fnName: "foo", params: ["a", "b"], fnBody: { kind: NodeKind.BlockStmt, location: { line: 0, column: 0 }, data: { statements: [] } }, fnFlags: "" },
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
});
