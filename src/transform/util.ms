// Transform Utilities — node-building helpers for AST transforms
// Each helper wraps createNode with the correct NodeKind and data shape.

import { Token, TokenKind, createToken } from "../lexer/token";
import {
	Node, NodeKind, DeclKind, SourceLocation, createNode,
	BlockStmtData, VariableDeclData, IfStmtData, WhileStmtData,
	TryCatchStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
} from "../ast/node";
import { TransformContext, freshTemp, NameSet, nameSetAdd } from "./context";

// Create a synthetic token from a source location (for transform-generated nodes)
export function syntheticToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}

// ===== Literal Builders =====

export function makeIdent(identName: string, loc: SourceLocation): Node {
	return createNode(NodeKind.Identifier, { name: identName }, syntheticToken(loc));
}

export function makeNull(loc: SourceLocation): Node {
	return createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, syntheticToken(loc));
}

export function makeNumber(val: number, loc: SourceLocation): Node {
	return createNode(NodeKind.NumberLiteral, { value: val }, syntheticToken(loc));
}

export function makeString(val: string, loc: SourceLocation): Node {
	return createNode(NodeKind.StringLiteral, { value: val }, syntheticToken(loc));
}

export function makeBool(val: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.BooleanLiteral, { boolValue: val }, syntheticToken(loc));
}

// ===== Statement Builders =====

export function makeBlock(stmts: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.BlockStmt, { statements: stmts }, syntheticToken(loc));
}

export function makeVarDecl(varName: string, init: Node, declKind: DeclKind, loc: SourceLocation): Node {
	return createNode(NodeKind.VariableDecl, { declName: varName, declType: "", initializer: init, declKind }, syntheticToken(loc));
}

export function makeExprStmt(exprNode: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ExprStmt, { expr: exprNode }, syntheticToken(loc));
}

export function makeReturn(arg: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ReturnStmt, { argument: arg }, syntheticToken(loc));
}

export function makeIf(cond: Node, thenBranch: Node, elseBranch: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.IfStmt, { condition: cond, consequent: thenBranch, alternate: elseBranch }, syntheticToken(loc));
}

export function makeWhile(cond: Node, body: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.WhileStmt, { whileCondition: cond, whileBody: body }, syntheticToken(loc));
}

export function makeTryCatch(tryBody: Node, catchName: string, catchBody: Node, finallyBody: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.TryCatchStmt, { tryBody, catchName, catchBody, finallyBody }, syntheticToken(loc));
}

export function makeContinue(loc: SourceLocation): Node {
	return createNode(NodeKind.ContinueStmt, { continueLabel: "" }, syntheticToken(loc));
}

// ===== Expression Builders =====

export function makeBinary(leftNode: Node, op: string, rightNode: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.BinaryExpr, { operator: op, left: leftNode, right: rightNode }, syntheticToken(loc));
}

export function makeUnary(op: string, arg: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.UnaryExpr, { unaryOp: op, operand: arg }, syntheticToken(loc));
}

export function makeCall(calleeNode: Node, args: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.CallExpr, { callee: calleeNode, arguments: args }, syntheticToken(loc));
}

export function makeMember(obj: Node, prop: string, loc: SourceLocation): Node {
	return createNode(NodeKind.MemberExpr, { object: obj, property: prop, isOptional: false }, syntheticToken(loc));
}

export function makeConditional(cond: Node, cons: Node, alt: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ConditionalExpr, { ternaryCondition: cond, ternaryConsequent: cons, ternaryAlternate: alt }, syntheticToken(loc));
}

export function makeAssign(leftNode: Node, rightNode: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.BinaryExpr, { operator: "=", left: leftNode, right: rightNode }, syntheticToken(loc));
}

export function makeArrayAccess(obj: Node, idx: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ArrayAccess, { array: obj, index: idx }, syntheticToken(loc));
}

export function makeSwitch(disc: Node, cases: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.SwitchStmt, { switchDisc: disc, switchCases: cases }, syntheticToken(loc));
}

export function makeSwitchCase(tests: Node[], stmts: Node[], isDefault: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.SwitchCase, { caseTests: tests, caseStmts: stmts, isDefault }, syntheticToken(loc));
}

// ===== Declaration Builders =====

export function makeFnDecl(name: string, fnParams: string[], paramTypes: string[], body: Node, flags: string, returnType: string, loc: SourceLocation): Node {
	return createNode(NodeKind.FunctionDecl, {
		fnName: name, params: fnParams, fnParamTypes: paramTypes,
		fnBody: body, fnFlags: flags, fnReturnType: returnType,
	}, syntheticToken(loc));
}

export function makeInterfaceDecl(name: string, fields: string[], fieldTypes: string[], loc: SourceLocation): Node {
	return createNode(NodeKind.InterfaceDecl, {
		interfaceName: name, interfaceFields: fields, interfaceFieldTypes: fieldTypes,
	}, syntheticToken(loc));
}

export function makeObjectLiteral(keys: string[], values: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.ObjectLiteral, { properties: values, keys }, syntheticToken(loc));
}

// ===== Declaration Collection =====
// Collect variable declaration names in a function body. Stops at nested functions.
// varOnly=true: only DeclKind.Var (for varHoist). varOnly=false: all decls (for generatorLower).
// Handles: BlockStmt, IfStmt, WhileStmt, TryCatchStmt, DoWhileStmt, SwitchStmt/SwitchCase.

export function collectDeclNames(node: Node, ns: NameSet, varOnly: boolean): void {
	match (node.kind) {
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (!varOnly || d.declKind === DeclKind.Var) {
				nameSetAdd(ns, d.declName);
			}
			collectDeclNames(d.initializer, ns, varOnly);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			let i = 0;
			while (i < d.statements.length) {
				collectDeclNames(d.statements[i], ns, varOnly);
				i += 1;
			}
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			collectDeclNames(d.consequent, ns, varOnly);
			collectDeclNames(d.alternate, ns, varOnly);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			collectDeclNames(d.whileBody, ns, varOnly);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			collectDeclNames(d.tryBody, ns, varOnly);
			collectDeclNames(d.catchBody, ns, varOnly);
			collectDeclNames(d.finallyBody, ns, varOnly);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			collectDeclNames(d.doBody, ns, varOnly);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			let si = 0;
			while (si < d.switchCases.length) {
				collectDeclNames(d.switchCases[si], ns, varOnly);
				si += 1;
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			let ci = 0;
			while (ci < d.caseStmts.length) {
				collectDeclNames(d.caseStmts[ci], ns, varOnly);
				ci += 1;
			}
		},
		_ => {},
	};
}

// ===== DeclKind Helpers =====

// Convert boolean isConst flag → DeclKind enum (for AST nodes that still use boolean flags)
export function boolToDeclKind(isConst: boolean): DeclKind {
	return match (isConst) { true => DeclKind.Const, _ => DeclKind.Let };
}

// ===== Helpers =====

// Capture an expression into a temp variable to prevent double-evaluation.
// Returns { decl: const $tmp_N = expr, ref: $tmp_N identifier }.
// Follows Nim's lowerings.nim:evalOnce pattern.
export function evalOnce(expr: Node, ctx: TransformContext, loc: SourceLocation): { decl: Node, ref: Node } {
	const name = freshTemp(ctx, "tmp");
	return {
		decl: makeVarDecl(name, expr, DeclKind.Const, loc),
		ref: makeIdent(name, loc),
	};
}

// Extract statements from a body node (block → its stmts, single stmt → [stmt])
export function extractBodyStmts(body: Node): Node[] {
	const result: Node[] = [];
	if (body.kind === NodeKind.BlockStmt) {
		const bd = body.data as BlockStmtData;
		for (const stmt of bd.statements) {
			result.push(stmt);
		}
	} else {
		result.push(body);
	}
	return result;
}
