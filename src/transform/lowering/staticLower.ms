import {
	Node, NodeKind, createNodeAt, ClassDeclData, ActorDeclData, PropertyDeclData, BlockStmtData,
	ExportDeclData, DecoratedDeclData, ExprStmtData, Symbol, SymbolFlag,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkExpandBlocks } from "../walker";
import { literalTakesType } from "../coercion/constantFolding";
import { makeAssign, makeMember, makeIdentResolved, makeIdent, makeExprStmt } from "../util";
import { parseInput, getStmts } from "../testUtil";

function isDataInitLiteral(init: Node): boolean {
	return init.kind == NodeKind.NumberLiteral
		|| init.kind == NodeKind.StringLiteral
		|| init.kind == NodeKind.BooleanLiteral;
}
function isInlinedReadonlyScalar(declNode: Node, ownerName: string, member: Node): boolean {
	if (member.kind != NodeKind.PropertyDecl) return false;
	const d = member.data as PropertyDeclData;
	if (!d.propIsStatic || !d.propIsReadonly || d.propInitializer == null) return false;
	const sym = staticFieldSym(declNode.resolvedSym, ownerName + "." + d.propName);
	if (sym == null || sym.symFlags.has(SymbolFlag.Mutable)) return false;
	return literalTakesType(d.propInitializer, member.nodeType);
}


function staticFieldSym(ownerSym: Symbol | null, qualifiedName: string): Symbol {
	if (ownerSym == null) return null as unknown as Symbol;
	for (const sf of ownerSym!.staticFields) {
		if (sf.name == qualifiedName) return sf;
	}
	return null as unknown as Symbol;
}

function staticFieldAssignment(declNode: Node, ownerName: string, member: Node): Node {
	const pd = member.data as PropertyDeclData;
	if (pd.propInitializer.nodeType == null && member.nodeType != null) {
		pd.propInitializer.nodeType = member.nodeType;
	}
	const ownerSym = declNode.resolvedSym;
	const receiver = ownerSym != null ? makeIdentResolved(ownerSym, member.location) : makeIdent(ownerName, member.location);
	const target = makeMember(receiver, pd.propName, member.location);
	target.resolvedSym = staticFieldSym(ownerSym, ownerName + "." + pd.propName);
	if (member.nodeType != null) { target.nodeType = member.nodeType; }
	const assign = makeAssign(target, pd.propInitializer, member.location);
	pd.propInitializer = null as unknown as Node;
	return makeExprStmt(assign, member.location);
}

function bareMember(member: Node): Node {
	if (member.kind == NodeKind.DecoratedDecl) {
		const dd = member.data as DecoratedDeclData;
		if (dd.decoratedNode != null) return dd.decoratedNode;
	}
	return member;
}

function staticRunBlock(declNode: Node, stmts: Node[]): Node {
	return createNodeAt(NodeKind.BlockStmt, { statements: stmts }, declNode.location);
}

function lowerBodyStaticsInPlace(declNode: Node, ownerName: string, body: Node[], out: Node[]): void {
	let write: int32 = 0;
	for (let read: int32 = 0; read < body.length; read += 1) {
		const m = body[read];
		if (m.kind == NodeKind.BlockStmt) {
			out.push(staticRunBlock(declNode, (m.data as BlockStmtData).statements));
			continue;
		}
		const member = bareMember(m);
		if (m.kind == NodeKind.PropertyDecl && isInlinedReadonlyScalar(declNode, ownerName, member)) continue;
		body[write] = m;
		write += 1;
		if (member.kind != NodeKind.PropertyDecl) continue;
		const pd = member.data as PropertyDeclData;
		if (!pd.propIsStatic || pd.propInitializer == null) continue;
		if (isDataInitLiteral(pd.propInitializer)) continue;
		const assign: Node[] = [staticFieldAssignment(declNode, ownerName, member)];
		out.push(staticRunBlock(declNode, assign));
	}
	body.length = write;
}

function expandClassStmt(stmt: Node, ctx: TransformContext): Node[] {
	let target = stmt;
	if (target.kind == NodeKind.ExportDecl) {
		target = (target.data as ExportDeclData).exportedDecl;
	}
	if (target == null) return [stmt];
	const out: Node[] = [stmt];
	if (target.kind == NodeKind.ClassDecl) {
		const cd = target.data as ClassDeclData;
		lowerBodyStaticsInPlace(target, cd.className, cd.classBody, out);
	} else if (target.kind == NodeKind.ActorDecl) {
		const ad = target.data as ActorDeclData;
		lowerBodyStaticsInPlace(target, ad.actorName, ad.actorBody, out);
	}
	return out;
}

export function lowerStaticInit(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandClassStmt, ctx);
	return program;
}

// ===== Tests =====

function loweredKinds(input: string): string {
	const result = parseInput(input);
	if (!result.ok) return "PARSE_ERROR";
	const prog = lowerStaticInit(result.value, null as unknown as TransformContext);
	let out = "";
	for (const s of getStmts(prog)) {
		out = out + (s.kind == NodeKind.ClassDecl ? "class," : "stmt,");
	}
	return out;
}

test "a computed static initializer leaves the class body" {
	assert loweredKinds("function f(): int32 { return 1; }\nclass K { static a: int32 = f(); }") == "stmt,class,stmt,";
}

test "a literal static initializer keeps the data-init path" {
	assert loweredKinds("class K { static a: int32 = 1; }") == "class,";
}

test "a static block becomes statements after the class" {
	assert loweredKinds("class K { static a: int32 = 1;\n\tstatic { K.a = 2; } }") == "class,stmt,";
}

test "static statements follow class-body order" {
	const result = parseInput("function f(): int32 { return 1; }\nclass K { static { K.b = 0; }\n\tstatic a: int32 = f(); }");
	assert result.ok;
	const prog = lowerStaticInit(result.value, null as unknown as TransformContext);
	const stmts = getStmts(prog);
	assert stmts.length == 4;
	assert stmts[2].kind == NodeKind.BlockStmt;
	assert stmts[3].kind == NodeKind.BlockStmt;
	const fieldUnit = (stmts[3].data as BlockStmtData).statements;
	assert fieldUnit.length == 1;
	assert (fieldUnit[0].data as ExprStmtData).expr.kind == NodeKind.BinaryExpr;
}
