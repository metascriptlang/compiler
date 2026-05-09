// Optional Coercion — wraps T returns for Maybe<T> return types in C.
//
// Fires for any non-pointer Maybe<T> (struct, primitive, string). Ref/Ptr/null
// types stay as Union — codegen emits bare pointers with NULL as the sentinel.
//
// Detection: resolved return type has the IsMaybe flag (set by resolvePass when
// collapsing T | null → Maybe<T> for any non-pointer T).
//
// All return statements in the body are transformed via direct struct construction
// (Nim-parity: ~/projects/nim/lib/pure/options.nim's `some(val)` returns
// `Option[T](has: true, val: val)` — a struct literal, no runtime helper):
//   return null   → return <NullLiteral typed as Maybe<T>>     // codegen emits {0}
//   return expr   → return { value: expr, present: true }      // direct struct literal

import {
	Node, NodeKind, Type,
	FunctionDeclData, ReturnStmtData, BlockStmtData, IfStmtData,
} from "../../ast/node";
import { isMaybeType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { wrapMaybeValue } from "./nullableLower";
import { firstStmtKindAfter, stmtCountAfter, parseInput, getStmts } from "../testUtil";
import { createTransformContext } from "../context";

// ===== Main Entry Point =====

export function coerceOptionals(program: Node, ctx: TransformContext): Node {
	walkNode(program, optionalVisitor);
	return program;
}

function optionalVisitor(node: Node): Node {
	if (node.kind !== NodeKind.FunctionDecl) return node;
	const d = node.data as FunctionDeclData;

	// Only fire when the resolved return type is Maybe<T>.
	// Ref/Ptr/null unions skip this transform — codegen handles them directly.
	const sym = node.resolvedSym;
	if (sym === null || sym.symbolType === null || sym.symbolType.typeReturn === null) return node;
	const maybeType = sym.symbolType.typeReturn;
	if (!isMaybeType(maybeType)) return node;

	// Walk the function body and transform return statements
	transformReturnsInBody(d.fnBody, maybeType);

	return node;
}

// Walk body and transform returns in T|null functions
function transformReturnsInBody(body: Node, maybeType: Type): void {
	match (body.kind) {
		NodeKind.ReturnStmt => {
			const rd = body.data as ReturnStmtData;
			// Canonical Maybe coercion. Handles all three cases internally:
			// already-Maybe passthrough, null retype, non-null wrap.
			rd.argument = wrapMaybeValue(rd.argument, maybeType, body.location);
		},
		NodeKind.BlockStmt => {
			const bd = body.data as BlockStmtData;
			let i = 0;
			while (i < bd.statements.length) {
				transformReturnsInBody(bd.statements[i], maybeType);
				i += 1;
			}
		},
		NodeKind.IfStmt => {
			const id = body.data as IfStmtData;
			transformReturnsInBody(id.consequent, maybeType);
			if (id.alternate !== null) {
				transformReturnsInBody(id.alternate, maybeType);
			}
		},
		_ => {},
	};
}

// ===== Helpers for Tests =====

function getReturnArgKind(input: string): NodeKind {
	const result = parseInput(input);
	if (!result.ok) return NodeKind.Program;
	const ctx = createTransformContext();
	coerceOptionals(result.value, ctx);
	const stmts = getStmts(result.value);
	if (stmts.length === 0) return NodeKind.Program;
	if (stmts[0].kind !== NodeKind.FunctionDecl) return NodeKind.Program;
	const fd = stmts[0].data as FunctionDeclData;
	const bd = fd.fnBody.data as BlockStmtData;
	if (bd.statements.length === 0) return NodeKind.Program;
	const ret = bd.statements[0];
	if (ret.kind !== NodeKind.ReturnStmt) return NodeKind.Program;
	const rd = ret.data as ReturnStmtData;
	return rd.argument.kind;
}

// ===== Tests =====
test "non-return unchanged" { assert stmtCountAfter("const x = 1;", coerceOptionals) === 1; }

test "call unchanged" { assert firstStmtKindAfter("f();", coerceOptionals) === NodeKind.ExprStmt; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", coerceOptionals) === NodeKind.WhileStmt; }

test "if unchanged" { assert firstStmtKindAfter("if (x) {}", coerceOptionals) === NodeKind.IfStmt; }

test "non-optional function unchanged" { assert firstStmtKindAfter("function foo(): number { return 1; }", coerceOptionals) === NodeKind.FunctionDecl; }

// Detection is now type-based (requires resolvedSym set by the checker).
// parseInput skips the checker, so the transform sees no Maybe flag and is a no-op.
// These tests verify that no-checker invocations don't accidentally wrap returns.
test "return null without checker is unchanged" {
	const k = getReturnArgKind("function foo(): number | null { return null; }");
	assert k === NodeKind.NullLiteral;
}

test "return expr without checker is unchanged" {
	const k = getReturnArgKind("function foo(): number | null { return 42; }");
	assert k === NodeKind.NumberLiteral;
}

test "return expr in plain fn unchanged" {
	const k = getReturnArgKind("function foo(): number { return 42; }");
	assert k === NodeKind.NumberLiteral;
}
