// Assignability — the one relation every write site asks (Nim parampatterns.isAssignable)
//
// A write lands in the storage of the lvalue's root unless a step on the way
// reaches through a reference: `.field` / `[i]` on a Ptr, Ref, Var, class,
// interface or T[] writes the pointee, which the root binding does not own.
// Otherwise the root decides: a `const` owns its value to the last field,
// and a value parameter or a for-of binding is a read-only view of the
// caller's storage. Rebinding a parameter (CK-18) or a loop binding (CK-30)
// stays legal. A Borrow<T> root refuses every write, through a reference too.

import { Node, NodeKind, IdentifierData, MemberExprData, ArrayAccessData, BinaryExprData, HiddenDerefData, HiddenStdConvData, OutExprData, TypeAssertionData, Type, TypeKind, TypeFlag, Symbol, SymbolKind } from "../ast/node";
import { SymbolFlag, hasFlag } from "./symbol";
import { isReadonlyView, isAtomicRef, isStringLike, isNumeric, isSendableFunction, isMaybeType } from "./types";
import { isValueAggregateParam } from "./paramMutationAnalysis";
import { nonNullMemberOfNullable } from "./compat";

export enum WriteVerdict {
	Writable,
	ConstRebind,
	ConstInterior,
	ValueParamInterior,
	ForVarInterior,
	BorrowView,
}

export enum WriteSite {
	Assign,
	RefArg,
	CPointer,
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
		TypeKind.Union => t.typeFlags.has(TypeFlag.ValueUnion),
		TypeKind.Alias | TypeKind.Distinct => isDeclaredValueStorage(t.typeReturn),
		_ => holdsInlineValue(t),
	};
}

function holdsInlineValue(t: Type | null): boolean {
	if (t == null) return false;
	return match (t.kind) {
		TypeKind.Struct => t.sym != null && t.sym.symbolKind == SymbolKind.Struct,
		TypeKind.GenericInstance => t.typeExtra != null && holdsInlineValue(t.typeExtra),
		TypeKind.SizedArray => true,
		TypeKind.Alias | TypeKind.Distinct => holdsInlineValue(t.typeReturn),
		_ => false,
	};
}

export function isFrozenByConst(t: Type | null): boolean {
	return frozenAt(t, false, 0);
}

function frozenAt(t: Type | null, inGenericBody: boolean, depth: int32): boolean {
	if (t == null || depth > 8) return false;
	if (isNumeric(t)) return true;
	return match (t.kind) {
		TypeKind.Boolean | TypeKind.BooleanLiteral | TypeKind.NumberLiteral | TypeKind.Char
			| TypeKind.String | TypeKind.StringLiteral | TypeKind.Enum | TypeKind.EnumLiteral | TypeKind.Null => true,
		TypeKind.GenericParam => inGenericBody,
		TypeKind.Function => isSendableFunction(t),
		TypeKind.Array | TypeKind.SizedArray | TypeKind.Distinct | TypeKind.Alias => frozenAt(t.typeReturn, inGenericBody, depth + 1),
		TypeKind.Struct => isDeclaredValueStorage(t) && t.typeChildren.every((f: Type): boolean => frozenAt(f, inGenericBody, depth + 1)),
		TypeKind.GenericInstance => isDeclaredValueStorage(t) && frozenAt(t.typeExtra, true, depth + 1)
			&& t.typeChildren.every((a: Type): boolean => frozenAt(a, inGenericBody, depth + 1)),
		TypeKind.Union => frozenUnion(t, inGenericBody, depth),
		_ => false,
	};
}

function frozenUnion(t: Type, inGenericBody: boolean, depth: int32): boolean {
	let aggregates = 0;
	let nulls = 0;
	for (const m of t.typeChildren) {
		if (!frozenAt(m, inGenericBody, depth + 1)) return false;
		if (m.kind == TypeKind.Null) nulls += 1;
		else if (!isNumeric(m) && m.kind != TypeKind.String && m.kind != TypeKind.StringLiteral && m.kind != TypeKind.Boolean
				&& m.kind != TypeKind.BooleanLiteral && m.kind != TypeKind.NumberLiteral && m.kind != TypeKind.Enum && m.kind != TypeKind.EnumLiteral) aggregates += 1;
	}
	return aggregates == 0 || (aggregates == 1 && nulls == 1 && t.typeChildren.length == 2);
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

function borrowRoot(target: Node): Symbol | null {
	let cur: Node = target;
	while (cur.kind != NodeKind.Identifier) {
		if (cur.kind == NodeKind.MemberExpr) cur = (cur.data as MemberExprData).object;
		else if (cur.kind == NodeKind.ArrayAccess) cur = (cur.data as ArrayAccessData).array;
		else if (cur.kind == NodeKind.HiddenDeref) cur = (cur.data as HiddenDerefData).expr;
		else return null;
	}
	const sym = cur.resolvedSym;
	return sym != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.Borrow ? sym : null;
}

function valueBehindNull(t: Type | null): Type | null {
	if (t != null && isMaybeType(t) && t.typeReturn != null) return t.typeReturn;
	return nonNullMemberOfNullable(t) ?? t;
}

function sameStorageOperand(n: Node): Node | null {
	if (n.kind == NodeKind.TypeAssertion) return (n.data as TypeAssertionData).asExpr;
	if (n.kind == NodeKind.OutExpr) return (n.data as OutExprData).outArg;
	if ((n.kind == NodeKind.HiddenSubConv || n.kind == NodeKind.HiddenStdConv)
			&& n.nodeType != null && (n.nodeType.kind == TypeKind.Struct || n.nodeType.kind == TypeKind.Tuple)) {
		return (n.data as HiddenStdConvData).convExpr;
	}
	return null;
}

export function checkWrite(target: Node, site: WriteSite): WriteCheck {
	const borrowed = borrowRoot(target);
	if (borrowed != null) return { verdict: WriteVerdict.BorrowView, root: borrowed };
	const asRefArg = site == WriteSite.RefArg || site == WriteSite.CPointer;
	let cur: Node = target;
	let interior = false;
	let deep = true;
	if (site == WriteSite.View || site == WriteSite.Receiver) {
		cur = sliceSource(target);
		if (!isValueContainer(cur.nodeType)) return { verdict: WriteVerdict.Writable, root: null };
		interior = true;
	}
	while (cur.kind != NodeKind.Identifier) {
		const operand = sameStorageOperand(cur);
		if (operand != null) {
			if (!isDeclaredValueStorage(valueBehindNull(operand.nodeType))) deep = false;
			cur = operand;
			continue;
		}
		let base: Node | null = null;
		if (cur.kind == NodeKind.MemberExpr) base = (cur.data as MemberExprData).object;
		else if (cur.kind == NodeKind.ArrayAccess) base = sliceSource((cur.data as ArrayAccessData).array);
		const held = base != null ? valueBehindNull(base.nodeType) : null;
		if (base == null || !isValueAggregateParam(held)) return { verdict: WriteVerdict.Writable, root: null };
		interior = true;
		if (!isDeclaredValueStorage(held)) deep = false;
		cur = base;
	}
	const sym = cur.resolvedSym;
	if (sym == null || (reachesThroughReference(sym) && (interior || sym.symbolType.kind == TypeKind.Var))) return { verdict: WriteVerdict.Writable, root: sym };
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
	if (node.kind == NodeKind.HiddenDeref) return lvalueText((node.data as HiddenDerefData).expr);
	return "…";
}

export function viewRefusal(source: Node, slot: Type | null): string | null {
	if (slot == null || slot.kind != TypeKind.Span || isReadonlyView(slot)) return null;
	const root = sliceSource(source);
	if (isStringLike(root.nodeType)) {
		return `cannot view '${lvalueText(root)}' as a writable Span — a string is immutable; a view that only reads is Readonly<Span<T>>`;
	}
	return writeRefusal(source, WriteSite.View);
}

export function writeRefusal(target: Node, site: WriteSite, method: string = ""): string | null {
	const w = checkWrite(target, site);
	if (w.root == null || w.verdict == WriteVerdict.Writable) return null;
	const name = w.root.name;
	const text = lvalueText(target);
	const what = match (site) {
		WriteSite.RefArg => `pass '${text}' to a 'ref' parameter`,
		WriteSite.CPointer => `pass '${text}' to a non-const C pointer parameter`,
		WriteSite.Receiver => `mutate '${text}' with '${method}'`,
		WriteSite.View => `view '${text}' as a writable Span`,
		WriteSite.Assign => w.verdict == WriteVerdict.ConstRebind || target.kind == NodeKind.Identifier ? `assign to '${name}'` : `write '${text}'`,
	};
	const refusal = match (w.verdict) {
		WriteVerdict.ConstRebind | WriteVerdict.ConstInterior => `cannot ${what} — '${name}' is const (use 'let')`,
		WriteVerdict.ValueParamInterior => `cannot mutate value-type parameter '${name}': value parameters are read-only views; copy it locally first`,
		WriteVerdict.ForVarInterior => `cannot mutate value-type loop variable '${name}': for-of binds a per-iteration copy; iterate by index to mutate the collection`,
		WriteVerdict.BorrowView => `cannot ${what} — '${name}' is a read-only Borrow<T> view; to write, change what it was taken from or take a 'ref' parameter instead`,
		WriteVerdict.Writable => { throw new Error("internal: writeRefusal reached a Writable verdict"); },
	};
	return site == WriteSite.View ? refusal + "; a view that only reads is Readonly<Span<T>>" : refusal;
}

