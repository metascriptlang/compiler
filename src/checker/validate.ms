// AST Validator — ensures Phase 2 finalized all semantic metadata
//
// Every expression node MUST have a non-null nodeType.
// Every CallExpr and MemberExpr MUST have a non-null resolvedSym.
// Every Identifier MUST have a non-null resolvedSym.
//
// This is the gate that guarantees Phase 5 (Codegen) is a pure DUMP layer.

import { Node, NodeKind, ProgramData, FunctionDeclData, ClassDeclData, VariableDeclData, ExprStmtData, CallExprData, MemberExprData, IdentifierData, BinaryExprData, UnaryExprData, IfStmtData, WhileStmtData, ReturnStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, MatchStmtData, MatchCaseData, BlockStmtData, DecoratedDeclData, ExportDeclData } from "../ast/node";
import { CheckerContext, addError } from "./context";


export function validateTypedAST(ctx: CheckerContext, node: Node): void {
	if (node === null) return;

	// Check semantic metadata on expression nodes
	if (isExpression(node)) {
		if (node.nodeType === null) {
			addError(ctx, `Internal Error: missing nodeType on ${nodeKindToString(node.kind)} at line ${node.location.line}`);
		}

		match (node.kind) {
			NodeKind.Identifier => {
				if (node.resolvedSym === null) {
					const d = node.data as IdentifierData;
					addError(ctx, `Internal Error: un-resolved identifier '${d.name}' at line ${node.location.line}`);
				}
			},
			NodeKind.CallExpr => {
				if (node.resolvedSym === null) {
					addError(ctx, `Internal Error: un-resolved call at line ${node.location.line}`);
				}
			},
			NodeKind.MemberExpr => {
				// MemberExpr might be enum member access (rewritten to Identifier by checker)
				// or it might be a property/method.
				if (node.resolvedSym === null) {
					const d = node.data as MemberExprData;
					addError(ctx, `Internal Error: un-resolved member access '${d.property}' at line ${node.location.line}`);
				}
			},
			_ => {},
		};
	}

	// Recurse based on node kind
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const s of d.programStmts) validateTypedAST(ctx, s);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			if (d.fnBody !== null) validateTypedAST(ctx, d.fnBody);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			for (const m of d.classBody) validateTypedAST(ctx, m);
		},
		NodeKind.MethodDecl => {
			const d = node.data as FunctionDeclData; // MethodDecl shares FunctionDeclData layout
			if (d.fnBody !== null) validateTypedAST(ctx, d.fnBody);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (d.initializer !== null) validateTypedAST(ctx, d.initializer);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) validateTypedAST(ctx, s);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			validateTypedAST(ctx, d.condition);
			validateTypedAST(ctx, d.consequent);
			if (d.alternate !== null) validateTypedAST(ctx, d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			validateTypedAST(ctx, d.whileCondition);
			validateTypedAST(ctx, d.whileBody);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			validateTypedAST(ctx, d.expr);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (d.argument !== null) validateTypedAST(ctx, d.argument);
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			validateTypedAST(ctx, d.left);
			validateTypedAST(ctx, d.right);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			validateTypedAST(ctx, d.operand);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			validateTypedAST(ctx, d.callee);
			for (const a of d.arguments) validateTypedAST(ctx, a);
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			validateTypedAST(ctx, d.object);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			validateTypedAST(ctx, d.decoratedNode);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			validateTypedAST(ctx, d.exportedDecl);
		},
		_ => {},
	};
}

function isExpression(node: Node): boolean {
	const k = node.kind;
	return k === NodeKind.Identifier || k === NodeKind.NumberLiteral || k === NodeKind.StringLiteral ||
		   k === NodeKind.BooleanLiteral || k === NodeKind.NullLiteral || k === NodeKind.BinaryExpr ||
		   k === NodeKind.UnaryExpr || k === NodeKind.CallExpr || k === NodeKind.MemberExpr ||
		   k === NodeKind.ArrayAccess || k === NodeKind.ConditionalExpr || k === NodeKind.ObjectLiteral ||
		   k === NodeKind.ArrayLiteral || k === NodeKind.TypeAssertion || k === NodeKind.ArrowFunction ||
		   k === NodeKind.FunctionExpr || k === NodeKind.NewExpr;
}

function nodeKindToString(k: NodeKind): string {
	return match (k) {
		NodeKind.Identifier => "Identifier",
		NodeKind.NumberLiteral => "NumberLiteral",
		NodeKind.BinaryExpr => "BinaryExpr",
		NodeKind.CallExpr => "CallExpr",
		NodeKind.MemberExpr => "MemberExpr",
		_ => "Expression",
	};
}
