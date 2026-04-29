// Optional Coercion — wraps T returns for Maybe<T> (struct | null) return types in C
//
// Only fires for value-type structs wrapped as Maybe (struct has no null sentinel,
// so it needs a `{ value, present }` wrapper). Ref<T>|Null / Ptr<T>|Null stay as
// Union — codegen emits them as bare pointer with NULL sentinel, no wrapping needed.
// Primitive | null stays as Union too — wrapping helpers for primitives don't exist.
//
// Detection: resolved return type has the IsMaybe flag (set by resolvePass when
// collapsing struct | null → Maybe<T>). The string-based detection used previously
// was unsafe — it fired on every "|" annotation including ref unions.
//
// All return statements in the body are transformed:
//   return null   → return msOptionalNull()
//   return expr   → return msOptionalWrap(expr)

import {
	Node, NodeKind,
	FunctionDeclData, ReturnStmtData, BlockStmtData, IfStmtData,
} from "../../ast/node";
import { isMaybeType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent } from "../util";
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

	// Only fire when the resolved return type is Maybe<T> (struct | null).
	// Ref/Ptr/primitive unions skip this transform — codegen handles them directly.
	const sym = node.resolvedSym;
	if (sym === null || sym.symbolType === null || sym.symbolType.typeReturn === null) return node;
	if (!isMaybeType(sym.symbolType.typeReturn)) return node;

	// Walk the function body and transform return statements
	transformReturnsInBody(d.fnBody, d.fnReturnType);

	return node;
}

// Walk body and transform returns in T|null functions
function transformReturnsInBody(body: Node, retType: string): void {
	match (body.kind) {
		NodeKind.ReturnStmt => {
			const rd = body.data as ReturnStmtData;
			const loc = body.location;
			if (rd.argument.kind === NodeKind.NullLiteral) {
				// return null → return msOptionalNull()
				rd.argument = makeCall(makeIdent("msOptionalNull", loc), [], loc);
			} else {
				// return expr → return msOptionalWrap(expr)
				const args: Node[] = [];
				args.push(rd.argument);
				rd.argument = makeCall(makeIdent("msOptionalWrap", loc), args, loc);
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
		NodeKind.IfStmt => {
			const id = body.data as IfStmtData;
			transformReturnsInBody(id.consequent, retType);
			if (id.alternate !== null) {
				transformReturnsInBody(id.alternate, retType);
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
