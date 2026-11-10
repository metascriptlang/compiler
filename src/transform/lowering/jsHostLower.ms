// JS backend: a `@jsHost` class is the host's class of the same name, as a magic type is the
// backend's own representation. Its declaration (fields, bodies) is the native backends' and the
// engine's; on JS its members are the host's: a getter reads the host property, a method or static
// calls the host member, and a constructor passes the arguments its signature takes, so the host
// applies its own defaults. A span crosses to the host as the host's array. A class over a host
// class is one the host calls back, leaving trailing arguments out, so its methods apply their own
// defaults as the TS emit does.

import { Node, NodeKind, CallExprData, MemberExprData, NewExprData, HiddenStdConvData, IdentifierData, ClassDeclData, MethodDeclData, DecoratedDeclData, BlockStmtData, Type, TypeKind, Symbol, SymbolKind, NodeFlag } from "../../ast/node";
import { classParentOf } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeMember, runtimeRef, generatedRef, makeIdentResolved, makeExprStmt } from "../util";

export function lowerJsHostMembers(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		if (node.kind == NodeKind.CallExpr) return hostCall(node);
		if (node.kind == NodeKind.NewExpr) return hostNew(node);
		if (node.kind == NodeKind.ClassDecl) return hostCalledDefaults(node);
		return node;
	});
}

function hostMember(sym: Symbol | null): boolean {
	if (sym == null || sym.symbolKind != SymbolKind.Function) return false;
	let cur: Symbol | null = sym;
	while (cur != null) {
		if (hasFlag(cur, SymbolFlag.JsHost)) return true;
		cur = cur.instantiatedFrom;
	}
	return false;
}

// The routine a `super(...)` runs, the implementation or a signature's variant, belongs to its class through ctorOwner.
function hostConstructor(routine: Symbol | null): boolean {
	if (routine == null) return false;
	if (hasFlag(routine, SymbolFlag.JsHost)) return true;
	return routine.ctorOwner != null && hasFlag(routine.ctorOwner, SymbolFlag.JsHost);
}

function hostClassType(t: Type | null): boolean {
	let cur = t;
	if (cur != null && cur.kind == TypeKind.Ref && cur.typeReturn != null) cur = cur.typeReturn;
	return cur != null && cur.sym != null && hasFlag(cur.sym, SymbolFlag.JsHost);
}

function written(args: Node[]): Node[] {
	return args.filter((a: Node): boolean => !a.flags.has(NodeFlag.FilledDefault));
}

function isSpan(t: Type | null): boolean {
	if (t == null) return false;
	if ((t.kind == TypeKind.Var || t.kind == TypeKind.Sink || t.kind == TypeKind.Lent) && t.typeReturn != null) return t.typeReturn.kind == TypeKind.Span;
	return t.kind == TypeKind.Span;
}

// An array or a typed array reaches the host as it is; a span value becomes the host's array.
function hostArg(arg: Node): Node {
	let source = arg;
	if ((source.kind == NodeKind.HiddenStdConv || source.kind == NodeKind.HiddenSubConv) && isSpan((source.data as HiddenStdConvData).convType)) {
		source = (source.data as HiddenStdConvData).convExpr;
	}
	if (!isSpan(source.nodeType)) return source;
	const host = makeCall(runtimeRef("msSpanHost", arg.location), [source], arg.location);
	host.nodeType = source.nodeType;
	return host;
}

function hostCall(node: Node): Node {
	const d = node.data as CallExprData;
	if (d.callee.kind == NodeKind.Identifier && (d.callee.data as IdentifierData).name == "super") {
		if (hostClassType(node.nodeType) || hostMember(d.callee.resolvedSym) || hostConstructor(d.callee.resolvedSym)) d.arguments = written(d.arguments);
		return node;
	}
	if (d.callee.kind != NodeKind.MemberExpr) return node;
	const sym = node.resolvedSym ?? d.callee.resolvedSym;
	if (!hostMember(sym)) return node;
	const mem = d.callee.data as MemberExprData;
	const args = written(d.arguments).map(hostArg);
	if (mem.property.startsWith("get_")) {
		if (args.length != 0) throw new Error(`internal: host getter '${mem.property}' called with arguments`);
		const read = makeMember(mem.object, mem.property.slice(4), node.location);
		read.nodeType = node.nodeType;
		return read;
	}
	if (mem.property.startsWith("set_")) throw new Error(`internal: '${mem.property}' of a @jsHost class has no host form`);
	const owner = mem.object.resolvedSym;
	const isStatic = owner != null && owner.symbolKind == SymbolKind.Class;
	const pattern = isStatic ? `${owner!.name}.${mem.property}(@)` : `#.${mem.property}(@)`;
	const callee = generatedRef(pattern, node.location);
	callee.resolvedSym!.nativeName = pattern;
	const call = makeCall(callee, isStatic ? args : [mem.object].concat(args), node.location);
	call.nodeType = node.nodeType;
	return call;
}

function hostNew(node: Node): Node {
	if (!hostClassType(node.nodeType)) return node;
	const d = node.data as NewExprData;
	d.newArguments = written(d.newArguments);
	return node;
}

function overHostClass(t: Type | null): boolean {
	let parent = classParentOf(t);
	while (parent != null) {
		if (hostClassType(parent)) return true;
		parent = classParentOf(parent);
	}
	return false;
}

function hostCalledDefaults(node: Node): Node {
	if (node.resolvedSym == null || !overHostClass(node.resolvedSym.symbolType)) return node;
	for (const member of (node.data as ClassDeclData).classBody) {
		const decl = member.kind == NodeKind.DecoratedDecl ? (member.data as DecoratedDeclData).decoratedNode : member;
		if (decl.kind == NodeKind.MethodDecl) fillOmittedArguments(decl);
	}
	return node;
}

function fillOmittedArguments(method: Node): void {
	const d = method.data as MethodDeclData;
	if (d.methodDefaults == null || method.paramSyms == null || d.methodBody == null || d.methodBody.kind != NodeKind.BlockStmt) return;
	const fills: Node[] = [];
	for (let i = 0; i < d.methodDefaults.length && i < method.paramSyms.length; i++) {
		const value = d.methodDefaults[i];
		const param = method.paramSyms[i];
		if (value == null || param == null) continue;
		const fill = generatedRef("if (# === undefined) # = #", value.location);
		fill.resolvedSym!.nativeName = fill.resolvedSym!.name;
		const at = value.location;
		fills.push(makeExprStmt(makeCall(fill, [makeIdentResolved(param, at), makeIdentResolved(param, at), value], at), at));
	}
	if (fills.length == 0) return;
	const body = d.methodBody.data as BlockStmtData;
	body.statements = fills.concat(body.statements);
}
