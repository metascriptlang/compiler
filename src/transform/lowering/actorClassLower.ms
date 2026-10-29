// Actor lowering for the Raiser — an `actor` becomes a class whose message methods post a
// job to the mailbox runtime in std/core/promise instead of running at once.
//
// The VM has one thread, so an actor needs no state and handle split: the instance is the
// state, `pid` is a field filled from the pid table when the instance is built, and a
// message method keeps its symbol, its parameters and its `this`, and returns the reply
// future its callers already see in its type. The body moves into a closure the mailbox
// runs one message at a time, after the sender's turn.
//
//   void method        msActorPost(this.pid, () => { body })
//
// A body that awaits runs in async closures and the mailbox waits for it before the next
// message, so a suspended actor keeps its place. `onTerminate` registers with the pid once
// the constructor exists, after the pid and before the field defaults.

import {
	Node, NodeKind, SourceLocation, createNode,
	ActorDeclData, ClassDeclData, MethodDeclData, DecoratedDeclData, ExportDeclData,
	ProgramData, BlockStmtData, ExprStmtData, BinaryExprData, MemberExprData, ConstructorDeclData,
	Symbol, SymbolKind, Type, TypeKind,
} from "../../ast/node";
import { TransformContext, newLoweredSym, freshOwnedSym } from "../context";
import { makeCall, makeBlock, makeExprStmt, makeReturn, makeMember, makeIdentResolved, makeTypedIdentResolved, makeLocalDecl, runtimeRef, syntheticToken } from "../util";
import { createFunction, createClosureType, createPromise, voidType, getSysType, isAwaitable, awaitedType } from "../../checker/types";
import { routineFlagSet, RoutineFlag } from "../../checker/symbol";
import { bodyContainsAwait } from "./actorLower";

function methodOf(member: Node): Node | null {
	if (member.kind == NodeKind.MethodDecl) return member;
	if (member.kind == NodeKind.DecoratedDecl) {
		const inner = (member.data as DecoratedDeclData).decoratedNode;
		if (inner != null && inner.kind == NodeKind.MethodDecl) return inner;
	}
	return null;
}

function isHook(name: string): boolean {
	return name == "onTerminate" || name == "onExit" || name == "onDown" || name == "onIdle";
}

function suspends(md: MethodDeclData): boolean {
	return routineFlagSet(md.methodFlags).has(RoutineFlag.Async) || bodyContainsAwait(md.methodBody);
}

function makeArrow(params: Symbol[], paramTypes: Type[], body: Node, ret: Type, isAsync: boolean, loc: SourceLocation): Node {
	const names: string[] = [];
	for (const p of params) names.push(p.name);
	const arrow = createNode(NodeKind.ArrowFunction, {
		arrowParams: names,
		arrowParamTypes: [] as string[],
		arrowBody: body,
		arrowFlags: isAsync ? "async" : "",
		arrowReturnType: "",
		arrowDefaults: [] as Node[],
	}, syntheticToken(loc));
	arrow.nodeType = createClosureType(paramTypes, names, ret);
	arrow.paramSyms = params;
	return arrow;
}

function typedCall(name: string, args: Node[], t: Type, loc: SourceLocation): Node {
	const call = makeCall(runtimeRef(name, loc), args, loc);
	call.nodeType = t;
	return call;
}

function pidOf(thisSym: Symbol, loc: SourceLocation): Node {
	const pid = makeMember(makeIdentResolved(thisSym, loc), "pid", loc);
	pid.nodeType = getSysType(TypeKind.Int64);
	return pid;
}

function proxify(method: Node, ctx: TransformContext): void {
	const md = method.data as MethodDeclData;
	const loc = method.location;
	if (method.paramSyms == null || method.paramSyms.length == 0 || method.nodeType == null) {
		throw new Error(`internal: actor method '${md.methodName}' reached lowering without its receiver symbol or its type`);
	}
	const thisSym = method.paramSyms[0];
	const declared = method.nodeType;
	const declaredRet = declared.typeReturn != null ? declared.typeReturn : voidType();
	const isVoid = md.methodReturnType == "" || md.methodReturnType == "void";
	const waits = suspends(md);
	const original = md.methodBody;
	const stmts: Node[] = [];
	if (isVoid) {
		const job = makeArrow([], [], original, waits ? createPromise(voidType()) : voidType(), waits, loc);
		stmts.push(makeExprStmt(typedCall(waits ? "msActorPostAsync" : "msActorPost", [pidOf(thisSym, loc), job], voidType(), loc), loc));
	} else {
		const held = isAwaitable(declaredRet) ? awaitedType(declaredRet)! : declaredRet;
		const promised = createPromise(held);
		const bodyRet = waits ? promised : held;
		const replySym = freshOwnedSym(ctx, "reply", promised);
		const runSym = freshOwnedSym(ctx, "run", createClosureType([], [], bodyRet));
		const ran = makeCall(makeIdentResolved(runSym, loc), [], loc);
		ran.nodeType = bodyRet;
		let value = ran;
		if (waits) {
			value = createNode(NodeKind.AwaitExpr, { awaitArg: ran }, syntheticToken(loc));
			value.nodeType = held;
		}
		const settle = typedCall("msActorReplySettle", [makeIdentResolved(replySym, loc), value], voidType(), loc);
		const job = makeArrow([], [], makeBlock([makeExprStmt(settle, loc)], loc), waits ? createPromise(voidType()) : voidType(), waits, loc);
		const post = typedCall(waits ? "msActorPostCallAsync" : "msActorPostCall", [pidOf(thisSym, loc), job, makeIdentResolved(replySym, loc)], voidType(), loc);
		stmts.push(makeLocalDecl(replySym, typedCall("msActorReplyNew", [], promised, loc), promised, loc));
		stmts.push(makeLocalDecl(runSym, makeArrow([], [], original, bodyRet, waits, loc), runSym.symbolType!, loc));
		stmts.push(makeExprStmt(post, loc));
		stmts.push(makeReturn(makeIdentResolved(replySym, loc), loc));
		const proxyType = createFunction(declared.typeChildren, declared.typeNames, promised);
		method.nodeType = proxyType;
		if (method.resolvedSym != null) method.resolvedSym.symbolType = proxyType;
		md.methodReturnType = "unknown";
	}
	md.methodBody = makeBlock(stmts, loc);
	md.methodFlags = "";
}

function addPidField(actorSym: Symbol | null): void {
	if (actorSym == null || actorSym.symbolType == null) throw new Error("internal: an actor reached lowering without its symbol type");
	const handle = actorSym.symbolType;
	const shape = handle.kind == TypeKind.Ref && handle.typeReturn != null ? handle.typeReturn : handle;
	shape.typeNames.push("pid");
	shape.typeChildren.push(getSysType(TypeKind.Int64));
}

function convert(node: Node, ctx: TransformContext): void {
	const d = node.data as ActorDeclData;
	const loc = node.location;
	const pid = createNode(NodeKind.PropertyDecl, {
		propName: "pid",
		propType: "int64",
		propIsStatic: false,
		propIsReadonly: true,
		propVisibility: "",
		propInitializer: typedCall("msActorOpen", [], getSysType(TypeKind.Int64), loc),
	}, syntheticToken(loc));
	pid.nodeType = getSysType(TypeKind.Int64);
	const body: Node[] = [pid];
	for (const member of d.actorBody) {
		const method = methodOf(member);
		if (method != null && !isHook((method.data as MethodDeclData).methodName)) proxify(method, ctx);
		body.push(member);
	}
	addPidField(node.resolvedSym);
	node.resolvedSym!.symbolKind = SymbolKind.Class;
	converted.push(node.resolvedSym!);
	node.kind = NodeKind.ClassDecl;
	node.data = {
		className: d.actorName,
		classDisplayName: d.actorName,
		classExtends: "",
		classBody: body,
		nameLocation: d.nameLocation,
		classImplements: [] as string[],
	} as ClassDeclData;
}

function declOf(stmt: Node): Node {
	if (stmt.kind == NodeKind.ExportDecl) return (stmt.data as ExportDeclData).exportedDecl;
	return stmt;
}

const converted: Symbol[] = [];

export function lowerActorClasses(program: Node, ctx: TransformContext): Node {
	if (program.kind != NodeKind.Program) return program;
	converted.shrink(0);
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = declOf(stmt);
		if (decl != null && decl.kind == NodeKind.ActorDecl) convert(decl, ctx);
	}
	return program;
}

function memberNamed(cd: ClassDeclData, kind: NodeKind, name: string): Node | null {
	for (const member of cd.classBody) {
		const method = methodOf(member);
		if (kind == NodeKind.MethodDecl && method != null && (method.data as MethodDeclData).methodName == name) return method;
		if (kind == NodeKind.ConstructorDecl && member.kind == NodeKind.ConstructorDecl) return member;
	}
	return null;
}

function isPidInit(stmt: Node): boolean {
	if (stmt.kind != NodeKind.ExprStmt) return false;
	const e = (stmt.data as ExprStmtData).expr;
	if (e == null || e.kind != NodeKind.BinaryExpr) return false;
	const left = (e.data as BinaryExprData).left;
	return left.kind == NodeKind.MemberExpr && (left.data as MemberExprData).property == "pid";
}

function registerTerminate(classNode: Node, ctx: TransformContext): void {
	const cd = classNode.data as ClassDeclData;
	const hook = memberNamed(cd, NodeKind.MethodDecl, "onTerminate");
	if (hook == null) return;
	const ctor = memberNamed(cd, NodeKind.ConstructorDecl, "");
	if (ctor == null || ctor.paramSyms == null || ctor.paramSyms.length == 0 || hook.nodeType == null || hook.resolvedSym == null) {
		throw new Error(`internal: actor '${cd.className}' reached its terminate registration without a constructor or a typed hook`);
	}
	const body = (ctor.data as ConstructorDeclData).ctorBody.data as BlockStmtData;
	if (body.statements.length == 0 || !isPidInit(body.statements[0])) {
		throw new Error(`internal: the constructor of actor '${cd.className}' does not start with its pid`);
	}
	const loc = ctor.location;
	const thisSym = ctor.paramSyms[0];
	const reasonType = hook.nodeType.typeChildren[1];
	const reasonSym = newLoweredSym(ctx, SymbolKind.Parameter, "reason", reasonType);
	const selfSym = freshOwnedSym(ctx, "self", thisSym.symbolType);
	const self = makeLocalDecl(selfSym, makeIdentResolved(thisSym, loc), thisSym.symbolType!, loc);
	const hookCall = makeCall(makeTypedIdentResolved(hook.resolvedSym, null, loc), [makeIdentResolved(selfSym, loc), makeIdentResolved(reasonSym, loc)], loc);
	hookCall.nodeType = voidType();
	const arrow = makeArrow([reasonSym], [reasonType], makeBlock([makeExprStmt(hookCall, loc)], loc), voidType(), false, loc);
	const register = makeExprStmt(typedCall("msActorOnTerminate", [pidOf(thisSym, loc), arrow], voidType(), loc), loc);
	const merged: Node[] = [body.statements[0], self, register];
	for (let i = 1; i < body.statements.length; i += 1) merged.push(body.statements[i]);
	body.statements = merged;
}

export function registerActorTerminators(program: Node, ctx: TransformContext): Node {
	if (program.kind != NodeKind.Program) return program;
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = declOf(stmt);
		if (decl != null && decl.kind == NodeKind.ClassDecl && decl.resolvedSym != null && converted.indexOf(decl.resolvedSym) >= 0) registerTerminate(decl, ctx);
	}
	return program;
}
