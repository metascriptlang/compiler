// Optional Coercion — wraps T returns for T|null return types in C
// Follows reference optional_coercion.zig
//
// In C, `T | null` is represented as a tagged union (ms_optional_T).
// When a function returns T|null but an arm returns plain T,
// the value must be wrapped: return ms_optional_wrap(value);
// When returning null: return ms_optional_null();
//
// Without type info: this transform is conservative. It only transforms
// explicit `return null` in functions with T|null return annotation.
// Full implementation requires checker to know function return types.
// TODO: With checker integration, wrap all non-null returns in T|null functions.

import {
	Node, NodeKind,
	FunctionDeclData, ReturnStmtData, BlockStmtData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent } from "../util";
import { findChar } from "../../utils/string";
import { test, check, testGroup } from "std/testing";
import { firstStmtKindAfter, stmtCountAfter } from "../testUtil";

// ===== Main Entry Point =====

export function coerceOptionals(program: Node, ctx: TransformContext): Node {
	walkNode(program, optionalVisitor);
	return program;
}

function optionalVisitor(node: Node): Node {
	if (node.kind !== NodeKind.FunctionDecl) return node;
	const d = node.data as FunctionDeclData;

	// Check if return type annotation contains "|" (union type, likely T|null)
	if (!isOptionalReturnType(d.fnReturnType)) return node;

	// Walk the function body and transform return statements
	transformReturnsInBody(d.fnBody, d.fnReturnType);

	return node;
}

// Check if a return type string looks like an optional (contains top-level "|")
function isOptionalReturnType(retType: string): boolean {
	if (retType === "") return false;
	return findChar(retType, "|") >= 0;
}

// Walk body and transform `return null` → `return ms_optional_null()`
function transformReturnsInBody(body: Node, retType: string): void {
	match (body.kind) {
		NodeKind.ReturnStmt => {
			const rd = body.data as ReturnStmtData;
			if (rd.argument.kind === NodeKind.NullLiteral) {
				const loc = body.location;
				rd.argument = makeCall(makeIdent("ms_optional_null", loc), [], loc);
			}
		},
		NodeKind.BlockStmt => {
			const bd = body.data as BlockStmtData;
			let i = 0;
			while (i < bd.statements.length) {
				transformReturnsInBody(bd.statements[i], retType);
				i += 1;
			}
		},
		_ => {},
	};
}

// ===== Tests =====

testGroup("Optional Coercion", () => {
	test("non-return unchanged", () => {
		check(stmtCountAfter("const x = 1;", coerceOptionals) === 1);
	});
	test("call unchanged", () => {
		check(firstStmtKindAfter("f();", coerceOptionals) === NodeKind.ExprStmt);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", coerceOptionals) === NodeKind.WhileStmt);
	});
	test("if unchanged", () => {
		check(firstStmtKindAfter("if (x) {}", coerceOptionals) === NodeKind.IfStmt);
	});
	test("non-optional function unchanged", () => {
		check(firstStmtKindAfter("function foo(): number { return 1; }", coerceOptionals) === NodeKind.FunctionDecl);
	});
});
