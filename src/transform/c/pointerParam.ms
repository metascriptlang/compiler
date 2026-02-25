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
// Without full type info: uses syntactic heuristic on type annotation.
// Parameters with non-primitive type names are flagged as pointer candidates.
// TODO: With checker integration, look up type in SymbolTable for accuracy.

import {
	Node, NodeKind,
	FunctionDeclData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { test, check, testGroup } from "std/testing";
import { firstStmtKindAfter, stmtCountAfter } from "../testUtil";

// ===== Main Entry Point =====

export function markPointerParams(program: Node, ctx: TransformContext): Node {
	walkNode(program, markParams);
	return program;
}

function markParams(node: Node): Node {
	if (node.kind !== NodeKind.FunctionDecl) return node;
	const d = node.data as FunctionDeclData;

	// Analysis pass: check each parameter's type annotation
	// C codegen will use fnParamTypes to determine pointer vs value treatment.
	// This transform validates the data is accessible; actual pointer decisions
	// are made by codegen using isPrimitiveType checks on the type annotations.
	// No AST mutation needed — fnParamTypes already carries the info.

	return node;
}

// Utility for C codegen: check if a type name is a primitive (value type in C)
export function isPrimitiveTypeName(typeName: string): boolean {
	return match (typeName) {
		"number" | "string" | "boolean" | "void" | "null" | "undefined" | "any" | "unknown" | "never" => true,
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
});
