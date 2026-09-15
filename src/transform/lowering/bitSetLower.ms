import { Node, NodeKind, NodeData, BinaryExprData, CallExprData, UnaryExprData, TypeAssertionData, NumberLiteralData, VariableDeclData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData, BlockStmtData, Type, TypeKind, SourceLocation, createNodeAt } from "../../ast/node";
import { bitSetElemType, setRepr, booleanType, createPrimitive } from "../../checker/types";
import { addError } from "../../checker/context";
import { TransformContext, freshTempSym } from "../context";
import { walkNode, walkExpandBlocks, replaceInExpr } from "../walker";
import { makeBinary, makeUnary, makeNumber, makeIdent, makeIdentResolved, makeArrayAccess, makeCall, makeConditional, makeVarDecl, makeBlock, makeIf, makeBreak, makeBool } from "../util";
import { cloneIfPure } from "../coercion/intArithJS";
import { DeclKind } from "../../ast/node";

function byteType(): Type { return createPrimitive(TypeKind.Uint8); }
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

function isSetArgOp(name: string): boolean {
	return name == "SetUnion" || name == "SetIntersection" || name == "SetDifference"
		|| name == "SetSymmetricDifference" || name == "SetIsSubsetOf"
		|| name == "SetIsSupersetOf" || name == "SetIsDisjointFrom";
}

function setWordOperator(name: string): string {
	if (name == "SetUnion") return "|";
	if (name == "SetIntersection" || name == "SetDifference") return "&";
	if (name == "SetSymmetricDifference") return "^";
	return "";
}

function complementOf(operand: Node, t: Type, loc: SourceLocation): Node {
	const c = makeUnary("~", operand, loc);
	c.nodeType = t;
	return c;
}

function isZero(expr: Node, t: Type, loc: SourceLocation): Node {
	return typedBinary(expr, "==", typedNumber(0, t, loc), booleanType(), loc);
}

function lowerWordCall(node: Node, name: string, recv: Node, repr: Type): Node {
	const d = node.data as CallExprData;
	const loc = node.location;
	if (name == "SetIsEmpty" && d.arguments.length == 1) {
		return typedBinary(recv, "==", typedNumber(0, repr, loc), booleanType(), loc);
	}
	if (name == "SetSize" && d.arguments.length == 1) return lowerWordCard(recv, repr, loc);
	if (name == "SetHash" && d.arguments.length == 1) return lowerWordHash(recv, repr, loc);
	if (d.arguments.length != 2) return node;
	if (isSetArgOp(name)) return lowerWordSetOp(node, name, recv, d.arguments[1], repr, loc);
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

function cardCall(word: Node, loc: SourceLocation): Node {
	const call = makeCall(makeIdent("msSetCard32", loc), [word], loc);
	call.nodeType = int32Type();
	return call;
}

function asUint32(operand: Node, loc: SourceLocation): Node {
	const cast = createNodeAt(NodeKind.TypeAssertion, { asExpr: operand, asType: "uint32" } as NodeData, loc);
	cast.nodeType = createPrimitive(TypeKind.Uint32);
	return cast;
}

function hashWordInto(acc: Node, word: Node, loc: SourceLocation): Node {
	const call = makeCall(makeIdent("msSetHashWord", loc), [acc, word], loc);
	call.nodeType = createPrimitive(TypeKind.Int64);
	return call;
}

function foldWordHashes(words: Node[], loc: SourceLocation): Node {
	let acc = typedNumber(0, createPrimitive(TypeKind.Int64), loc);
	for (const word of words) acc = hashWordInto(acc, word, loc);
	return acc;
}

function lowerWordHash(recv: Node, repr: Type, loc: SourceLocation): Node {
	if (repr.kind != TypeKind.Uint64) return foldWordHashes([recv], loc);
	const shifted = typedBinary(recv, ">>", typedNumber(32, int32Type(), loc), repr, loc);
	return foldWordHashes([asUint32(recv, loc), asUint32(shifted, loc)], loc);
}

function lowerWordCard(recv: Node, repr: Type, loc: SourceLocation): Node {
	if (repr.kind != TypeKind.Uint64) return cardCall(recv, loc);
	const low = cardCall(asUint32(recv, loc), loc);
	const shifted = typedBinary(recv, ">>", typedNumber(32, int32Type(), loc), repr, loc);
	const high = cardCall(asUint32(shifted, loc), loc);
	return typedBinary(low, "+", high, int32Type(), loc);
}

function lowerWordSetOp(node: Node, name: string, recv: Node, other: Node, repr: Type, loc: SourceLocation): Node {
	const setType = recv.nodeType;
	const op = setWordOperator(name);
	if (op != "") {
		const right = name == "SetDifference" ? complementOf(other, repr, loc) : other;
		return typedBinary(recv, op, right, setType, loc);
	}
	if (name == "SetIsSubsetOf") return isZero(typedBinary(recv, "&", complementOf(other, repr, loc), repr, loc), repr, loc);
	if (name == "SetIsSupersetOf") return isZero(typedBinary(other, "&", complementOf(recv, repr, loc), repr, loc), repr, loc);
	if (name == "SetIsDisjointFrom") return isZero(typedBinary(recv, "&", other, repr, loc), repr, loc);
	return node;
}

// ===== array class (SizedArray<uint8, N>) — the reference's ctArray branch =====

function wordCount(repr: Type): int32 { return repr.typeValue; }

function wordAtIndex(recv: Node, index: Node, loc: SourceLocation): Node {
	const r = cloneIfPure(recv);
	if (r == null) return null as unknown as Node;
	const access = makeArrayAccess(r, index, loc);
	access.nodeType = byteType();
	return access;
}

function wordAt(recv: Node, i: int32, loc: SourceLocation): Node {
	return wordAtIndex(recv, typedNumber(i, int32Type(), loc), loc);
}

function memberWordIndex(member: Node, loc: SourceLocation): Node {
	const m = cloneIfPure(member);
	if (m == null) return null as unknown as Node;
	return typedBinary(m, ">>", typedNumber(3, int32Type(), loc), int32Type(), loc);
}

function memberBitInWord(member: Node, loc: SourceLocation): Node {
	const m = cloneIfPure(member);
	if (m == null) return null as unknown as Node;
	const offset = typedBinary(m, "&", typedNumber(7, int32Type(), loc), int32Type(), loc);
	return typedBinary(typedNumber(1, byteType(), loc), "<<", offset, byteType(), loc);
}

function memberBit(member: Node, i: int32, loc: SourceLocation): Node {
	const inWord = typedBinary(memberWordIndex(member, loc), "==", typedNumber(i, int32Type(), loc), booleanType(), loc);
	const picked = makeConditional(inWord, memberBitInWord(member, loc), typedNumber(0, byteType(), loc), loc);
	picked.nodeType = byteType();
	return picked;
}

function wordOf(operand: Node, i: int32, loc: SourceLocation): Node {
	if (isSetOperand(operand)) return wordAt(operand, i, loc);
	return memberBit(operand, i, loc);
}

function arrayLiteral(elements: Node[], t: Type | null, loc: SourceLocation): Node {
	const lit = createNodeAt(NodeKind.ArrayLiteral, { elements } as NodeData, loc);
	lit.nodeType = t;
	return lit;
}

function lowerArrayCall(node: Node, name: string, recv: Node, repr: Type): Node {
	const d = node.data as CallExprData;
	const loc = node.location;
	const n = wordCount(repr);
	if (name == "SetIsEmpty" && d.arguments.length == 1) {
		let acc = wordAt(recv, 0, loc);
		for (let i = 1; i < n; i += 1) acc = typedBinary(acc, "|", wordAt(recv, i, loc), byteType(), loc);
		return typedBinary(acc, "==", typedNumber(0, byteType(), loc), booleanType(), loc);
	}
	if (name == "SetHash" && d.arguments.length == 1) {
		const words: Node[] = [];
		for (let i = 0; i < n; i += 1) words.push(wordAt(recv, i, loc));
		return foldWordHashes(words, loc);
	}
	if (name == "SetSize" && d.arguments.length == 1) {
		let total = cardCall(wordAt(recv, 0, loc), loc);
		for (let i = 1; i < n; i += 1) total = typedBinary(total, "+", cardCall(wordAt(recv, i, loc), loc), int32Type(), loc);
		return total;
	}
	if (d.arguments.length != 2) return node;
	const member = d.arguments[1];
	if (isSetArgOp(name)) return lowerArraySetOp(node, name, recv, member, repr, loc);
	if (name == "SetHas") {
		const word = wordAtIndex(recv, memberWordIndex(member, loc), loc);
		const masked = typedBinary(word, "&", memberBitInWord(member, loc), byteType(), loc);
		return typedBinary(masked, "!=", typedNumber(0, byteType(), loc), booleanType(), loc);
	}
	if (name == "SetIncl" || name == "SetExcl") {
		const elements: Node[] = [];
		for (let i = 0; i < n; i += 1) {
			const bit = memberBit(member, i, loc);
			if (name == "SetIncl") {
				elements.push(typedBinary(wordAt(recv, i, loc), "|", bit, byteType(), loc));
			} else {
				const cleared = makeUnary("~", bit, loc);
				cleared.nodeType = byteType();
				elements.push(typedBinary(wordAt(recv, i, loc), "&", cleared, byteType(), loc));
			}
		}
		return arrayLiteral(elements, repr, loc);
	}
	return node;
}

function arrayPredicateWord(name: string, recv: Node, other: Node, i: int32, loc: SourceLocation): Node {
	const t = byteType();
	if (name == "SetIsSupersetOf") return isZero(typedBinary(wordAt(other, i, loc), "&", complementOf(wordAt(recv, i, loc), t, loc), t, loc), t, loc);
	if (name == "SetIsDisjointFrom") return isZero(typedBinary(wordAt(recv, i, loc), "&", wordAt(other, i, loc), t, loc), t, loc);
	return isZero(typedBinary(wordAt(recv, i, loc), "&", complementOf(wordAt(other, i, loc), t, loc), t, loc), t, loc);
}

function lowerArraySetOp(node: Node, name: string, recv: Node, other: Node, repr: Type, loc: SourceLocation): Node {
	const n = wordCount(repr);
	const op = setWordOperator(name);
	if (op != "") {
		const elements: Node[] = [];
		for (let i = 0; i < n; i += 1) {
			const right = name == "SetDifference"
				? complementOf(wordAt(other, i, loc), byteType(), loc)
				: wordAt(other, i, loc);
			elements.push(typedBinary(wordAt(recv, i, loc), op, right, byteType(), loc));
		}
		return arrayLiteral(elements, repr, loc);
	}
	let acc = arrayPredicateWord(name, recv, other, 0, loc);
	for (let i = 1; i < n; i += 1) {
		acc = typedBinary(acc, "&&", arrayPredicateWord(name, recv, other, i, loc), booleanType(), loc);
	}
	return acc;
}

function lowerArrayBinary(node: Node, repr: Type): Node {
	const d = node.data as BinaryExprData;
	const loc = node.location;
	const n = wordCount(repr);
	if (isSetBinaryOp(d.operator)) {
		const elements: Node[] = [];
		for (let i = 0; i < n; i += 1) {
			elements.push(typedBinary(wordOf(d.left, i, loc), d.operator, wordOf(d.right, i, loc), byteType(), loc));
		}
		return arrayLiteral(elements, repr, loc);
	}
	if (d.operator == "==" || d.operator == "!=") {
		let acc = typedBinary(wordAt(d.left, 0, loc), "==", wordAt(d.right, 0, loc), booleanType(), loc);
		for (let i = 1; i < n; i += 1) {
			const same = typedBinary(wordAt(d.left, i, loc), "==", wordAt(d.right, i, loc), booleanType(), loc);
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
	for (let i = 0; i < wordCount(repr); i += 1) elements.push(typedNumber(0, byteType(), node.location));
	return arrayLiteral(elements, repr, node.location);
}

// ===== dispatch =====

function lowerCall(node: Node): Node {
	const d = node.data as CallExprData;
	if (d.arguments.length == 0) return node;
	const recv = d.arguments[0];
	if (!isSetOperand(recv)) return node;
	const repr = setRepr(recv.nodeType);
	if (repr == null) return node;
	const name = setOpName(d.callee);
	if (name == "") return node;
	if (repr.kind == TypeKind.SizedArray) return lowerArrayCall(node, name, recv, repr);
	return lowerWordCall(node, name, recv, repr);
}

function lowerBinary(node: Node): Node {
	const d = node.data as BinaryExprData;
	if (isSetBinaryOp(d.operator)) {
		if (bitSetElemType(node.nodeType) == null) return node;
		const repr = setRepr(node.nodeType);
		if (repr == null) return node;
		if (repr.kind == TypeKind.SizedArray) return lowerArrayBinary(node, repr);
		return lowerWordBinary(node, repr);
	}
	if (d.operator == "==" || d.operator == "!=") {
		const repr = arrayRepr(d.left.nodeType);
		if (repr == null || arrayRepr(d.right.nodeType) == null) return node;
		return lowerArrayBinary(node, repr);
	}
	return node;
}

function lowerNode(node: Node): Node {
	if (node.kind == NodeKind.CallExpr) return lowerCall(node);
	if (node.kind == NodeKind.BinaryExpr) return lowerBinary(node);
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
	return walkNode(program, (n: Node): Node => { return lowerNode(n); });
}
