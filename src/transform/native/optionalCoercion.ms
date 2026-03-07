// Optional Coercion — wraps T returns for T|null return types in C
// Follows reference optional_coercion.zig
//
// In C, `T | null` is represented as a tagged union (msOptionalT).
// When a function returns T|null but an arm returns plain T,
// the value must be wrapped: return msOptionalWrap(value);
// When returning null: return msOptionalNull();
//
// Detection: function has T|null return type annotation (contains "|").
// All return statements in the body are transformed:
//   return null   → return msOptionalNull()
//   return expr   → return msOptionalWrap(expr)

import {
	Node, NodeKind,
	FunctionDeclData, ReturnStmtData, BlockStmtData, IfStmtData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent } from "../util";
import { findChar } from "../../utils/string";
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

test "return null in optional fn becomes call" {
	const k = getReturnArgKind("function foo(): number | null { return null; }");
	assert k === NodeKind.CallExpr;
}

test "return expr in optional fn becomes call" {
	const k = getReturnArgKind("function foo(): number | null { return 42; }");
	assert k === NodeKind.CallExpr;
}

test "return expr in plain fn unchanged" {
	const k = getReturnArgKind("function foo(): number { return 42; }");
	assert k === NodeKind.NumberLiteral;
}
