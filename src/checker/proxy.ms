// Proxy<T, H> (std/core/proxy): `new Proxy(t, h)` and every member read, write and method
// call of the proxy, routed to the handler's trap for its key or to what `Reflect` does on
// the target when H declares none (docs/LANG.md "Proxy"). The trap call is built at the use
// site, so the handler's methods resolve as any method call written there would.

import { ArrayAccessData, BinaryExprData, CallExprData, ClassDeclData, DeclKind, DecoratedDeclData, ExportDeclData, ForOfStmtData, HiddenDerefData, MemberExprData, MethodDeclData, NewExprData, Node, NodeFlag, NodeKind, SourceLocation, StringLiteralData, Type, TypeKind, UpdateExprData, createNodeAt } from "../ast/node";
import { cloneNodeForCheck } from "../monomorphize/clone";
import { callCheckExpr, callCheckStmt } from "./checkerCallbacks";
import { CheckerContext, addError, findAllExtensionsByName, findFirstMatchingExt } from "./context";
import { lookupSymbol } from "./symbol";
import { errorType, isArrayType, isNumeric, peelToStruct, skipModifier, typeDisplayName, typeNameOf } from "./types";
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
	const parts = proxyPartsOf(ctx, node.nodeType);
	if (parts != null) refuseObjectModelTraps(ctx, parts[1], node.location);
	return true;
}

const OBJECT_MODEL_TRAPS = ["defineProperty", "getOwnPropertyDescriptor", "getPrototypeOf", "setPrototypeOf", "isExtensible", "preventExtensions", "apply", "construct"];

function refuseObjectModelTraps(ctx: CheckerContext, handler: Type, loc: SourceLocation): void {
	for (const trap of OBJECT_MODEL_TRAPS) {
		if (!classDeclares(handler, trap)) continue;
		addError(ctx, `'${typeDisplayName(handler)}' declares the '${trap}' trap: it belongs to JavaScript's object model of property descriptors, prototypes and callable objects, which MetaScript objects do not have`, loc.line, loc.column);
	}
	if (classDeclares(handler, "ownKeys")) {
		addError(ctx, `'${typeDisplayName(handler)}' declares the 'ownKeys' trap: no operation lists the keys of a Proxy, so it would never run`, loc.line, loc.column);
	}
}

// The position of the first parameter or the return of an extern that holds a Proxy, "" when none.
export function proxyAtExtern(ctx: CheckerContext, paramTypes: Type[], returnType: Type): string {
	for (let i = 0; i < paramTypes.length; i += 1) {
		if (proxyPartsOf(ctx, paramTypes[i]) != null) return "parameter " + (i + 1).toString();
	}
	return proxyPartsOf(ctx, returnType) != null ? "return type" : "";
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
	if (key == "length" && isArrayType(target)) return true;
	const s = peelToStruct(target);
	return s != null && s.typeNames != null && s.typeNames.indexOf(key) >= 0;
}

function refuseUnknownKey(ctx: CheckerContext, target: Type, key: string, loc: SourceLocation): boolean {
	if (isKeyOf(target, key)) return false;
	addError(ctx, `'${key}' is not a key of '${typeDisplayName(target)}'`, loc.line, loc.column);
	return true;
}

// A receiver or key read twice in the trap call reads the same value: a name, a literal or a field path.
function readsWithoutEffect(n: Node): boolean {
	if (n.kind == NodeKind.Identifier || n.kind == NodeKind.NumberLiteral || n.kind == NodeKind.StringLiteral) return true;
	if (n.kind == NodeKind.HiddenDeref) return readsWithoutEffect((n.data as HiddenDerefData).expr);
	return n.kind == NodeKind.MemberExpr && !(n.data as MemberExprData).isOptional && readsWithoutEffect((n.data as MemberExprData).object);
}

function call(name: string, args: Node[], loc: SourceLocation): Node {
	const callee = createNodeAt(NodeKind.Identifier, { name: name }, loc);
	return createNodeAt(NodeKind.CallExpr, { callee: callee, arguments: args, isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
}

function methodCall(object: Node, method: string, args: Node[], loc: SourceLocation): Node {
	return createNodeAt(NodeKind.CallExpr, { callee: member(object, method, loc), arguments: args, isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
}

function member(object: Node, key: string, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.MemberExpr, { object: object, property: key, isOptional: false }, loc);
}

function ident(id: string, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.Identifier, { name: id }, loc);
}

function keyLiteral(key: string, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: key }, loc);
}

function numberLiteral(n: int32, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.NumberLiteral, { value: n, isFloat: false, intVal: n, outOfRangeText: "", isBitPattern: false }, loc);
}

function statement(expr: Node): Node {
	return createNodeAt(NodeKind.ExprStmt, { expr: expr }, expr.location);
}

function block(statements: Node[], loc: SourceLocation): Node {
	return createNodeAt(NodeKind.BlockStmt, { statements: statements }, loc);
}

function routine(params: string[], body: Node, loc: SourceLocation): Node {
	const types: string[] = [];
	const defaults: Node[] = [];
	for (let i = 0; i < params.length; i += 1) { types.push(""); defaults.push(null as unknown as Node); }
	return createNodeAt(NodeKind.ArrowFunction, {
		arrowParams: params, arrowParamTypes: types, arrowBody: body,
		arrowFlags: "", arrowReturnType: "", arrowDefaults: defaults,
	}, loc);
}

// `proxyHandler(p).<trap>(proxyTarget(p), ...args)` for a receiver read without effect.
function handlerCall(proxy: Node, trap: string, args: Node[], loc: SourceLocation): Node {
	const callArgs: Node[] = [call("proxyTarget", [cloneNodeForCheck(proxy)], loc)].concat(args);
	return methodCall(call("proxyHandler", [proxy], loc), trap, callArgs, loc);
}

// `Reflect.<op>(proxyTarget(p), ...args)`: what a trap the handler leaves out does.
function reflectCall(proxy: Node, op: string, args: Node[], loc: SourceLocation): Node {
	return methodCall(ident("Reflect", loc), op, [call("proxyTarget", [proxy], loc)].concat(args), loc);
}

const RECEIVER = "$proxy";
const KEY = "$key";

// `proxyWith(p, ($proxy) => body)`: a receiver with effects is read once, into the parameter.
function readOnce(proxy: Node, body: Node, loc: SourceLocation): Node {
	return call("proxyWith", [proxy, routine([RECEIVER], body, loc)], loc);
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

// The read of `recv[key]` through `get`, or through `Reflect.get` when H declares none.
function readOf(recv: Node, key: Node, route: Route, loc: SourceLocation): Node {
	if (route == "trap") return handlerCall(recv, "get", [key], loc);
	if (key.kind == NodeKind.StringLiteral) return member(call("proxyTarget", [recv], loc), (key.data as StringLiteralData).value, loc);
	return reflectCall(recv, "get", [key], loc);
}

function readThrough(ctx: CheckerContext, node: Node, recv: Node, key: Node, handler: Type, expected: Type | null): Type {
	const loc = node.location;
	const route = routeOf(ctx, handler, "get", loc);
	if (route == "refused") return errorType();
	const read = route == "trap" && !readsWithoutEffect(recv)
		? readOnce(recv, readOf(ident(RECEIVER, loc), key, route, loc), loc)
		: readOf(recv, key, route, loc);
	callCheckExpr(ctx, read, expected);
	return adopt(node, read);
}

// `p.key` → `get(target, "key")`, or `target.key` when H declares no `get`.
export function readThroughProxy(ctx: CheckerContext, node: Node, parts: Type[], expected: Type | null): Type {
	const d = node.data as MemberExprData;
	if (refuseUnknownKey(ctx, parts[0], d.property, node.location)) return errorType();
	return readThrough(ctx, node, d.object, keyLiteral(d.property, node.location), parts[1], expected);
}

// `p[i]` on a Proxy<E[], H> → `get(target, i)`, or `Reflect.get(target, i)` when H declares no `get`.
export function readIndexThroughProxy(ctx: CheckerContext, node: Node, expected: Type | null): void {
	const d = node.data as ArrayAccessData;
	const parts = proxyPartsOf(ctx, d.array.nodeType);
	if (parts == null) return;
	readThrough(ctx, node, d.array, d.index, parts[1], expected);
}

// The write of `value` to `recv[key]`: `set`, whose false fails the write, or `Reflect.set`
// on an array target, or the field of the target.
function writeTo(recv: Node, key: Node, value: Node, route: Route, onArray: boolean, loc: SourceLocation): Node {
	if (route == "trap") return call("proxyChecked", [handlerCall(recv, "set", [key, value], loc), keyLiteral("set", loc), cloneNodeForCheck(key)], loc);
	if (onArray) return reflectCall(recv, "set", [key, value], loc);
	const field = member(call("proxyTarget", [recv], loc), (key.data as StringLiteralData).value, loc);
	return createNodeAt(NodeKind.BinaryExpr, { left: field, operator: "=", right: value }, loc);
}

// The read `recv[key]` written again, so a compound write's read goes through `get` like any read.
function rereadOf(recv: Node, key: Node, loc: SourceLocation): Node {
	if (key.kind == NodeKind.StringLiteral) return member(cloneNodeForCheck(recv), (key.data as StringLiteralData).value, loc);
	return createNodeAt(NodeKind.ArrayAccess, { array: cloneNodeForCheck(recv), index: cloneNodeForCheck(key) }, loc);
}

// `recv[key] op= v` is the write of `recv[key] op v`.
function compoundWrite(recv: Node, key: Node, op: string, right: Node, route: Route, onArray: boolean, loc: SourceLocation): Node {
	const value = op == "=" ? right
		: createNodeAt(NodeKind.BinaryExpr, { left: rereadOf(recv, key, loc), operator: op.slice(0, op.length - 1), right: right }, loc);
	return writeTo(recv, key, value, route, onArray, loc);
}

// `p.key = v`, `p[i] = v` and their compound forms; a receiver or index with effects is read once.
export function writeThroughProxy(ctx: CheckerContext, node: Node): boolean {
	const d = node.data as BinaryExprData;
	let recv: Node;
	let key: Node;
	if (d.left.kind == NodeKind.MemberExpr) {
		const md = d.left.data as MemberExprData;
		recv = md.object;
		key = keyLiteral(md.property, d.left.location);
	} else if (d.left.kind == NodeKind.ArrayAccess) {
		recv = (d.left.data as ArrayAccessData).array;
		key = (d.left.data as ArrayAccessData).index;
	} else return false;
	const parts = proxyPartsOf(ctx, recv.nodeType);
	if (parts == null) return false;
	const loc = d.left.location;
	const onArray = isArrayType(parts[0]);
	const unknown = key.kind == NodeKind.StringLiteral && refuseUnknownKey(ctx, parts[0], (key.data as StringLiteralData).value, loc);
	const route: Route = unknown ? "refused" : routeOf(ctx, parts[1], "set", loc);
	if (route == "refused") { node.nodeType = errorType(); return true; }
	let write: Node;
	if (readsWithoutEffect(recv) && readsWithoutEffect(key)) write = compoundWrite(recv, key, d.operator, d.right, route, onArray, loc);
	else if (key.kind == NodeKind.StringLiteral) write = readOnce(recv, block([statement(compoundWrite(ident(RECEIVER, loc), key, d.operator, d.right, route, onArray, loc))], loc), loc);
	else {
		const body = block([statement(compoundWrite(ident(RECEIVER, loc), ident(KEY, loc), d.operator, d.right, route, onArray, loc))], loc);
		write = call("proxyWithKey", [recv, key, routine([RECEIVER, KEY], body, loc)], loc);
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

function proxyOperand(ctx: CheckerContext, n: Node): boolean {
	if (n.kind == NodeKind.MemberExpr) return proxyPartsOf(ctx, (n.data as MemberExprData).object.nodeType) != null;
	return n.kind == NodeKind.ArrayAccess && proxyPartsOf(ctx, (n.data as ArrayAccessData).array.nodeType) != null;
}

// `p.key++` and `p[i]++` as a statement are `+= 1`.
export function updateThroughProxy(ctx: CheckerContext, node: Node): boolean {
	const d = node.data as UpdateExprData;
	if (!proxyOperand(ctx, d.updateArg)) return false;
	if (node != ctx.stmtPosExpr) {
		addError(ctx, `'${d.updateOp}' through a Proxy is a statement: write it on its own line`, node.location.line, node.location.column);
		node.nodeType = errorType();
		return true;
	}
	node.kind = NodeKind.BinaryExpr;
	node.data = { left: d.updateArg, operator: d.updateOp == "++" ? "+=" : "-=", right: numberLiteral(1, node.location) };
	node.flags = node.flags.excl(NodeFlag.Sem);
	node.nodeType = null;
	callCheckExpr(ctx, node, null);
	return true;
}

export type Keyed = "none" | "member" | "index" | "refused";

// `p["key"]` is `p.key`; `p[i]` with a number on a Proxy<E[], H> is an index; a key held in a
// variable is refused until the instances can be chosen by it.
export function keyedProxyAccess(ctx: CheckerContext, node: Node): Keyed {
	const d = node.data as ArrayAccessData;
	const parts = proxyPartsOf(ctx, d.array.nodeType);
	if (parts == null) return "none";
	if (d.index.nodeType == null) callCheckExpr(ctx, d.index, null);
	const keyType = skipModifier(d.index.nodeType);
	if (isArrayType(parts[0]) && isNumeric(keyType)) return "index";
	const key = d.index.kind == NodeKind.StringLiteral ? (d.index.data as StringLiteralData).value
		: keyType != null && keyType.kind == TypeKind.StringLiteral ? keyType.typeName : null;
	if (key == null) {
		addError(ctx, `a Proxy is indexed by a key written in the source; '${typeDisplayName(d.index.nodeType)}' is not one`, d.index.location.line, d.index.location.column);
		node.nodeType = errorType();
		return "refused";
	}
	node.kind = NodeKind.MemberExpr;
	node.data = { object: d.array, property: key, isOptional: false };
	node.flags = node.flags.excl(NodeFlag.Sem);
	node.nodeType = null;
	return "member";
}

// ===== Method calls =====

// An array method on a Proxy<E[], H> and the std function that runs its steps, with the
// traps it needs and how many arguments it takes.
type Chain = { method: string, fn: string, steps: string[], minArgs: int32, maxArgs: int32 };

const CHAINS: Chain[] = [
	{ method: "push", fn: "proxyPush", steps: ["len", "set", "setLen"], minArgs: 1, maxArgs: 1 },
	{ method: "pop", fn: "proxyPop", steps: ["len", "get", "del", "setLen"], minArgs: 0, maxArgs: 0 },
	{ method: "shift", fn: "proxyShift", steps: ["len", "get", "set", "has", "del", "setLen"], minArgs: 0, maxArgs: 0 },
	{ method: "splice", fn: "proxySplice", steps: ["len", "get", "set", "has", "del", "setLen"], minArgs: 2, maxArgs: 2 },
	{ method: "reverse", fn: "proxyReverse", steps: ["len", "get", "set", "has"], minArgs: 0, maxArgs: 0 },
	{ method: "fill", fn: "proxyFill", steps: ["len", "set"], minArgs: 1, maxArgs: 1 },
	{ method: "sort", fn: "proxySortDefault", steps: ["len", "get", "set", "has"], minArgs: 0, maxArgs: 0 },
	{ method: "sort", fn: "proxySort", steps: ["len", "get", "set", "has"], minArgs: 1, maxArgs: 1 },
	{ method: "map", fn: "proxyMap", steps: ["len", "get", "has"], minArgs: 1, maxArgs: 1 },
	{ method: "filter", fn: "proxyFilter", steps: ["len", "get", "has"], minArgs: 1, maxArgs: 1 },
	{ method: "some", fn: "proxySome", steps: ["len", "get", "has"], minArgs: 1, maxArgs: 1 },
	{ method: "find", fn: "proxyFind", steps: ["len", "get"], minArgs: 1, maxArgs: 1 },
	{ method: "findIndex", fn: "proxyFindIndex", steps: ["len", "get"], minArgs: 1, maxArgs: 1 },
	{ method: "findLastIndex", fn: "proxyFindLastIndex", steps: ["len", "get"], minArgs: 1, maxArgs: 1 },
	{ method: "indexOf", fn: "proxyIndexOf", steps: ["len", "get", "has"], minArgs: 1, maxArgs: 1 },
	{ method: "lastIndexOf", fn: "proxyLastIndexOf", steps: ["len", "get", "has"], minArgs: 1, maxArgs: 2 },
	{ method: "includes", fn: "proxyIncludes", steps: ["len", "get"], minArgs: 1, maxArgs: 1 },
	{ method: "join", fn: "proxyJoin", steps: ["len", "get"], minArgs: 1, maxArgs: 1 },
	{ method: "slice", fn: "proxySlice", steps: ["len", "get", "has"], minArgs: 1, maxArgs: 2 },
	{ method: "at", fn: "proxyAt", steps: ["len", "get"], minArgs: 1, maxArgs: 1 },
];

const TRAPS = ["get", "set", "has", "deleteProperty", "ownKeys"];

// One step of a chain as a routine that captures nothing: each reads or writes the proxy
// it is given, so the read or write goes through the trap like one written in the source.
function step(kind: string, handler: Type, ctx: CheckerContext, loc: SourceLocation): Node {
	const p = ident("$p", loc);
	const k = ident("$k", loc);
	if (kind == "len") return routine(["$p"], member(p, "length", loc), loc);
	if (kind == "get") return routine(["$p", "$k"], createNodeAt(NodeKind.ArrayAccess, { array: p, index: k }, loc), loc);
	if (kind == "set") {
		const write = createNodeAt(NodeKind.BinaryExpr, { left: createNodeAt(NodeKind.ArrayAccess, { array: p, index: k }, loc), operator: "=", right: ident("$v", loc) }, loc);
		return routine(["$p", "$k", "$v"], block([statement(write)], loc), loc);
	}
	if (kind == "setLen") {
		const write = createNodeAt(NodeKind.BinaryExpr, { left: member(p, "length", loc), operator: "=", right: ident("$n", loc) }, loc);
		return routine(["$p", "$n"], block([statement(write)], loc), loc);
	}
	if (kind == "has") {
		const has = routeOf(ctx, handler, "has", loc) == "trap" ? handlerCall(p, "has", [k], loc) : reflectCall(p, "has", [k], loc);
		return routine(["$p", "$k"], has, loc);
	}
	const del = routeOf(ctx, handler, "deleteProperty", loc) == "trap"
		? call("proxyChecked", [handlerCall(p, "deleteProperty", [k], loc), keyLiteral("deleteProperty", loc), cloneNodeForCheck(k)], loc)
		: reflectCall(p, "deleteProperty", [k], loc);
	return routine(["$p", "$k"], block([statement(del)], loc), loc);
}

function chainOf(method: string, argc: int32): Chain | null {
	for (const c of CHAINS) {
		if (c.method == method && argc >= c.minArgs && argc <= c.maxArgs) return c;
	}
	return null;
}

// `p.m(...args)`: the handler's override `m(target, ...args)` when H declares one; on a
// Proxy<E[], H> the std chain of `m` otherwise; a key of T holding a function is read and
// called; anything else is refused, so a method never runs on the target behind the traps.
export function callThroughProxy(ctx: CheckerContext, node: Node, expected: Type | null): boolean {
	const d = node.data as CallExprData;
	if (d.callee.kind != NodeKind.MemberExpr) return false;
	const md = d.callee.data as MemberExprData;
	const parts = proxyPartsOf(ctx, md.object.nodeType);
	if (parts == null) return false;
	const loc = d.callee.location;
	const method = md.property;
	if (isKeyOf(parts[0], method)) {
		readThroughProxy(ctx, d.callee, parts, null);
		return false;
	}
	let built: Node | null = null;
	const overrides = TRAPS.indexOf(method) < 0 && classDeclares(parts[1], method);
	if (overrides) {
		if (routeOf(ctx, parts[1], method, loc) == "refused") { node.nodeType = errorType(); return true; }
		built = readsWithoutEffect(md.object) ? handlerCall(md.object, method, d.arguments, loc)
			: readOnce(md.object, handlerCall(ident(RECEIVER, loc), method, d.arguments, loc), loc);
	} else if (isArrayType(parts[0])) {
		const chain = chainOf(method, d.arguments.length as int32);
		if (chain != null) {
			const args: Node[] = [md.object];
			for (const s of chain.steps) args.push(step(s, parts[1], ctx, loc));
			built = call(chain.fn, args.concat(d.arguments), loc);
		}
	}
	if (built == null) {
		const why = isArrayType(parts[0])
			? `'${method}' with ${d.arguments.length} argument(s) has no trap form on a Proxy of an array`
			: `a Proxy calls no method of its target, which would run behind the traps`;
		addError(ctx, `${why}: declare '${method}' in '${typeDisplayName(parts[1])}' to override it, or call it on proxyTarget(p)`, loc.line, loc.column);
		node.nodeType = errorType();
		return true;
	}
	callCheckExpr(ctx, built, expected);
	adopt(node, built);
	return true;
}

// `for (const x of p)` over a Proxy<E[], H> reads `length` and each index through the traps,
// as JavaScript's array iterator does: `{ const $items = p; for (let $i = 0; $i < $items.length; $i += 1) { const x = $items[$i]; body } }`.
export function iterateThroughProxy(ctx: CheckerContext, node: Node): boolean {
	const d = node.data as ForOfStmtData;
	const parts = proxyPartsOf(ctx, d.forOfIterable.nodeType);
	if (parts == null) return false;
	const loc = node.location;
	if (!isArrayType(parts[0])) {
		addError(ctx, `for-of over a Proxy needs an array target; '${typeDisplayName(parts[0])}' is not one`, loc.line, loc.column);
		return true;
	}
	const items = createNodeAt(NodeKind.VariableDecl, { declName: "$items", declType: "", initializer: d.forOfIterable, declKind: DeclKind.Const, nameLocation: loc }, loc);
	const index = createNodeAt(NodeKind.VariableDecl, { declName: "$i", declType: "", initializer: numberLiteral(0, loc), declKind: DeclKind.Let, nameLocation: loc }, loc);
	const element = createNodeAt(NodeKind.ArrayAccess, { array: ident("$items", loc), index: ident("$i", loc) }, loc);
	const binding = d.forOfPattern != null
		? createNodeAt(NodeKind.DestructuringDecl, { destrPattern: d.forOfPattern, destrInit: element, destrIsConst: d.forOfIsConst }, loc)
		: createNodeAt(NodeKind.VariableDecl, { declName: d.forOfBinding, declType: "", initializer: element, declKind: d.forOfIsConst ? DeclKind.Const : DeclKind.Let, nameLocation: d.bindingLocation }, d.bindingLocation);
	const bound = ctx.adoptedDecls.get(node);
	if (bound != null) { ctx.adoptedDecls.delete(node); ctx.adoptedDecls.set(binding, bound); }
	const loop = createNodeAt(NodeKind.ForStmt, {
		forInit: index,
		forCondition: createNodeAt(NodeKind.BinaryExpr, { left: ident("$i", loc), operator: "<", right: member(ident("$items", loc), "length", loc) }, loc),
		forUpdate: createNodeAt(NodeKind.BinaryExpr, { left: ident("$i", loc), operator: "+=", right: numberLiteral(1, loc) }, loc),
		forBody: block([binding, d.forOfBody], loc),
		forLabel: d.forOfLabel,
	}, loc);
	node.kind = NodeKind.BlockStmt;
	node.data = { statements: [items, loop] };
	node.flags = node.flags.excl(NodeFlag.Sem);
	callCheckStmt(ctx, node);
	return true;
}

// `p === todo`: a proxy and its target are two identities (docs/LANG.md "A Proxy<T, H> is not
// a T"); `key in p` has no meaning a Proxy keeps, MetaScript's `in` reading no trap.
export function refuseProxyOperator(ctx: CheckerContext, op: string, left: Type | null, right: Type | null, node: Node): boolean {
	if (op == "in") {
		if (proxyPartsOf(ctx, right) == null) return false;
		addError(ctx, `'in' on a ${typeDisplayName(right)} would skip its 'has' trap: test the key on proxyTarget(p)`, node.location.line, node.location.column);
		return true;
	}
	if (op != "===" && op != "!==" && op != "==" && op != "!=") return false;
	const leftIsProxy = proxyPartsOf(ctx, left) != null;
	if (leftIsProxy == (proxyPartsOf(ctx, right) != null)) return false;
	const other = skipModifier(leftIsProxy ? right : left);
	if (other == null || other.kind == TypeKind.Null || other.kind == TypeKind.Error) return false;
	addError(ctx, `a ${typeDisplayName(leftIsProxy ? left : right)} and a ${typeDisplayName(other)} are different types: compare proxyTarget(p) with the target`, node.location.line, node.location.column);
	return true;
}
