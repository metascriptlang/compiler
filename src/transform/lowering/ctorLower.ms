// Constructor lowering — materialize instance field initializers as
// assignments inside the constructor body.
//
// Canonical order: `super(args)` → own field initializers in declaration order
// → user constructor body. The C backend used to emit the defaults at the `new`
// site instead, which ran them BEFORE super() and never walked the parent
// chain; the JS backend dropped PropertyDecl entirely and ran them nowhere.
// Semantics are TS `[[Set]]` (assignment in the constructor), so one lowering
// serves both backends.

import {
	Node, NodeKind, ClassDeclData, PropertyDeclData, ConstructorDeclData,
	BlockStmtData, ProgramData, ExportDeclData, DecoratedDeclData,
	ExprStmtData, CallExprData, IdentifierData, FunctionDeclData,
	createNodeAt,
} from "../../ast/node";
import { TransformContext, createTransformContext } from "../context";
import { makeAssign, makeMember, makeExprStmt, makeTypedIdent, makeBlock, makeCall, makeIdent } from "../util";
import { createFunction, voidType } from "../../checker/types";
import { getCtorParamTypes, parentClassSymOf } from "../../checker/symbol";
import { lowerMethodToFunction } from "./methodToFunction";
import { parseInput, getStmts } from "../testUtil";

function fieldInitStatements(classNode: Node, cd: ClassDeclData): Node[] {
	const stmts: Node[] = [];
	for (const member of cd.classBody) {
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			if (!pd.propIsStatic && pd.propInitializer !== null) {
				// Untyped initializers (an empty array literal) codegen by their
				// declared field type, not by a guessed default.
				if (pd.propInitializer.nodeType === null && member.nodeType !== null) {
					pd.propInitializer.nodeType = member.nodeType;
				}
				const receiver = makeTypedIdent("this", classNode.nodeType, member.location);
				const target = makeMember(receiver, pd.propName, member.location);
				if (target.nodeType === null && member.nodeType !== null) {
					target.nodeType = member.nodeType;
				}
				const assign = makeAssign(target, pd.propInitializer, member.location);
				stmts.push(makeExprStmt(assign, member.location));
				// The initializer now lives in exactly one place. Leaving it on the
				// PropertyDecl too would hand later passes the same node twice.
				pd.propInitializer = null as unknown as Node;
			}
		}
	}
	return stmts;
}

function isSuperCallStmt(stmt: Node): boolean {
	if (stmt === null || stmt.kind !== NodeKind.ExprStmt) return false;
	const ed = stmt.data as ExprStmtData;
	if (ed.expr === null || ed.expr.kind !== NodeKind.CallExpr) return false;
	const call = ed.expr.data as CallExprData;
	if (call.callee === null || call.callee.kind !== NodeKind.Identifier) return false;
	return (call.callee.data as IdentifierData).name === "super";
}

function lowerCtorBody(classNode: Node, cd: ClassDeclData, ctorNode: Node): void {
	const ctorData = ctorNode.data as ConstructorDeclData;
	if (ctorData.ctorBody === null || ctorData.ctorBody.kind !== NodeKind.BlockStmt) return;
	const inits = fieldInitStatements(classNode, cd);
	if (inits.length === 0) return;
	const body = ctorData.ctorBody.data as BlockStmtData;
	let at = 0;
	if (body.statements.length > 0 && isSuperCallStmt(body.statements[0])) at = 1;
	const merged: Node[] = [];
	let i = 0;
	while (i < at) {
		merged.push(body.statements[i]);
		i += 1;
	}
	for (const s of inits) { merged.push(s); }
	while (i < body.statements.length) {
		merged.push(body.statements[i]);
		i += 1;
	}
	body.statements = merged;
}

// An implicit `super()` is only safe to synthesize when the parent constructor
// takes no arguments — there is nothing to forward otherwise. A `super`
// identifier with no resolvedSym is worse than none: both backends fall through
// to their generic call path and emit a call to an undefined symbol.
function implicitSuperStmt(classNode: Node, cd: ClassDeclData): Node {
	if (cd.classExtends === "") return null as unknown as Node;
	if (classNode.resolvedSym === null) return null as unknown as Node;
	const parentSym = parentClassSymOf(classNode.resolvedSym);
	if (parentSym === null) return null as unknown as Node;
	const parentParams = getCtorParamTypes(parentSym);
	if (parentParams !== null && parentParams.length > 0) return null as unknown as Node;
	const loc = classNode.location;
	const callee = makeIdent("super", loc);
	callee.resolvedSym = parentSym;
	const call = makeCall(callee, [], loc);
	call.nodeType = voidType();
	return makeExprStmt(call, loc);
}

function synthesizeCtor(classNode: Node, cd: ClassDeclData): void {
	const loc = classNode.location;
	const stmts: Node[] = [];
	const superStmt = implicitSuperStmt(classNode, cd);
	if (superStmt !== null) stmts.push(superStmt);
	for (const s of fieldInitStatements(classNode, cd)) { stmts.push(s); }
	const ctorNode = createNodeAt(NodeKind.ConstructorDecl, {
		ctorParams: [],
		ctorParamTypes: [],
		ctorBody: makeBlock(stmts, loc),
		ctorDefaults: [],
	}, loc);
	// methodToFunction widens typeChildren with the receiver only when a Function
	// type is already present; without it `this` lifts as void*.
	ctorNode.nodeType = createFunction([], [], voidType());
	cd.classBody.push(ctorNode);
}

function ensureImplicitSuper(classNode: Node, cd: ClassDeclData, ctorNode: Node): void {
	const ctorData = ctorNode.data as ConstructorDeclData;
	if (ctorData.ctorBody === null || ctorData.ctorBody.kind !== NodeKind.BlockStmt) return;
	const body = ctorData.ctorBody.data as BlockStmtData;
	if (body.statements.length > 0 && isSuperCallStmt(body.statements[0])) return;
	const superStmt = implicitSuperStmt(classNode, cd);
	if (superStmt === null) return;
	const merged: Node[] = [superStmt];
	for (const s of body.statements) { merged.push(s); }
	body.statements = merged;
}

function lowerClassNode(classNode: Node): void {
	const cd = classNode.data as ClassDeclData;
	let ctorNode = null as unknown as Node;
	for (const member of cd.classBody) {
		if (member.kind === NodeKind.ConstructorDecl) {
			ctorNode = member;
		} else if (member.kind === NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			if (dd.decoratedNode !== null && dd.decoratedNode.kind === NodeKind.ConstructorDecl) {
				ctorNode = dd.decoratedNode;
			}
		}
	}
	if (ctorNode === null) {
		synthesizeCtor(classNode, cd);
		return;
	}
	ensureImplicitSuper(classNode, cd, ctorNode);
	lowerCtorBody(classNode, cd, ctorNode);
}

export function lowerCtorInit(program: Node, ctx: TransformContext): Node {
	if (program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		let target = stmt;
		if (target.kind === NodeKind.ExportDecl) {
			target = (target.data as ExportDeclData).exportedDecl;
		}
		if (target !== null && target.kind === NodeKind.ClassDecl) {
			lowerClassNode(target);
		}
	}
	return program;
}

// ===== Test Helpers =====

function ctorStmtKinds(input: string): string {
	const result = parseInput(input);
	if (!result.ok) return "PARSE_ERROR";
	const prog = lowerCtorInit(result.value, null as unknown as TransformContext);
	const stmts = getStmts(prog);
	if (stmts.length === 0) return "NO_STMTS";
	const cd = stmts[0].data as ClassDeclData;
	for (const member of cd.classBody) {
		if (member.kind === NodeKind.ConstructorDecl) {
			const body = (member.data as ConstructorDeclData).ctorBody.data as BlockStmtData;
			let out = "";
			for (const s of body.statements) {
				out = out + (isSuperCallStmt(s) ? "super," : "stmt,");
			}
			return out;
		}
	}
	return "NO_CTOR";
}

function liftedInitNames(input: string): string {
	const result = parseInput(input);
	if (!result.ok) return "PARSE_ERROR";
	const ctx = createTransformContext();
	let prog = lowerCtorInit(result.value, ctx);
	prog = lowerMethodToFunction(prog, ctx);
	let out = "";
	for (const stmt of getStmts(prog)) {
		if (stmt.kind === NodeKind.FunctionDecl) {
			out = out + (stmt.data as FunctionDeclData).fnName + ",";
		}
	}
	return out;
}

function remainingInitializers(input: string): number {
	const result = parseInput(input);
	if (!result.ok) return -1;
	const prog = lowerCtorInit(result.value, null as unknown as TransformContext);
	const stmts = getStmts(prog);
	const cd = stmts[0].data as ClassDeclData;
	let n = 0;
	for (const member of cd.classBody) {
		if (member.kind === NodeKind.PropertyDecl && (member.data as PropertyDeclData).propInitializer !== null) {
			n += 1;
		}
	}
	return n;
}

// ===== Tests =====

test "field initializers move into the constructor" {
	assert ctorStmtKinds("class A { x: number = 1; constructor() { foo(); } }") === "stmt,stmt,";
}

test "field initializers land after an explicit super call" {
	assert ctorStmtKinds("class A extends B { x: number = 1; constructor() { super(); foo(); } }") === "super,stmt,stmt,";
}

test "the initializer is left in exactly one place" {
	assert remainingInitializers("class A { x: number = 1; constructor() {} }") === 0;
}

test "a static field is not moved into the constructor" {
	assert remainingInitializers("class A { static x: number = 1; constructor() {} }") === 1;
}

test "a class without a constructor gets one" {
	assert ctorStmtKinds("class A { x: number = 1; }") === "stmt,";
}

test "the synthesized constructor takes the initializer with it" {
	assert remainingInitializers("class A { x: number = 1; }") === 0;
}

test "a class with no initializers keeps its body" {
	assert ctorStmtKinds("class A { x: number; constructor() { foo(); } }") === "stmt,";
}

test "a synthesized constructor lifts to <Class>_init" {
	assert liftedInitNames("class A { x: number = 1; }") === "A_init,";
}

test "every class in a chain gets an _init to call" {
	assert liftedInitNames("class A { x: number = 1; } class B extends A { y: number = 2; }") === "A_init,B_init,";
}
