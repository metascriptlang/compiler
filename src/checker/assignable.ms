// Assignability — the one relation every write site asks (Nim parampatterns.isAssignable)
//
// A write lands in the storage of the lvalue's root unless a step on the way
// reaches through a reference: `.field` / `[i]` on a Ptr, Ref, Var, class,
// interface or T[] writes the pointee, which the root binding does not own.
// Otherwise the root decides: a `const` owns its value to the last field,
// and a value parameter or a for-of binding is a read-only view of the
// caller's storage. Rebinding a parameter (CK-18) or a loop binding (CK-30)
// stays legal.

import { Node, NodeKind, IdentifierData, MemberExprData, ArrayAccessData, BinaryExprData, HiddenDerefData, OutExprData, TypeAssertionData, Type, TypeKind, Symbol, SymbolKind } from "../ast/node";
import { SymbolFlag, hasFlag } from "./symbol";
import { isReadonlyView, isAtomicRef, isSharedGraphType, isNodeGraphType, isStringLike } from "./types";
import { isValueAggregateParam } from "./paramMutationAnalysis";

export enum WriteVerdict {
	Writable,
	ConstRebind,
	ConstInterior,
	ValueParamInterior,
	ForVarInterior,
}

export enum WriteSite {
	Assign,
	RefArg,
	Receiver,
	View,
}

export struct WriteCheck {
	verdict: WriteVerdict;
	root: Symbol | null;
}

// Const is deep only through storage a declaration makes a value: a declared
// `struct` (its symbol is SymbolKind.Struct), `T[N]` and `Vec<T>`. An object
// `type {…}`, an interface or a class shares TypeKind.Struct but is declared
// by alias or interface, so a const of one only fixes the binding (CK-91).
function isDeclaredValueStorage(t: Type | null): boolean {
	if (t == null) return false;
	return match (t.kind) {
		TypeKind.GenericInstance => t.typeExtra != null && isDeclaredValueStorage(t.typeExtra),
		TypeKind.Array => true,
		_ => holdsInlineValue(t),
	};
}

function holdsInlineValue(t: Type | null): boolean {
	if (t == null) return false;
	return match (t.kind) {
		TypeKind.Struct => t.sym != null && t.sym.symbolKind == SymbolKind.Struct,
		TypeKind.GenericInstance => t.typeExtra != null && holdsInlineValue(t.typeExtra),
		TypeKind.SizedArray => true,
		_ => false,
	};
}

function reachesThroughReference(sym: Symbol): boolean {
	const t = sym.symbolType;
	if (t == null) return false;
	return t.kind == TypeKind.Var || t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr;
}

function sliceSource(node: Node): Node {
	let cur = node;
	while (cur.kind == NodeKind.ArrayAccess) {
		const d = cur.data as ArrayAccessData;
		if (d.index == null || d.index.kind != NodeKind.BinaryExpr || (d.index.data as BinaryExprData).operator != "..") break;
		cur = d.array;
	}
	return cur;
}

function isValueContainer(t: Type | null): boolean {
	return t != null && (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray);
}

export function checkWrite(target: Node, site: WriteSite): WriteCheck {
	const asRefArg = site == WriteSite.RefArg;
	let cur: Node = target;
	let interior = false;
	let deep = true;
	if (site == WriteSite.View || site == WriteSite.Receiver) {
		cur = sliceSource(target);
		if (!isValueContainer(cur.nodeType)) return { verdict: WriteVerdict.Writable, root: null };
		interior = true;
	}
	while (cur.kind != NodeKind.Identifier) {
		let base: Node | null = null;
		if (cur.kind == NodeKind.MemberExpr) base = (cur.data as MemberExprData).object;
		else if (cur.kind == NodeKind.ArrayAccess) base = sliceSource((cur.data as ArrayAccessData).array);
		if (base == null || !isValueAggregateParam(base.nodeType)) return { verdict: WriteVerdict.Writable, root: null };
		interior = true;
		if (!isDeclaredValueStorage(base.nodeType)) deep = false;
		cur = base;
	}
	const sym = cur.resolvedSym;
	if (sym == null || reachesThroughReference(sym)) return { verdict: WriteVerdict.Writable, root: sym };
	const viewInterior = interior || (asRefArg && isValueAggregateParam(target.nodeType));
	if (hasFlag(sym, SymbolFlag.ForVar)) return { verdict: viewInterior ? WriteVerdict.ForVarInterior : WriteVerdict.Writable, root: sym };
	if (sym.symbolKind == SymbolKind.Variable && !hasFlag(sym, SymbolFlag.Mutable)) {
		if (!interior) return { verdict: WriteVerdict.ConstRebind, root: sym };
		if (deep) return { verdict: WriteVerdict.ConstInterior, root: sym };
		return { verdict: WriteVerdict.Writable, root: sym };
	}
	if (viewInterior && sym.symbolKind == SymbolKind.Parameter) return { verdict: WriteVerdict.ValueParamInterior, root: sym };
	return { verdict: WriteVerdict.Writable, root: sym };
}

export function isLocation(node: Node): boolean {
	if (node.kind == NodeKind.Identifier || node.kind == NodeKind.HiddenDeref) return true;
	if (node.kind == NodeKind.OutExpr) return isLocation((node.data as OutExprData).outArg);
	let base: Node | null = null;
	if (node.kind == NodeKind.MemberExpr) base = (node.data as MemberExprData).object;
	else if (node.kind == NodeKind.ArrayAccess) base = (node.data as ArrayAccessData).array;
	if (base == null) return false;
	return !holdsInlineValue(base.nodeType) || isLocation(base);
}

// PARALOCK Amendment I — SHARE is immutable: no write may reach through an
// Arc<T> handle. Peels the member/index chain of a write target; the write
// passes through every prefix's deref, so an Arc at ANY prefix position (the
// root receiver `a.f = 1`, an interior field `holder.box.n = 1`, an indexed
// element `a.arr[i] = 1`) makes the whole write shared-state mutation.
// Writing the handle SLOT itself (`holder.box = otherArc`) is not affected —
// its prefixes stop at `holder`. Member access through a Ref inserts
// HiddenDeref (the deref node's type is the pointee), so the Arc test is
// applied to the deref's inner expression, not the deref node.
export function writeThroughArc(target: Node): boolean {
	let cur: Node | null = target;
	while (cur != null) {
		if (cur.kind == NodeKind.MemberExpr) {
			const o = (cur.data as MemberExprData).object;
			if (o != null && o.nodeType != null && isAtomicRef(o.nodeType)) return true;
			cur = o;
		} else if (cur.kind == NodeKind.ArrayAccess) {
			const a = (cur.data as ArrayAccessData).array;
			if (a != null && a.nodeType != null && isAtomicRef(a.nodeType)) return true;
			cur = a;
		} else if (cur.kind == NodeKind.HiddenDeref) {
			const e = (cur.data as HiddenDerefData).expr;
			if (e != null && e.nodeType != null && isAtomicRef(e.nodeType)) return true;
			cur = e;
		} else {
			break;
		}
	}
	return false;
}

export function writeThroughGraphBackedge(target: Node): boolean {
	let cur: Node | null = target;
	while (cur != null) {
		let base: Node | null = null;
		if (cur.kind == NodeKind.MemberExpr) base = (cur.data as MemberExprData).object;
		else if (cur.kind == NodeKind.ArrayAccess) base = (cur.data as ArrayAccessData).array;
		else if (cur.kind == NodeKind.HiddenDeref) base = (cur.data as HiddenDerefData).expr;
		else if (cur.kind == NodeKind.TypeAssertion) base = (cur.data as TypeAssertionData).asExpr;
		else break;
		if (base != null && base.nodeType != null && cur.nodeType != null
				&& isSharedGraphType(base.nodeType) && isNodeGraphType(cur.nodeType)
				&& cur != target) return true;
		cur = base;
	}
	return false;
}

export function readonlyPrefixType(target: Node): Type | null {
	let cur: Node | null = target;
	while (cur != null) {
		let base: Node | null = null;
		if (cur.kind == NodeKind.MemberExpr) base = (cur.data as MemberExprData).object;
		else if (cur.kind == NodeKind.ArrayAccess) base = (cur.data as ArrayAccessData).array;
		else if (cur.kind == NodeKind.HiddenDeref) base = (cur.data as HiddenDerefData).expr;
		else break;
		if (base != null && base.nodeType != null && isReadonlyView(base.nodeType)) return base.nodeType;
		cur = base;
	}
	return null;
}

export function readonlyRootType(target: Node): Type | null {
	if (target.kind == NodeKind.Identifier && isReadonlyView(target.nodeType)) return target.nodeType;
	return readonlyPrefixType(target);
}

export function lvalueText(node: Node): string {
	if (node.kind == NodeKind.Identifier) return (node.data as IdentifierData).name;
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		return lvalueText(d.object) + "." + d.property;
	}
	if (node.kind == NodeKind.ArrayAccess) return lvalueText((node.data as ArrayAccessData).array) + "[…]";
	return "…";
}

export function viewRefusal(source: Node, slot: Type | null): string {
	if (slot == null || slot.kind != TypeKind.Span || isReadonlyView(slot)) return "";
	const root = sliceSource(source);
	if (isStringLike(root.nodeType)) {
		return `cannot view '${lvalueText(root)}' as a writable Span — a string is immutable; a view that only reads is Readonly<Span<T>>`;
	}
	return writeRefusal(source, WriteSite.View);
}

export function writeRefusal(target: Node, site: WriteSite, method: string = ""): string {
	const w = checkWrite(target, site);
	if (w.root == null || w.verdict == WriteVerdict.Writable) return "";
	const name = w.root.name;
	const text = lvalueText(target);
	const what = match (site) {
		WriteSite.RefArg => `pass '${text}' to a 'ref' parameter`,
		WriteSite.Receiver => `mutate '${text}' with '${method}'`,
		WriteSite.View => `view '${text}' as a writable Span`,
		WriteSite.Assign => w.verdict == WriteVerdict.ConstRebind ? `assign to '${name}'` : `write '${text}'`,
	};
	const refusal = match (w.verdict) {
		WriteVerdict.ConstRebind | WriteVerdict.ConstInterior => `cannot ${what} — '${name}' is const (use 'let')`,
		WriteVerdict.ValueParamInterior => `cannot mutate value-type parameter '${name}': value parameters are read-only views; copy it locally first`,
		WriteVerdict.ForVarInterior => `cannot mutate value-type loop variable '${name}': for-of binds a per-iteration copy; iterate by index to mutate the collection`,
		WriteVerdict.Writable => "",
	};
	return site == WriteSite.View ? refusal + "; a view that only reads is Readonly<Span<T>>" : refusal;
}
