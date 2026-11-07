// A `typeof` test on a parameter typed by a type parameter is decided for each instance, as a trait
// `when` is (docs/LANG.md §when): an instance whose binding is one concrete type keeps only the branch
// that type takes. A union binding keeps the test at run time, and so does a test no member of the
// constraint can pass, so the instance still reports the branch that reads a never.

import { Node, NodeKind, FunctionDeclData, IfStmtData, ConditionalExprData, BinaryExprData, UnaryExprData, IdentifierData, StringLiteralData, BlockStmtData, VariableDeclData, ArrowFunctionData, FunctionExprData, TryCatchStmtData, ForOfStmtData, Type, TypeKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { typeofTagOf, isMaybeType, peelTransparentInstance } from "./types";

const UNDECIDED: int32 = -1;

interface TypeTest {
	tag: string;
	reachable: string[] | null;
}

export function decideInstanceTypeTests(generic: Node, clone: Node, names: string[], params: Type[], types: Type[]): void {
	if (generic.kind != NodeKind.FunctionDecl || clone.kind != NodeKind.FunctionDecl) return;
	const gd = generic.data as FunctionDeclData;
	decideParameterTypeTests(gd.params, gd.fnParamTypes, (clone.data as FunctionDeclData).fnBody, names, params, types);
}

export function decideParameterTypeTests(paramNames: string[], paramTypes: string[], body: Node | null, names: string[], params: Type[], types: Type[]): void {
	const tags = new Map<string, TypeTest>();
	for (let i = 0; i < paramNames.length && i < paramTypes.length; i += 1) {
		const at = names.indexOf(paramTypes[i].trim());
		if (at < 0 || at >= types.length) continue;
		const tag = decidedTag(types[at]);
		if (tag != "") tags.set(paramNames[i], { tag, reachable: at < params.length ? constraintTags(params[at].typeExtra) : null });
	}
	if (tags.size == 0 || body == null) return;
	forgetRedeclared(body, tags);
	if (tags.size > 0) decideIn(body, tags);
}

function decidedTag(t: Type): string {
	const v = peelTransparentInstance(t);
	if (v.kind == TypeKind.Union || v.kind == TypeKind.Unknown || v.kind == TypeKind.Inferred
		|| v.kind == TypeKind.GenericParam || v.kind == TypeKind.Error || isMaybeType(v)) return "";
	return typeofTagOf(v);
}

function constraintTags(constraint: Type | null): string[] | null {
	if (constraint == null) return null;
	const v = peelTransparentInstance(constraint);
	const members = v.kind == TypeKind.Union ? v.typeChildren : [v];
	const out: string[] = [];
	for (const m of members) {
		if (m == null) continue;
		const tag = decidedTag(m);
		if (tag == "") return null;
		if (!out.includes(tag)) out.push(tag);
	}
	return out;
}

function forgetRedeclared(node: Node, tags: Map<string, TypeTest>): void {
	for (const name of declaredNames(node)) tags.delete(name);
	forEachChild(node, (child: Node): void => { forgetRedeclared(child, tags); });
}

function declaredNames(node: Node): string[] {
	return match (node.kind) {
		NodeKind.VariableDecl => [(node.data as VariableDeclData).declName],
		NodeKind.ArrowFunction => (node.data as ArrowFunctionData).arrowParams,
		NodeKind.FunctionExpr => (node.data as FunctionExprData).funcExprParams,
		NodeKind.FunctionDecl => (node.data as FunctionDeclData).params,
		NodeKind.TryCatchStmt => [(node.data as TryCatchStmtData).catchName],
		NodeKind.ForOfStmt => [(node.data as ForOfStmtData).forOfBinding],
		_ => [],
	};
}

function decideIn(node: Node, tags: Map<string, TypeTest>): void {
	if (node.kind == NodeKind.BlockStmt) {
		decideStatements((node.data as BlockStmtData).statements, tags);
		return;
	}
	if (node.kind == NodeKind.IfStmt && takeIfBranch(node, tags)) {
		decideIn(node, tags);
		return;
	}
	if (node.kind == NodeKind.ConditionalExpr && takeTernaryBranch(node, tags)) {
		decideIn(node, tags);
		return;
	}
	forEachChild(node, (child: Node): void => { decideIn(child, tags); });
}

function decideStatements(stmts: Node[], tags: Map<string, TypeTest>): void {
	let i = 0;
	while (i < stmts.length) {
		const s = stmts[i];
		const decided = s.kind == NodeKind.IfStmt && takeIfBranch(s, tags);
		decideIn(s, tags);
		if (decided && alwaysExits(s)) {
			stmts.shrink(i + 1);
			return;
		}
		i += 1;
	}
}

function takeIfBranch(node: Node, tags: Map<string, TypeTest>): boolean {
	const d = node.data as IfStmtData;
	const value = testValue(d.condition, tags);
	if (value == UNDECIDED) return false;
	const picked = value == 1 ? d.consequent : d.alternate;
	if (picked == null) {
		becomeEmptyBlock(node);
	} else {
		becomeNode(node, picked);
	}
	return true;
}

function takeTernaryBranch(node: Node, tags: Map<string, TypeTest>): boolean {
	const d = node.data as ConditionalExprData;
	const value = testValue(d.ternaryCondition, tags);
	if (value == UNDECIDED) return false;
	becomeNode(node, value == 1 ? d.ternaryConsequent : d.ternaryAlternate);
	return true;
}

function becomeNode(node: Node, picked: Node): void {
	node.kind = picked.kind;
	node.data = picked.data;
	node.location = picked.location;
	node.flags = picked.flags;
	node.typeExpr = picked.typeExpr;
	node.typeExprs = picked.typeExprs;
}

function becomeEmptyBlock(node: Node): void {
	node.kind = NodeKind.BlockStmt;
	node.data = { statements: [] } as BlockStmtData;
}

function alwaysExits(node: Node): boolean {
	return match (node.kind) {
		NodeKind.ReturnStmt | NodeKind.ThrowStmt => true,
		NodeKind.BlockStmt => {
			const stmts = (node.data as BlockStmtData).statements;
			return stmts.length > 0 && alwaysExits(stmts[stmts.length - 1]);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return d.alternate != null && alwaysExits(d.consequent) && alwaysExits(d.alternate);
		},
		_ => false,
	};
}

function testValue(cond: Node, tags: Map<string, TypeTest>): int32 {
	if (cond.kind == NodeKind.UnaryExpr) {
		const u = cond.data as UnaryExprData;
		if (u.unaryOp != "!") return UNDECIDED;
		const v = testValue(u.operand, tags);
		return v == UNDECIDED ? v : 1 - v;
	}
	if (cond.kind != NodeKind.BinaryExpr) return UNDECIDED;
	const b = cond.data as BinaryExprData;
	if (b.operator == "&&" || b.operator == "||") {
		const l = testValue(b.left, tags);
		if (b.operator == "&&" && l == 0) return 0;
		if (b.operator == "||" && l == 1) return 1;
		const r = testValue(b.right, tags);
		if (l == UNDECIDED || r == UNDECIDED) return UNDECIDED;
		return b.operator == "&&" ? l * r : (l + r > 0 ? 1 : 0);
	}
	const equal = b.operator == "==" || b.operator == "===";
	if (!equal && b.operator != "!=" && b.operator != "!==") return UNDECIDED;
	const test = testedParam(b.left, tags) != null ? testedParam(b.left, tags) : testedParam(b.right, tags);
	const literal = b.left.kind == NodeKind.StringLiteral ? b.left : b.right;
	if (test == null || literal.kind != NodeKind.StringLiteral) return UNDECIDED;
	const asked = (literal.data as StringLiteralData).value;
	if (test.reachable != null && !test.reachable.includes(asked)) return UNDECIDED;
	return (asked == test.tag) == equal ? 1 : 0;
}

function testedParam(node: Node, tags: Map<string, TypeTest>): TypeTest | null {
	if (node.kind != NodeKind.UnaryExpr) return null;
	const u = node.data as UnaryExprData;
	if (u.unaryOp != "typeof" || u.operand.kind != NodeKind.Identifier) return null;
	const test = tags.get((u.operand.data as IdentifierData).name);
	return test != null ? test : null;
}
