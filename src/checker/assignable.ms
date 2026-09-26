// Assignability — the one relation every write site asks (Nim parampatterns.isAssignable)
//
// A write lands in the storage of the lvalue's root unless a step on the way
// reaches through a reference: `.field` / `[i]` on a Ptr, Ref, Var, class,
// interface or T[] writes the pointee, which the root binding does not own.
// Otherwise the root decides: a `const` owns its value to the last field,
// and a value parameter or a for-of binding is a read-only view of the
// caller's storage. Rebinding a parameter (CK-18) or a loop binding (CK-30)
// stays legal. Mutating methods on those views are still found by name in
// paramMutationAnalysis until method receivers become ordinary arguments.

import { Node, NodeKind, IdentifierData, MemberExprData, ArrayAccessData, Type, TypeKind, Symbol, SymbolKind } from "../ast/node";
import { SymbolFlag, hasFlag } from "./symbol";
import { isValueAggregateParam } from "./paramMutationAnalysis";

export enum WriteVerdict {
	Writable,
	ConstRebind,
	ConstInterior,
	ValueParamInterior,
	ForVarInterior,
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
		TypeKind.Struct => t.sym != null && t.sym.symbolKind == SymbolKind.Struct,
		TypeKind.GenericInstance => t.typeExtra != null && isDeclaredValueStorage(t.typeExtra),
		TypeKind.SizedArray | TypeKind.Array => true,
		_ => false,
	};
}

function reachesThroughReference(sym: Symbol): boolean {
	const t = sym.symbolType;
	if (t == null) return false;
	return t.kind == TypeKind.Var || t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr;
}

// `asRefArg`: the lvalue is handed to a `ref` formal, which may write any of it
// and rebind it.
export function checkWrite(target: Node, asRefArg: boolean): WriteCheck {
	let cur: Node = target;
	let interior = false;
	let deep = true;
	while (cur.kind != NodeKind.Identifier) {
		let base: Node | null = null;
		if (cur.kind == NodeKind.MemberExpr) base = (cur.data as MemberExprData).object;
		else if (cur.kind == NodeKind.ArrayAccess) base = (cur.data as ArrayAccessData).array;
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

export function lvalueText(node: Node): string {
	if (node.kind == NodeKind.Identifier) return (node.data as IdentifierData).name;
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		return lvalueText(d.object) + "." + d.property;
	}
	if (node.kind == NodeKind.ArrayAccess) return lvalueText((node.data as ArrayAccessData).array) + "[…]";
	return "…";
}

export function writeRefusal(target: Node, asRefArg: boolean): string {
	const w = checkWrite(target, asRefArg);
	if (w.root == null) return "";
	const name = w.root.name;
	const what = asRefArg ? `pass '${lvalueText(target)}' to a 'ref' parameter` : w.verdict == WriteVerdict.ConstRebind ? `assign to '${name}'` : `write '${lvalueText(target)}'`;
	return match (w.verdict) {
		WriteVerdict.ConstRebind | WriteVerdict.ConstInterior => `cannot ${what} — '${name}' is const (use 'let')`,
		WriteVerdict.ValueParamInterior => `cannot mutate value-type parameter '${name}': value parameters are read-only views; copy it locally first`,
		WriteVerdict.ForVarInterior => `cannot mutate value-type loop variable '${name}': for-of binds a per-iteration copy; iterate by index to mutate the collection`,
		_ => "",
	};
}
