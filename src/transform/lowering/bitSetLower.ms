import { Node, NodeKind, NodeData, BinaryExprData, CallExprData, UnaryExprData, TypeAssertionData, NumberLiteralData, VariableDeclData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData, BlockStmtData, Type, TypeKind, SourceLocation, createNodeAt } from "../../ast/node";
import { bitSetElemType, setRepr, booleanType, createPrimitive } from "../../checker/types";
import { addError } from "../../checker/context";
import { TransformContext, freshTempSym } from "../context";
import { walkNode, walkExpandBlocks, replaceInExpr } from "../walker";
import { makeBinary, makeUnary, makeNumber, makeCall, makeIdent, makeIdentResolved, makeArrayAccess, makeConditional, makeVarDecl, makeBlock, makeIf, makeBreak, makeBool } from "../util";
import { cloneIfPure } from "../coercion/intArithJS";
import { DeclKind } from "../../ast/node";

function uint32Type(): Type { return createPrimitive(TypeKind.Uint32); }
function int32Type(): Type { return createPrimitive(TypeKind.Int32); }

function typedNumber(val: number, t: Type, loc: SourceLocation): Node {
	const n = makeNumber(val, loc);
	n.nodeType = t;
	return n;
}

function typedBinary(left: Node, op: string, right: Node, t: Type | null, loc: SourceLocation): Node {
	const n = makeBinary(left, op, right, loc);
	n.nodeType = t;
	return n;
}

function shiftMember(operand: Node, repr: Type): Node {
	const one = typedNumber(1, repr, operand.location);
	return typedBinary(one, "<<", operand, repr, operand.location);
}

function isEnumOperand(n: Node | null): boolean {
	return n != null && n.nodeType != null && n.nodeType.kind == TypeKind.Enum;
}

function isSetOperand(n: Node | null): boolean {
	return n != null && bitSetElemType(n.nodeType) != null;
}

function arrayRepr(t: Type | null): Type | null {
	if (bitSetElemType(t) == null) return null;
	const repr = setRepr(t);
	if (repr == null || repr.kind != TypeKind.SizedArray) return null;
	return repr;
}

function setOpName(sym: Node): string {
	if (sym.kind != NodeKind.Identifier || sym.resolvedSym == null) return "";
	return sym.resolvedSym.builtinKind;
}

function isSetBinaryOp(op: string): boolean {
	return op == "|" || op == "&" || op == "^";
}

// ===== word class (uint32 / uint64) =====

function lowerWordCall(node: Node, name: string, recv: Node, repr: Type): Node {
	const d = node.data as CallExprData;
	const loc = node.location;
	if (name == "SetIsEmpty" && d.arguments.length == 1) {
		return typedBinary(recv, "==", typedNumber(0, repr, loc), booleanType(), loc);
	}
	if (d.arguments.length != 2) return node;
	const bit = shiftMember(d.arguments[1], repr);
	if (name == "SetHas") {
		const masked = typedBinary(recv, "&", bit, repr, loc);
		return typedBinary(masked, "!=", typedNumber(0, repr, loc), booleanType(), loc);
	}
	if (name == "SetIncl") return typedBinary(recv, "|", bit, recv.nodeType, loc);
	if (name == "SetExcl") {
		const cleared = makeUnary("~", bit, loc);
		cleared.nodeType = repr;
		return typedBinary(recv, "&", cleared, recv.nodeType, loc);
	}
	return node;
}

function lowerWordBinary(node: Node, repr: Type): Node {
	const d = node.data as BinaryExprData;
	if (isEnumOperand(d.left)) { d.left = shiftMember(d.left, repr); }
	if (isEnumOperand(d.right)) { d.right = shiftMember(d.right, repr); }
	return node;
}

// ===== array class (SizedArray<uint32, N>) — the reference's ctArray branch =====

function wordCount(repr: Type): int32 { return repr.typeFlags; }

function wordAtIndex(recv: Node, index: Node, repr: Type, ctx: TransformContext, loc: SourceLocation): Node {
	const r = cloneIfPure(recv);
	if (r == null) return null as unknown as Node;
	if (ctx.jsBackend) {
		const access = makeArrayAccess(r, index, loc);
		access.nodeType = uint32Type();
		return access;
	}
	const call = makeCall(makeIdent("msSizedArrayAccess", loc), [r, index, typedNumber(wordCount(repr), int32Type(), loc)], loc);
	call.nodeType = uint32Type();
	return call;
}

function wordAt(recv: Node, i: int32, repr: Type, ctx: TransformContext, loc: SourceLocation): Node {
	return wordAtIndex(recv, typedNumber(i, int32Type(), loc), repr, ctx, loc);
}

function memberWordIndex(member: Node, loc: SourceLocation): Node {
	const m = cloneIfPure(member);
	if (m == null) return null as unknown as Node;
	return typedBinary(m, ">>", typedNumber(5, int32Type(), loc), int32Type(), loc);
}

function memberBitInWord(member: Node, loc: SourceLocation): Node {
	const m = cloneIfPure(member);
	if (m == null) return null as unknown as Node;
	const offset = typedBinary(m, "&", typedNumber(31, int32Type(), loc), int32Type(), loc);
	return typedBinary(typedNumber(1, uint32Type(), loc), "<<", offset, uint32Type(), loc);
}

function memberBit(member: Node, i: int32, loc: SourceLocation): Node {
	const inWord = typedBinary(memberWordIndex(member, loc), "==", typedNumber(i, int32Type(), loc), booleanType(), loc);
	const picked = makeConditional(inWord, memberBitInWord(member, loc), typedNumber(0, uint32Type(), loc), loc);
	picked.nodeType = uint32Type();
	return picked;
}

function wordOf(operand: Node, i: int32, repr: Type, ctx: TransformContext, loc: SourceLocation): Node {
	if (isSetOperand(operand)) return wordAt(operand, i, repr, ctx, loc);
	return memberBit(operand, i, loc);
}

function arrayLiteral(elements: Node[], t: Type | null, loc: SourceLocation): Node {
	const lit = createNodeAt(NodeKind.ArrayLiteral, { elements } as NodeData, loc);
	lit.nodeType = t;
	return lit;
}

function lowerArrayCall(node: Node, name: string, recv: Node, repr: Type, ctx: TransformContext): Node {
	const d = node.data as CallExprData;
	const loc = node.location;
	const n = wordCount(repr);
	if (name == "SetIsEmpty" && d.arguments.length == 1) {
		let acc = wordAt(recv, 0, repr, ctx, loc);
		for (let i = 1; i < n; i += 1) acc = typedBinary(acc, "|", wordAt(recv, i, repr, ctx, loc), uint32Type(), loc);
		return typedBinary(acc, "==", typedNumber(0, uint32Type(), loc), booleanType(), loc);
	}
	if (d.arguments.length != 2) return node;
	const member = d.arguments[1];
	if (name == "SetHas") {
		const word = wordAtIndex(recv, memberWordIndex(member, loc), repr, ctx, loc);
		const masked = typedBinary(word, "&", memberBitInWord(member, loc), uint32Type(), loc);
		return typedBinary(masked, "!=", typedNumber(0, uint32Type(), loc), booleanType(), loc);
	}
	if (name == "SetIncl" || name == "SetExcl") {
		const elements: Node[] = [];
		for (let i = 0; i < n; i += 1) {
			const bit = memberBit(member, i, loc);
			if (name == "SetIncl") {
				elements.push(typedBinary(wordAt(recv, i, repr, ctx, loc), "|", bit, uint32Type(), loc));
			} else {
				const cleared = makeUnary("~", bit, loc);
				cleared.nodeType = uint32Type();
				elements.push(typedBinary(wordAt(recv, i, repr, ctx, loc), "&", cleared, uint32Type(), loc));
			}
		}
		return arrayLiteral(elements, repr, loc);
	}
	return node;
}

function lowerArrayBinary(node: Node, repr: Type, ctx: TransformContext): Node {
	const d = node.data as BinaryExprData;
	const loc = node.location;
	const n = wordCount(repr);
	if (isSetBinaryOp(d.operator)) {
		const elements: Node[] = [];
		for (let i = 0; i < n; i += 1) {
			elements.push(typedBinary(wordOf(d.left, i, repr, ctx, loc), d.operator, wordOf(d.right, i, repr, ctx, loc), uint32Type(), loc));
		}
		return arrayLiteral(elements, repr, loc);
	}
	if (d.operator == "==" || d.operator == "!=") {
		let acc = typedBinary(wordAt(d.left, 0, repr, ctx, loc), "==", wordAt(d.right, 0, repr, ctx, loc), booleanType(), loc);
		for (let i = 1; i < n; i += 1) {
			const same = typedBinary(wordAt(d.left, i, repr, ctx, loc), "==", wordAt(d.right, i, repr, ctx, loc), booleanType(), loc);
			acc = typedBinary(acc, "&&", same, booleanType(), loc);
		}
		if (d.operator == "==") return acc;
		const negated = makeUnary("!", acc, loc);
		negated.nodeType = booleanType();
		return negated;
	}
	return node;
}

function lowerArrayZero(node: Node, repr: Type): Node {
	const d = node.data as TypeAssertionData;
	if (d.asExpr == null || d.asExpr.kind != NodeKind.NumberLiteral) return node;
	if ((d.asExpr.data as NumberLiteralData).intVal != 0) return node;
	const elements: Node[] = [];
	for (let i = 0; i < wordCount(repr); i += 1) elements.push(typedNumber(0, uint32Type(), node.location));
	return arrayLiteral(elements, repr, node.location);
}

// ===== dispatch =====

function lowerCall(node: Node, ctx: TransformContext): Node {
	const d = node.data as CallExprData;
	if (d.arguments.length == 0) return node;
	const recv = d.arguments[0];
	if (!isSetOperand(recv)) return node;
	const repr = setRepr(recv.nodeType);
	if (repr == null) return node;
	const name = setOpName(d.callee);
	if (name == "") return node;
	if (repr.kind == TypeKind.SizedArray) return lowerArrayCall(node, name, recv, repr, ctx);
	return lowerWordCall(node, name, recv, repr);
}

function lowerBinary(node: Node, ctx: TransformContext): Node {
	const d = node.data as BinaryExprData;
	if (isSetBinaryOp(d.operator)) {
		if (bitSetElemType(node.nodeType) == null) return node;
		const repr = setRepr(node.nodeType);
		if (repr == null) return node;
		if (repr.kind == TypeKind.SizedArray) return lowerArrayBinary(node, repr, ctx);
		return lowerWordBinary(node, repr);
	}
	if (d.operator == "==" || d.operator == "!=") {
		const repr = arrayRepr(d.left.nodeType);
		if (repr == null || arrayRepr(d.right.nodeType) == null) return node;
		return lowerArrayBinary(node, repr, ctx);
	}
	return node;
}

function lowerNode(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.CallExpr) return lowerCall(node, ctx);
	if (node.kind == NodeKind.BinaryExpr) return lowerBinary(node, ctx);
	if (node.kind == NodeKind.TypeAssertion) {
		const repr = arrayRepr(node.nodeType);
		if (repr != null) return lowerArrayZero(node, repr);
	}
	return node;
}

// ===== operand hoisting: array-class operands are read once per word =====

function isArrayOp(node: Node): boolean {
	if (node.kind == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		return d.arguments.length > 0 && arrayRepr(d.arguments[0].nodeType) != null && setOpName(d.callee) != "";
	}
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isSetBinaryOp(d.operator)) return arrayRepr(node.nodeType) != null;
		if (d.operator == "==" || d.operator == "!=") return arrayRepr(d.left.nodeType) != null;
	}
	return false;
}

function hoistOperand(operand: Node, pre: Node[], ctx: TransformContext): Node {
	if (cloneIfPure(operand) != null) return operand;
	const t = operand.nodeType;
	const sym = freshTempSym(ctx, "bitset", t);
	const decl = makeVarDecl(sym.name, operand, DeclKind.Const, operand.location);
	decl.resolvedSym = sym;
	decl.nodeType = t;
	pre.push(decl);
	const ref = makeIdentResolved(sym, operand.location);
	ref.nodeType = t;
	return ref;
}

function hoistArrayOperands(expr: Node, pre: Node[], ctx: TransformContext): Node {
	return replaceInExpr(expr, (node: Node): Node => {
		if (!isArrayOp(node)) return node;
		if (node.kind == NodeKind.CallExpr) {
			const d = node.data as CallExprData;
			for (let i = 0; i < d.arguments.length; i += 1) d.arguments[i] = hoistOperand(d.arguments[i], pre, ctx);
			return node;
		}
		const d = node.data as BinaryExprData;
		d.left = hoistOperand(d.left, pre, ctx);
		d.right = hoistOperand(d.right, pre, ctx);
		return node;
	});
}

function containsImpureArrayOp(expr: Node): boolean {
	let found = false;
	replaceInExpr(expr, (node: Node): Node => {
		if (!isArrayOp(node)) return node;
		if (node.kind == NodeKind.CallExpr) {
			for (const arg of (node.data as CallExprData).arguments) { if (cloneIfPure(arg) == null) found = true; }
		} else {
			const d = node.data as BinaryExprData;
			if (cloneIfPure(d.left) == null || cloneIfPure(d.right) == null) found = true;
		}
		return node;
	});
	return found;
}

function bodyStatements(body: Node): Node[] {
	if (body != null && body.kind == NodeKind.BlockStmt) return (body.data as BlockStmtData).statements;
	return body != null ? [body] : [];
}

function expandStmt(stmt: Node, ctx: TransformContext): Node[] {
	const pre: Node[] = [];
	if (stmt.kind == NodeKind.VariableDecl) {
		const d = stmt.data as VariableDeclData;
		if (d.initializer != null) d.initializer = hoistArrayOperands(d.initializer, pre, ctx);
	} else if (stmt.kind == NodeKind.ExprStmt) {
		const d = stmt.data as ExprStmtData;
		if (d.expr != null) d.expr = hoistArrayOperands(d.expr, pre, ctx);
	} else if (stmt.kind == NodeKind.ReturnStmt) {
		const d = stmt.data as ReturnStmtData;
		if (d.argument != null) d.argument = hoistArrayOperands(d.argument, pre, ctx);
	} else if (stmt.kind == NodeKind.IfStmt) {
		const d = stmt.data as IfStmtData;
		if (d.alternate != null && d.alternate.kind == NodeKind.IfStmt && containsImpureArrayOp((d.alternate.data as IfStmtData).condition)) {
			d.alternate = makeBlock([d.alternate], d.alternate.location);
		}
		d.condition = hoistArrayOperands(d.condition, pre, ctx);
	} else if (stmt.kind == NodeKind.WhileStmt) {
		const d = stmt.data as WhileStmtData;
		if (!containsImpureArrayOp(d.whileCondition)) return [stmt];
		const loc = stmt.location;
		const cond = hoistArrayOperands(d.whileCondition, pre, ctx);
		pre.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), null as unknown as Node, loc));
		for (const s of bodyStatements(d.whileBody)) pre.push(s);
		d.whileCondition = makeBool(true, loc);
		d.whileBody = makeBlock(pre, loc);
		return [stmt];
	}
	pre.push(stmt);
	return pre;
}

export function lowerBitSet(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandStmt, ctx);
	return walkNode(program, (n: Node): Node => { return lowerNode(n, ctx); });
}
