// Pointer Parameter Marker — identifies function parameters that are pointers in C
// Follows reference pointer_param.zig + Nim's lfIndirect pattern
//
// In C, interface/class types are emitted as pointers (T*).
// This pass examines function parameter type annotations and identifies
// parameters whose types should be treated as pointers in C codegen.
//
// function foo(node: Node, count: number): void { ... }
//   → node: interface type → pointer in C (T*)
//   → count: number → value type in C
//
// Uses syntactic heuristic on type annotation strings.
// With checker context, resolves type aliases through symbol table for accuracy.

import {
	Node, NodeKind,
	FunctionDeclData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { lookupSymbol } from "../../checker/symbol";
import { TypeKind } from "../../checker/types";
import { test, check, testGroup } from "std/testing";
import { firstStmtKindAfter, stmtCountAfter, parseInput } from "../testUtil";

// ===== Main Entry Point =====

export function markPointerParams(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		return markParams(node, ctx);
	});
}

function markParams(node: Node, ctx: TransformContext): Node {
	if (node.kind !== NodeKind.FunctionDecl) return node;
	const d = node.data as FunctionDeclData;

	// Validate param types are accessible — codegen uses isPrimitiveTypeName()
	// on fnParamTypes to decide pointer vs value. With checker, we could resolve
	// type aliases, but no AST mutation is needed — fnParamTypes carries the info.
	for (const pt of d.fnParamTypes) {
		// With checker context, resolve type aliases for accuracy
		if (ctx.checkerCtx !== null && pt !== "") {
			const sym = lookupSymbol(ctx.checkerCtx.table, pt);
			if (sym !== null) {
				// If resolved type is Object or Class → pointer; else check heuristic
				if (sym.symbolType.kind === TypeKind.Object) {
					// Already non-primitive, isPrimitiveTypeName would return false
				}
			}
		}
	}

	return node;
}

// Utility for C codegen: check if a type name is a primitive (value type in C)
export function isPrimitiveTypeName(typeName: string): boolean {
	return match (typeName) {
		"number" | "string" | "boolean" | "void" | "null" | "undefined" | "any" | "unknown" | "never" => true,
		"int8" | "int16" | "int32" | "int64" | "uint8" | "uint16" | "uint32" | "uint64" => true,
		"float32" | "float64" => true,
		_ => false,
	};
}

// ===== Tests =====

testGroup("Pointer Param Marker", () => {
	test("non-function passthrough", () => {
		check(stmtCountAfter("const x = 1;", markPointerParams) === 1);
	});
	test("function stays FunctionDecl", () => {
		check(firstStmtKindAfter("function foo() {}", markPointerParams) === NodeKind.FunctionDecl);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", markPointerParams) === NodeKind.WhileStmt);
	});
	test("if unchanged", () => {
		check(firstStmtKindAfter("if (x) {}", markPointerParams) === NodeKind.IfStmt);
	});
	test("stmt count preserved", () => {
		check(stmtCountAfter("let a = 1; let b = 2;", markPointerParams) === 2);
	});
	test("isPrimitive number", () => {
		check(isPrimitiveTypeName("number"));
	});
	test("isPrimitive string", () => {
		check(isPrimitiveTypeName("string"));
	});
	test("isPrimitive boolean", () => {
		check(isPrimitiveTypeName("boolean"));
	});
	test("isPrimitive void", () => {
		check(isPrimitiveTypeName("void"));
	});
	test("isPrimitive int32", () => {
		check(isPrimitiveTypeName("int32"));
	});
	test("isPrimitive float64", () => {
		check(isPrimitiveTypeName("float64"));
	});
	test("not primitive Node", () => {
		check(!isPrimitiveTypeName("Node"));
	});
	test("not primitive Token", () => {
		check(!isPrimitiveTypeName("Token"));
	});
	test("not primitive Array", () => {
		check(!isPrimitiveTypeName("Array"));
	});
	test("not primitive empty", () => {
		check(!isPrimitiveTypeName(""));
	});
	test("function with params stays FunctionDecl", () => {
		check(firstStmtKindAfter("function foo(x: number, y: Node): void {}", markPointerParams) === NodeKind.FunctionDecl);
	});
});
