import { Node, NodeKind, Symbol, SymbolKind, Type, TypeKind, ClassDeclData, PropertyDeclData, MethodDeclData, DecoratedDeclData, ExportDeclData, InterfaceDeclData, CallExprData, MemberExprData, IdentifierData } from "../ast/node";
import { classDeclNodeOf, parentClassSymOf, lookupSymbol, Scope } from "./symbol";
import { CheckerContext, addError } from "./context";

function unwrapDecl(node: Node | null): Node | null {
	let n = node;
	while (n != null) {
		if (n.kind == NodeKind.ExportDecl) n = (n.data as ExportDeclData).exportedDecl;
		else if (n.kind == NodeKind.DecoratedDecl) n = (n.data as DecoratedDeclData).decoratedNode;
		else return n;
	}
	return null;
}

function isClassLike(sym: Symbol): boolean {
	return sym.symbolKind == SymbolKind.Class || sym.symbolKind == SymbolKind.Actor;
}

function originOf(sym: Symbol): Symbol {
	let s = sym;
	let depth = 0;
	while (s.instantiatedFrom != null && depth < 16) {
		s = s.instantiatedFrom;
		depth += 1;
	}
	return s;
}

enum DeclaredVisibility { NotDeclared, Public, Private, Protected }

function memberVisibility(written: string): DeclaredVisibility {
	if (written == "private") return DeclaredVisibility.Private;
	if (written == "protected") return DeclaredVisibility.Protected;
	return DeclaredVisibility.Public;
}

function ownVisibility(sym: Symbol, field: string): DeclaredVisibility {
	if (isClassLike(sym)) {
		const decl = classDeclNodeOf(sym);
		if (decl == null || decl.kind != NodeKind.ClassDecl) return DeclaredVisibility.NotDeclared;
		for (const member of (decl.data as ClassDeclData).classBody) {
			const m = unwrapDecl(member);
			if (m == null || m.kind != NodeKind.PropertyDecl) continue;
			const pd = m.data as PropertyDeclData;
			if (pd.propIsStatic || pd.propName != field) continue;
			return memberVisibility(pd.propVisibility);
		}
		return DeclaredVisibility.NotDeclared;
	}
	const decl = unwrapDecl(sym.declNode);
	if (decl == null || (decl.kind != NodeKind.StructDecl && decl.kind != NodeKind.InterfaceDecl)) return DeclaredVisibility.NotDeclared;
	const d = decl.data as InterfaceDeclData;
	for (let i = 0; i < d.interfaceFields.length; i += 1) {
		if (d.interfaceFields[i] != field) continue;
		const vis = d.interfaceFieldVisibility;
		return vis != null && i < vis.length && vis[i] == "private" ? DeclaredVisibility.Private : DeclaredVisibility.Public;
	}
	return DeclaredVisibility.NotDeclared;
}

function parentOf(sym: Symbol): Symbol | null {
	if (isClassLike(sym)) return parentClassSymOf(sym);
	const t = sym.symbolType;
	if (t == null || t.kind != TypeKind.Struct || t.typeExtra == null) return null;
	let p = t.typeExtra;
	if (p.kind == TypeKind.Ref && p.typeReturn != null) p = p.typeReturn;
	return p.sym;
}

export function privateFieldOwner(typeSym: Symbol | null, field: string): Symbol | null {
	let sym: Symbol | null = typeSym != null ? originOf(typeSym) : null;
	let depth = 0;
	while (sym != null && depth < 64) {
		const vis = ownVisibility(sym, field);
		if (vis == DeclaredVisibility.Private || vis == DeclaredVisibility.Protected) return sym;
		if (vis == DeclaredVisibility.Public) return null;
		const parent = parentOf(sym);
		sym = parent != null ? originOf(parent) : null;
		depth += 1;
	}
	return null;
}

function derivesFrom(cls: Symbol, owner: Symbol): boolean {
	let c: Symbol | null = cls;
	let depth = 0;
	while (c != null && depth < 64) {
		if (originOf(c) == owner) return true;
		c = parentClassSymOf(c);
		depth += 1;
	}
	return false;
}

function enclosingGrant(ctx: CheckerContext, owner: Symbol, protectedMember: boolean): Symbol | null {
	let scope: Scope | null = ctx.table.current;
	while (scope != null) {
		const granted = scope.privateAccess;
		if (granted != null) {
			const cls = originOf(granted);
			if (cls == owner || (protectedMember && derivesFrom(cls, owner))) return cls;
		}
		scope = scope.parent;
	}
	return null;
}

function reportClassMember(ctx: CheckerContext, owner: Symbol, name: string, what: string, protectedMember: boolean, receiver: Symbol | null, line: int32, column: int32): boolean {
	const through = enclosingGrant(ctx, owner, protectedMember);
	if (through == null) {
		const where = protectedMember ? "inside that class and its subclasses" : "inside that class";
		addError(ctx, `'${name}' is a ${protectedMember ? "protected" : "private"} ${what} of class '${owner.name}' and is only accessible ${where}`, line, column);
		return true;
	}
	if (!protectedMember || receiver == null || derivesFrom(originOf(receiver), through)) return false;
	addError(ctx, `'${name}' is a protected ${what} of class '${owner.name}' and is only accessible through an instance of class '${through.name}'; this is an instance of class '${originOf(receiver).name}'`, line, column);
	return true;
}

function befriends(ctx: CheckerContext, modulePath: string): boolean {
	let scope: Scope | null = ctx.table.current;
	while (scope != null) {
		if (scope.friendModules.indexOf(modulePath) >= 0) return true;
		scope = scope.parent;
	}
	return false;
}

export function befriend(ctx: CheckerContext, modules: string[]): Scope {
	const scope: Scope = ctx.table.current;
	for (const m of modules) scope.friendModules.push(m);
	return scope;
}

export function unfriend(scope: Scope, modules: string[]): void {
	for (let i = 0; i < modules.length; i += 1) scope.friendModules.pop();
}

const noFriends: string[] = [];

export function expansionFriendsOf(ctx: CheckerContext, node: Node): string[] {
	if (ctx.expansionFriends.size == 0) return noFriends;
	const friends = ctx.expansionFriends.get(node);
	return friends != null ? friends : noFriends;
}

export function markExpansion(ctx: CheckerContext, node: Node | null, friends: string[]): void {
	if (node != null && friends.length > 0) ctx.expansionFriends.set(node, friends);
}

export function expansionOf(ctx: CheckerContext, origin: Node, macroModule: string): string[] {
	const inherited = expansionFriendsOf(ctx, origin);
	const friends: string[] = [];
	for (const m of inherited) friends.push(m);
	if (macroModule != "") friends.push(macroModule);
	return friends;
}

function isProtectedMember(owner: Symbol, name: string): boolean {
	return isClassLike(owner) && ownVisibility(owner, name) == DeclaredVisibility.Protected;
}

function structFieldVisible(ctx: CheckerContext, owner: Symbol): boolean {
	return owner.modulePath == ctx.modulePath || befriends(ctx, owner.modulePath);
}

export function methodOwnerClass(ctx: CheckerContext, method: Symbol): Symbol | null {
	const decl = unwrapDecl(method.declNode);
	if (decl == null || decl.kind != NodeKind.MethodDecl || ctx.extensionRegistry == null) return null;
	for (const ext of ctx.extensionRegistry.methods) {
		if (ext.sym != method) continue;
		const owner = lookupSymbol(ctx.table, ext.receiverTypeName);
		return owner != null && isClassLike(owner) ? owner : null;
	}
	return null;
}

export function refusePrivateField(ctx: CheckerContext, typeSym: Symbol | null, field: string, line: int32, column: int32): boolean {
	return refuseMemberAccess(ctx, typeSym, field, typeSym, line, column);
}

export function refuseMemberAccess(ctx: CheckerContext, typeSym: Symbol | null, field: string, receiver: Symbol | null, line: int32, column: int32): boolean {
	const owner = privateFieldOwner(typeSym, field);
	if (owner == null) return false;
	if (isClassLike(owner)) return reportClassMember(ctx, owner, field, "field", isProtectedMember(owner, field), receiver, line, column);
	if (structFieldVisible(ctx, owner)) return false;
	addError(ctx, `'${field}' is a private field of '${owner.name}' and is only accessible in the module that declares it`, line, column);
	return true;
}

export function hiddenPrivateField(ctx: CheckerContext, typeSym: Symbol | null, fields: string[]): string {
	for (const f of fields) {
		const owner = privateFieldOwner(typeSym, f);
		if (owner == null) continue;
		const visible = isClassLike(owner)
			? enclosingGrant(ctx, owner, isProtectedMember(owner, f)) != null
			: structFieldVisible(ctx, owner);
		if (!visible) return f;
	}
	return "";
}

export function declaringSymOf(t: Type | null): Symbol | null {
	let cur = t;
	let depth = 0;
	while (cur != null && depth < 16) {
		if (cur.kind == TypeKind.GenericInstance && cur.typeExtra != null) {
			cur = cur.typeExtra;
		} else if ((cur.kind == TypeKind.Ref || cur.kind == TypeKind.Ptr || cur.kind == TypeKind.Alias) && cur.typeReturn != null && cur.sym == null) {
			cur = cur.typeReturn;
		} else {
			return cur.sym;
		}
		depth += 1;
	}
	return null;
}

export function firstPrivateField(typeSym: Symbol | null, fields: string[]): string {
	for (const f of fields) {
		if (privateFieldOwner(typeSym, f) != null) return f;
	}
	return "";
}

function methodClass(ctx: CheckerContext, method: Symbol): Symbol | null {
	const t = method.symbolType;
	const decl = unwrapDecl(method.declNode);
	if (decl != null && decl.kind == NodeKind.MethodDecl) {
		const md = decl.data as MethodDeclData;
		if (!md.methodIsStatic && t != null && t.kind == TypeKind.Function && t.typeChildren != null && t.typeChildren.length > 0) {
			const receiver = declaringSymOf(t.typeChildren[0]);
			if (receiver != null && isClassLike(receiver)) return originOf(receiver);
		}
	}
	const owner = methodOwnerClass(ctx, method);
	return owner != null ? originOf(owner) : null;
}

export function refuseHiddenMethodCall(ctx: CheckerContext, call: Node): void {
	if (call.kind != NodeKind.CallExpr) return;
	const callee = (call.data as CallExprData).callee;
	if (callee == null || callee.resolvedSym == null) return;
	const method = originOf(callee.resolvedSym);
	const decl = unwrapDecl(method.declNode);
	if (decl == null || decl.kind != NodeKind.MethodDecl) return;
	const md = decl.data as MethodDeclData;
	const vis = memberVisibility(md.methodVisibility);
	if (vis != DeclaredVisibility.Private && vis != DeclaredVisibility.Protected) return;
	const owner = methodClass(ctx, method);
	if (owner == null) return;
	const receiver = md.methodIsStatic ? null : receiverClassOf(callee);
	reportClassMember(ctx, owner, md.methodName, "method", vis == DeclaredVisibility.Protected, receiver, call.location.line, call.location.column);
}

export function isSuperReceiver(object: Node): boolean {
	return object.kind == NodeKind.Identifier && (object.data as IdentifierData).name == "super";
}

function receiverClassOf(callee: Node): Symbol | null {
	if (callee.kind != NodeKind.MemberExpr) return null;
	const object = (callee.data as MemberExprData).object;
	if (object == null || isSuperReceiver(object)) return null;
	return declaringSymOf(object.nodeType);
}
