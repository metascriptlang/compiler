// Proxy<T, H> (std/core/proxy): `new Proxy(t, h)` and every member read and write of
// the proxy, routed to the handler's trap for its key or to the target when H declares
// none (docs/LANG.md "Proxy"). The trap call is built at the use site, so the handler's
// methods resolve as any method call written there would.

import { ArrayAccessData, BinaryExprData, ClassDeclData, DecoratedDeclData, ExportDeclData, HiddenDerefData, MemberExprData, MethodDeclData, NewExprData, Node, NodeFlag, NodeKind, SourceLocation, StringLiteralData, Type, TypeKind, UpdateExprData, createNodeAt } from "../ast/node";
import { cloneNodeForCheck } from "../monomorphize/clone";
import { callCheckExpr } from "./checkerCallbacks";
import { CheckerContext, addError, findAllExtensionsByName, findFirstMatchingExt } from "./context";
import { lookupSymbol } from "./symbol";
import { errorType, peelToStruct, skipModifier, typeDisplayName, typeNameOf } from "./types";
import { declaringSymOf } from "./visibility";

function isStdProxy(ctx: CheckerContext): boolean {
	const sym = lookupSymbol(ctx.table, "Proxy");
	return sym != null && sym.modulePath.endsWith("std/core/proxy/index.ms");
}

// The target and handler types of a `Proxy<T, H>`, null for any other type.
export function proxyPartsOf(ctx: CheckerContext, t: Type | null): Type[] | null {
	const s = skipModifier(t);
	if (s == null || s.kind != TypeKind.GenericInstance || s.typeName != "Proxy" || s.typeChildren.length != 2) return null;
	return isStdProxy(ctx) ? s.typeChildren : null;
}

// `new Proxy(target, handler)` is `newProxy(target, handler)`.
export function checkNewProxy(ctx: CheckerContext, node: Node, expected: Type | null): boolean {
	if (!isStdProxy(ctx)) return false;
	const d = node.data as NewExprData;
	const callee = createNodeAt(NodeKind.Identifier, { name: "newProxy" }, d.newCallee.location);
	node.kind = NodeKind.CallExpr;
	node.data = { callee: callee, arguments: d.newArguments, isDirectCall: true, resolvedOverloadIdx: -1 };
	node.flags = node.flags.excl(NodeFlag.Sem);
	node.nodeType = null;
	callCheckExpr(ctx, node, expected);
	return true;
}

// Whether the handler's class declares the trap as an instance method, read from its declaration.
function classDeclares(handler: Type, trap: string): boolean {
	const sym = declaringSymOf(handler);
	let decl: Node | null = sym != null ? sym.declNode : null;
	if (decl != null && decl.kind == NodeKind.ExportDecl) decl = (decl.data as ExportDeclData).exportedDecl;
	if (decl != null && decl.kind == NodeKind.DecoratedDecl) decl = (decl.data as DecoratedDeclData).decoratedNode;
	if (decl == null || decl.kind != NodeKind.ClassDecl) return false;
	for (const member of (decl.data as ClassDeclData).classBody) {
		if (member.kind != NodeKind.MethodDecl) continue;
		const md = member.data as MethodDeclData;
		if (md.methodName == trap && !md.methodIsStatic) return true;
	}
	return false;
}

function callableHere(ctx: CheckerContext, handler: Type, trap: string): boolean {
	const name = typeNameOf(handler);
	if (name != "" && lookupSymbol(ctx.table, name + "_" + trap) != null) return true;
	return ctx.extensionRegistry != null && findFirstMatchingExt(findAllExtensionsByName(ctx.extensionRegistry, trap), handler) != null;
}

type Route = "trap" | "target" | "refused";

// The trap when H declares it, the target when H does not; a declared trap this site cannot
// call is refused, so a proxy never skips its handler.
function routeOf(ctx: CheckerContext, handler: Type, trap: string, loc: SourceLocation): Route {
	if (callableHere(ctx, handler, trap)) return "trap";
	if (!classDeclares(handler, trap)) return "target";
	addError(ctx, `the '${trap}' trap of '${typeDisplayName(handler)}' cannot be called here: export '${typeNameOf(handler)}' from its module`, loc.line, loc.column);
	return "refused";
}

function isKeyOf(target: Type, key: string): boolean {
	const s = peelToStruct(target);
	return s != null && s.typeNames != null && s.typeNames.indexOf(key) >= 0;
}

function refuseUnknownKey(ctx: CheckerContext, target: Type, key: string, loc: SourceLocation): boolean {
	if (isKeyOf(target, key)) return false;
	addError(ctx, `'${key}' is not a key of '${typeDisplayName(target)}'`, loc.line, loc.column);
	return true;
}

// A receiver read twice in the trap call reads the same proxy: a name or a field path.
function readsWithoutEffect(n: Node): boolean {
	if (n.kind == NodeKind.Identifier) return true;
	if (n.kind == NodeKind.HiddenDeref) return readsWithoutEffect((n.data as HiddenDerefData).expr);
	return n.kind == NodeKind.MemberExpr && !(n.data as MemberExprData).isOptional && readsWithoutEffect((n.data as MemberExprData).object);
}

function call(name: string, args: Node[], loc: SourceLocation): Node {
	const callee = createNodeAt(NodeKind.Identifier, { name: name }, loc);
	return createNodeAt(NodeKind.CallExpr, { callee: callee, arguments: args, isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
}

function member(object: Node, key: string, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.MemberExpr, { object: object, property: key, isOptional: false }, loc);
}

function keyLiteral(key: string, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: key }, loc);
}

// `proxyHandler(p).<trap>(proxyTarget(p), ...args)` for a receiver read without effect.
function handlerCall(proxy: Node, trap: string, args: Node[], loc: SourceLocation): Node {
	const method = member(call("proxyHandler", [proxy], loc), trap, loc);
	const callArgs: Node[] = [call("proxyTarget", [cloneNodeForCheck(proxy)], loc)].concat(args);
	return createNodeAt(NodeKind.CallExpr, { callee: method, arguments: callArgs, isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
}

const RECEIVER = "$proxy";

// `proxyWith(p, ($proxy) => body)`: a receiver with effects is read once, into the parameter.
function readOnce(proxy: Node, body: Node, loc: SourceLocation): Node {
	const routine = createNodeAt(NodeKind.ArrowFunction, {
		arrowParams: [RECEIVER], arrowParamTypes: [""], arrowBody: body,
		arrowFlags: "", arrowReturnType: "", arrowDefaults: [null as unknown as Node],
	}, loc);
	return call("proxyWith", [proxy, routine], loc);
}

function receiverParam(loc: SourceLocation): Node {
	return createNodeAt(NodeKind.Identifier, { name: RECEIVER }, loc);
}

function adopt(node: Node, from: Node): Type {
	node.kind = from.kind;
	node.data = from.data;
	node.nodeType = from.nodeType;
	node.flags = from.flags;
	node.variantSlot = from.variantSlot;
	if (from.resolvedSym != null) node.resolvedSym = from.resolvedSym;
	return node.nodeType ?? errorType();
}

// `p.key` → `get(target, "key")`, or `target.key` when H declares no `get`.
export function readThroughProxy(ctx: CheckerContext, node: Node, parts: Type[], expected: Type | null): Type {
	const d = node.data as MemberExprData;
	const loc = node.location;
	if (refuseUnknownKey(ctx, parts[0], d.property, loc)) return errorType();
	const route = routeOf(ctx, parts[1], "get", loc);
	if (route == "refused") return errorType();
	let read: Node;
	if (route == "target") read = member(call("proxyTarget", [d.object], loc), d.property, loc);
	else if (readsWithoutEffect(d.object)) read = handlerCall(d.object, "get", [keyLiteral(d.property, loc)], loc);
	else read = readOnce(d.object, handlerCall(receiverParam(loc), "get", [keyLiteral(d.property, loc)], loc), loc);
	callCheckExpr(ctx, read, expected);
	return adopt(node, read);
}

// The write of `value` to `recv.key`: `set(target, "key", value)`, or the field of the target.
function writeTo(recv: Node, key: string, value: Node, route: Route, loc: SourceLocation): Node {
	if (route == "trap") return handlerCall(recv, "set", [keyLiteral(key, loc), value], loc);
	return createNodeAt(NodeKind.BinaryExpr, { left: member(call("proxyTarget", [recv], loc), key, loc), operator: "=", right: value }, loc);
}

// `recv.key op= v` is the write of `recv.key op v`, its read going through `get` like any read.
function compoundWrite(recv: Node, key: string, op: string, right: Node, route: Route, loc: SourceLocation): Node {
	const value = op == "=" ? right
		: createNodeAt(NodeKind.BinaryExpr, { left: member(cloneNodeForCheck(recv), key, loc), operator: op.slice(0, op.length - 1), right: right }, loc);
	return writeTo(recv, key, value, route, loc);
}

// `p.key = v` and `p.key op= v`, routed like a read; a receiver with effects is read once.
export function writeThroughProxy(ctx: CheckerContext, node: Node): boolean {
	const d = node.data as BinaryExprData;
	if (d.left.kind != NodeKind.MemberExpr) return false;
	const md = d.left.data as MemberExprData;
	const parts = proxyPartsOf(ctx, md.object.nodeType);
	if (parts == null) return false;
	const loc = d.left.location;
	const route: Route = refuseUnknownKey(ctx, parts[0], md.property, loc) ? "refused" : routeOf(ctx, parts[1], "set", loc);
	if (route == "refused") { node.nodeType = errorType(); return true; }
	let write: Node;
	if (readsWithoutEffect(md.object)) write = compoundWrite(md.object, md.property, d.operator, d.right, route, loc);
	else {
		const stmt = createNodeAt(NodeKind.ExprStmt, { expr: compoundWrite(receiverParam(loc), md.property, d.operator, d.right, route, loc) }, loc);
		write = readOnce(md.object, createNodeAt(NodeKind.BlockStmt, { statements: [stmt] }, loc), loc);
	}
	if (write.kind == NodeKind.BinaryExpr) {
		node.data = write.data;
		node.flags = node.flags.excl(NodeFlag.Sem);
		node.nodeType = null;
		callCheckExpr(ctx, node, null);
		return true;
	}
	callCheckExpr(ctx, write, null);
	adopt(node, write);
	return true;
}

// `p.key++` as a statement is `p.key += 1`.
export function updateThroughProxy(ctx: CheckerContext, node: Node): boolean {
	const d = node.data as UpdateExprData;
	if (d.updateArg.kind != NodeKind.MemberExpr) return false;
	if (proxyPartsOf(ctx, (d.updateArg.data as MemberExprData).object.nodeType) == null) return false;
	if (node != ctx.stmtPosExpr) {
		addError(ctx, `'${d.updateOp}' through a Proxy is a statement: write it on its own line`, node.location.line, node.location.column);
		node.nodeType = errorType();
		return true;
	}
	const one = createNodeAt(NodeKind.NumberLiteral, { value: 1, isFloat: false, intVal: 1, outOfRangeText: "", isBitPattern: false }, node.location);
	node.kind = NodeKind.BinaryExpr;
	node.data = { left: d.updateArg, operator: d.updateOp == "++" ? "+=" : "-=", right: one };
	node.flags = node.flags.excl(NodeFlag.Sem);
	node.nodeType = null;
	callCheckExpr(ctx, node, null);
	return true;
}

// `p["key"]` is `p.key`; a key held in a variable is refused until the instances can be chosen by it.
export function keyedProxyAccess(ctx: CheckerContext, node: Node): boolean {
	const d = node.data as ArrayAccessData;
	if (proxyPartsOf(ctx, d.array.nodeType) == null) return false;
	if (d.index.nodeType == null) callCheckExpr(ctx, d.index, null);
	const keyType = skipModifier(d.index.nodeType);
	const key = d.index.kind == NodeKind.StringLiteral ? (d.index.data as StringLiteralData).value
		: keyType != null && keyType.kind == TypeKind.StringLiteral ? keyType.typeName : null;
	if (key == null) {
		addError(ctx, `a Proxy is indexed by a key written in the source; '${typeDisplayName(d.index.nodeType)}' is not one`, d.index.location.line, d.index.location.column);
		node.nodeType = errorType();
		return true;
	}
	node.kind = NodeKind.MemberExpr;
	node.data = { object: d.array, property: key, isOptional: false };
	node.flags = node.flags.excl(NodeFlag.Sem);
	node.nodeType = null;
	return true;
}

// `p === todo`: a proxy and its target are two identities (docs/LANG.md "A Proxy<T, H> is not a T").
export function refuseProxyComparison(ctx: CheckerContext, op: string, left: Type | null, right: Type | null, node: Node): boolean {
	if (op != "===" && op != "!==" && op != "==" && op != "!=") return false;
	const leftIsProxy = proxyPartsOf(ctx, left) != null;
	if (leftIsProxy == (proxyPartsOf(ctx, right) != null)) return false;
	const other = skipModifier(leftIsProxy ? right : left);
	if (other == null || other.kind == TypeKind.Null || other.kind == TypeKind.Error) return false;
	addError(ctx, `a ${typeDisplayName(leftIsProxy ? left : right)} and a ${typeDisplayName(other)} are different types: compare proxyTarget(p) with the target`, node.location.line, node.location.column);
	return true;
}
