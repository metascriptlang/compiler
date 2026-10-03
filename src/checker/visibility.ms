import { Node, NodeKind, Symbol, SymbolKind, Type, TypeKind, ClassDeclData, PropertyDeclData, MethodDeclData, DecoratedDeclData, ExportDeclData, InterfaceDeclData, CallExprData } from "../ast/node";
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

function grantsPrivateAccess(ctx: CheckerContext, owner: Symbol, protectedMember: boolean): boolean {
	let scope: Scope | null = ctx.table.current;
	while (scope != null) {
		const granted = scope.privateAccess;
		if (granted != null && (originOf(granted) == owner || (protectedMember && derivesFrom(originOf(granted), owner)))) return true;
		scope = scope.parent;
	}
	return false;
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

export function fieldVisible(ctx: CheckerContext, owner: Symbol, name: string): boolean {
	if (isClassLike(owner)) return grantsPrivateAccess(ctx, owner, isProtectedMember(owner, name));
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
	const owner = privateFieldOwner(typeSym, field);
	if (owner == null || fieldVisible(ctx, owner, field)) return false;
	if (isProtectedMember(owner, field)) {
		addError(ctx, `'${field}' is a protected field of class '${owner.name}' and is only accessible inside that class and its subclasses`, line, column);
	} else if (isClassLike(owner)) {
		addError(ctx, `'${field}' is a private field of class '${owner.name}' and is only accessible inside that class`, line, column);
	} else {
		addError(ctx, `'${field}' is a private field of '${owner.name}' and is only accessible in the module that declares it`, line, column);
	}
	return true;
}

export function hiddenPrivateField(ctx: CheckerContext, typeSym: Symbol | null, fields: string[]): string {
	for (const f of fields) {
		const owner = privateFieldOwner(typeSym, f);
		if (owner != null && !fieldVisible(ctx, owner, f)) return f;
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
	if (owner == null || grantsPrivateAccess(ctx, owner, vis == DeclaredVisibility.Protected)) return;
	const what = vis == DeclaredVisibility.Protected ? "protected" : "private";
	const where = vis == DeclaredVisibility.Protected ? "inside that class and its subclasses" : "inside that class";
	addError(ctx, `'${md.methodName}' is a ${what} method of class '${owner.name}' and is only accessible ${where}`, call.location.line, call.location.column);
}
