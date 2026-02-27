// Raiser codegen — Expression compilation
// AST expression nodes → typed bytecode instructions.

import {
	Node, NodeKind,
	NumberLiteralData, BooleanLiteralData, BinaryExprData, UnaryExprData,
	CallExprData, IdentifierData, MemberExprData
} from "../../ast/node";
import {
	RaiserOpcode, raiserABC, raiserABx
} from "../../raiser/bytecode";
import { raiserInt, raiserNil, raiserBool } from "../../raiser/value";
import {
	RaiserCompState, emitInst, addConst, allocReg, emitLoadConst
} from "./context";

// --- Expression compilation ---
// Returns the register holding the result.

export function compileExpr(s: RaiserCompState, node: Node): number {
	const k = node.kind;

	if (k === NodeKind.NumberLiteral) {
		const d = node.data as NumberLiteralData;
		const reg = allocReg(s);
		emitLoadConst(s, reg, raiserInt(d.value));
		return reg;
	}

	if (k === NodeKind.BooleanLiteral) {
		const d = node.data as BooleanLiteralData;
		const reg = allocReg(s);
		emitLoadConst(s, reg, raiserBool(d.boolValue));
		return reg;
	}

	if (k === NodeKind.NullLiteral) {
		const reg = allocReg(s);
		emitLoadConst(s, reg, raiserNil());
		return reg;
	}

	if (k === NodeKind.BinaryExpr) {
		return compileBinaryExpr(s, node);
	}

	if (k === NodeKind.UnaryExpr) {
		return compileUnaryExpr(s, node);
	}

	if (k === NodeKind.CallExpr) {
		return compileCallExpr(s, node);
	}

	// Fallback: load nil
	const reg = allocReg(s);
	emitLoadConst(s, reg, raiserNil());
	return reg;
}

// --- Binary ---

function compileBinaryExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as BinaryExprData;
	const lReg = compileExpr(s, d.left);
	const rReg = compileExpr(s, d.right);
	const dest = allocReg(s);
	const op = d.operator;

	if (op === "+") { emitInst(s, raiserABC(RaiserOpcode.AddI64, dest, lReg, rReg)); }
	else if (op === "-") { emitInst(s, raiserABC(RaiserOpcode.SubI64, dest, lReg, rReg)); }
	else if (op === "*") { emitInst(s, raiserABC(RaiserOpcode.MulI64, dest, lReg, rReg)); }
	else if (op === "/") { emitInst(s, raiserABC(RaiserOpcode.DivI64, dest, lReg, rReg)); }
	else if (op === "%") { emitInst(s, raiserABC(RaiserOpcode.ModI64, dest, lReg, rReg)); }
	else {
		emitLoadConst(s, dest, raiserInt(0));
	}
	return dest;
}

// --- Unary ---

function compileUnaryExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as UnaryExprData;
	const srcReg = compileExpr(s, d.operand);
	const dest = allocReg(s);
	if (d.unaryOp === "-") {
		emitInst(s, raiserABC(RaiserOpcode.NegI64, dest, srcReg, 0));
	} else {
		emitInst(s, raiserABC(RaiserOpcode.Move, dest, srcReg, 0));
	}
	return dest;
}

// --- Call ---

function compileCallExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as CallExprData;
	if (isConsoleLog(d.callee)) {
		const args = d.arguments;
		let lastReg = 0;
		let i = 0;
		while (i < args.length) {
			lastReg = compileExpr(s, args[i]);
			emitInst(s, raiserABC(RaiserOpcode.Print, lastReg, 0, 0));
			i = i + 1;
		}
		return lastReg;
	}
	// Unsupported calls return 0
	const reg = allocReg(s);
	emitLoadConst(s, reg, raiserInt(0));
	return reg;
}

function isConsoleLog(node: Node): boolean {
	if (node.kind !== NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	if (d.property !== "log") return false;
	if (d.object.kind !== NodeKind.Identifier) return false;
	const obj = d.object.data as IdentifierData;
	return obj.name === "console";
}
