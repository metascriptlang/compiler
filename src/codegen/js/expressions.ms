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

export function emitCallExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as CallExprData;

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
	for (let i = 0; i < d.keys.length; i += 1) {
		if (i > 0) emit(gen, ", ");
		emit(gen, d.keys[i]);
		emit(gen, ": ");
		if (i < d.properties.length) {
			emitNode(gen, d.properties[i]);
		}
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
	const isAsync = d.arrowFlags === "async" || d.arrowFlags === "async_generator";
	if (isAsync) { emit(gen, "async "); }
	if (d.arrowParams.length === 1 && !isAsync) {
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
	if (d.funcExprFlags === "async") { emit(gen, "async function("); }
	else if (d.funcExprFlags === "generator") { emit(gen, "function*("); }
	else if (d.funcExprFlags === "async_generator") { emit(gen, "async function*("); }
	else { emit(gen, "function("); }
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
