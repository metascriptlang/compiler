// JavaScript Codegen — Expression Emitters

import {
	Node, NodeKind,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	BigIntLiteralData, RegexLiteralData,
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData,
	ArrowFunctionData, FunctionExprData,
	TypeAssertionData, ConditionalExprData,
	SpreadExprData, NewExprData, MoveExprData,
	AwaitExprData, YieldExprData,
} from "../../ast/node";
import { emit, emitNode, emitIndent, emitNewline, JSGenerator, escapeJSString, emitJoinedStrings, emitJoinedNodes } from "./emit";

// ===== Literal Emitters =====

export function emitNumberLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as NumberLiteralData;
	if (d.value < 0) {
		emit(gen, "(");
		emit(gen, "" + d.value);
		emit(gen, ")");
	} else {
		emit(gen, "" + d.value);
	}
}

export function emitStringLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as StringLiteralData;
	emit(gen, "\"");
	emit(gen, escapeJSString(d.value));
	emit(gen, "\"");
}

export function emitBooleanLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as BooleanLiteralData;
	if (d.boolValue) {
		emit(gen, "true");
	} else {
		emit(gen, "false");
	}
}

export function emitNullLiteral(gen: JSGenerator, node: Node): void {
	emit(gen, "null");
}

export function emitBigIntLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as BigIntLiteralData;
	emit(gen, d.bigintValue);
}

export function emitRegexLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as RegexLiteralData;
	emit(gen, d.regexPattern);
}

// ===== Identifier =====

export function emitIdentifier(gen: JSGenerator, node: Node): void {
	const d = node.data as IdentifierData;
	emit(gen, d.name);
}

// ===== Binary Expression =====

export function emitBinaryExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as BinaryExprData;
	// Assignment doesn't need outer parens
	if (d.operator === "=") {
		emitNode(gen, d.left);
		emit(gen, " = ");
		emitNode(gen, d.right);
	} else if (d.operator === "+=" || d.operator === "-=" || d.operator === "*=" || d.operator === "/=" || d.operator === "%=") {
		emitNode(gen, d.left);
		emit(gen, " ");
		emit(gen, d.operator);
		emit(gen, " ");
		emitNode(gen, d.right);
	} else {
		emit(gen, "(");
		emitNode(gen, d.left);
		emit(gen, " ");
		emit(gen, d.operator);
		emit(gen, " ");
		emitNode(gen, d.right);
		emit(gen, ")");
	}
}

// ===== Unary Expression =====

export function emitUnaryExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as UnaryExprData;
	if (d.unaryOp === "typeof") {
		emit(gen, "typeof ");
		emitNode(gen, d.operand);
	} else {
		emit(gen, d.unaryOp);
		emitNode(gen, d.operand);
	}
}

// ===== Update Expression =====

export function emitUpdateExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as UpdateExprData;
	if (d.isPrefix) {
		emit(gen, d.updateOp);
		emitNode(gen, d.updateArg);
	} else {
		emitNode(gen, d.updateArg);
		emit(gen, d.updateOp);
	}
}

// ===== Call Expression =====

function isResultOkCall(node: Node): boolean {
	if (node.kind !== NodeKind.CallExpr) return false;
	const d = node.data as CallExprData;
	if (d.callee.kind !== NodeKind.MemberExpr) return false;
	const m = d.callee.data as MemberExprData;
	if (m.object.kind !== NodeKind.Identifier) return false;
	const id = m.object.data as IdentifierData;
	return id.name === "Result" && m.property === "ok";
}

function isResultErrCall(node: Node): boolean {
	if (node.kind !== NodeKind.CallExpr) return false;
	const d = node.data as CallExprData;
	if (d.callee.kind !== NodeKind.MemberExpr) return false;
	const m = d.callee.data as MemberExprData;
	if (m.object.kind !== NodeKind.Identifier) return false;
	const id = m.object.data as IdentifierData;
	return id.name === "Result" && m.property === "err";
}

export function emitCallExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as CallExprData;

	// Denormalize Result.ok(x) → { ok: true, value: x }
	if (isResultOkCall(node)) {
		emit(gen, "{ ok: true, value: ");
		if (d.arguments.length > 0) {
			emitNode(gen, d.arguments[0]);
		} else {
			emit(gen, "undefined");
		}
		emit(gen, " }");
		return;
	}

	// Denormalize Result.err(e) → { ok: false, error: e }
	if (isResultErrCall(node)) {
		emit(gen, "{ ok: false, error: ");
		if (d.arguments.length > 0) {
			emitNode(gen, d.arguments[0]);
		} else {
			emit(gen, "undefined");
		}
		emit(gen, " }");
		return;
	}

	// Regular function call
	emitNode(gen, d.callee);
	emit(gen, "(");
	emitJoinedNodes(gen, d.arguments, ", ");
	emit(gen, ")");
}

// ===== Member Expression =====

export function emitMemberExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as MemberExprData;
	// Wrap number literals: (42).toString()
	if (d.object.kind === NodeKind.NumberLiteral) {
		emit(gen, "(");
		emitNode(gen, d.object);
		emit(gen, ")");
	} else {
		emitNode(gen, d.object);
	}
	if (d.isOptional) {
		emit(gen, "?.");
	} else {
		emit(gen, ".");
	}
	emit(gen, d.property);
}

// ===== Array Access =====

export function emitArrayAccess(gen: JSGenerator, node: Node): void {
	const d = node.data as ArrayAccessData;
	emitNode(gen, d.array);
	emit(gen, "[");
	emitNode(gen, d.index);
	emit(gen, "]");
}

// ===== Object Literal =====

export function emitObjectLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as ObjectLiteralData;
	if (d.keys.length === 0) {
		emit(gen, "{}");
		return;
	}
	emit(gen, "{ ");
	let i = 0;
	while (i < d.keys.length) {
		if (i > 0) emit(gen, ", ");
		emit(gen, d.keys[i]);
		emit(gen, ": ");
		if (i < d.properties.length) {
			emitNode(gen, d.properties[i]);
		}
		i += 1;
	}
	emit(gen, " }");
}

// ===== Array Literal =====

export function emitArrayLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as ArrayLiteralData;
	emit(gen, "[");
	emitJoinedNodes(gen, d.elements, ", ");
	emit(gen, "]");
}

// ===== Arrow Function =====

export function emitArrowFunction(gen: JSGenerator, node: Node): void {
	const d = node.data as ArrowFunctionData;
	if (d.arrowParams.length === 1) {
		emit(gen, d.arrowParams[0]);
	} else {
		emit(gen, "(");
		emitJoinedStrings(gen, d.arrowParams, ", ");
		emit(gen, ")");
	}
	emit(gen, " => ");
	emitNode(gen, d.arrowBody);
}

// ===== Function Expression =====

export function emitFunctionExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as FunctionExprData;
	emit(gen, "function(");
	emitJoinedStrings(gen, d.funcExprParams, ", ");
	emit(gen, ") ");
	emitNode(gen, d.funcExprBody);
}

// ===== Conditional Expression =====

export function emitConditionalExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as ConditionalExprData;
	emit(gen, "(");
	emitNode(gen, d.ternaryCondition);
	emit(gen, " ? ");
	emitNode(gen, d.ternaryConsequent);
	emit(gen, " : ");
	emitNode(gen, d.ternaryAlternate);
	emit(gen, ")");
}

// ===== Spread Expression =====

export function emitSpreadExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as SpreadExprData;
	emit(gen, "...");
	emitNode(gen, d.spreadArg);
}

// ===== New Expression =====

export function emitNewExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as NewExprData;
	emit(gen, "new ");
	emitNode(gen, d.newCallee);
	emit(gen, "(");
	emitJoinedNodes(gen, d.newArguments, ", ");
	emit(gen, ")");
}

// ===== Type Assertion (no-op in JS) =====

export function emitTypeAssertion(gen: JSGenerator, node: Node): void {
	const d = node.data as TypeAssertionData;
	emitNode(gen, d.asExpr);
}

// ===== Move Expression (no-op in JS) =====

export function emitMoveExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as MoveExprData;
	emitNode(gen, d.moveArg);
}

// ===== Await Expression (fallback if not lowered) =====

export function emitAwaitExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as AwaitExprData;
	emit(gen, "await ");
	emitNode(gen, d.awaitArg);
}

// ===== Yield Expression (fallback if not lowered) =====

export function emitYieldExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as YieldExprData;
	if (d.isDelegate) {
		emit(gen, "yield* ");
	} else {
		emit(gen, "yield ");
	}
	emitNode(gen, d.yieldArg);
}
