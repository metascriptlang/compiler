// Reactive classification for JSX attribute values and expression children,
// read by the element macro — tests/render/emit.test.ms pins it.
//
// Reactive ⟺ the expression syntactically contains a call. Solid's rule reads
// "a property read is reactive", which holds there only because its props are
// proxy getters; Neon props are plain values, so a read of one can never
// re-run and only a call can.
//
// Children are reached through childCount/childAt (std/meta) rather than named
// fields: flat field names resolve only inside an engine-mode check, so a
// helper callable from a macro body cannot use them at top level. Every
// non-child field of the kinds below is a string, so "recurse into all
// children" is exactly the field list this replaced.

import { Node, NodeKind, childCount, childAt } from "std/meta";

function anyChildReactive(n: Node): boolean {
	const c = childCount(n);
	for (let i = 0; i < c; i = i + 1) {
		if (isReactiveExpr(childAt(n, i))) { return true; }
	}
	return false;
}

export function isReactiveExpr(n: Node): boolean {
	if (n === null) { return false; }
	const k = n.kind;
	// A macro argument arrives lowered — a bare `props.child` sits inside a
	// HiddenDeref — so the wrappers must be transparent, not classified.
	if (k === NodeKind.HiddenDeref || k === NodeKind.HiddenAddr
		|| k === NodeKind.HiddenStdConv || k === NodeKind.HiddenSubConv) {
		return anyChildReactive(n);
	}
	if (k === NodeKind.Identifier) { return false; }
	if (k === NodeKind.StringLiteral) { return false; }
	if (k === NodeKind.NumberLiteral) { return false; }
	if (k === NodeKind.BooleanLiteral) { return false; }
	if (k === NodeKind.NullLiteral) { return false; }
	if (k === NodeKind.MemberExpr || k === NodeKind.BinaryExpr || k === NodeKind.UnaryExpr
		|| k === NodeKind.ArrayAccess || k === NodeKind.TypeAssertion
		|| k === NodeKind.ConditionalExpr) {
		return anyChildReactive(n);
	}
	return true;
}

export function peelHidden(n: Node): Node {
	let cur = n;
	while (cur.kind === NodeKind.HiddenDeref || cur.kind === NodeKind.HiddenAddr
		|| cur.kind === NodeKind.HiddenStdConv || cur.kind === NodeKind.HiddenSubConv) {
		if (childCount(cur) === 0) { return cur; }
		cur = childAt(cur, 0);
	}
	return cur;
}

export function isEventName(name: string): boolean {
	return name.startsWith("on") && name.charAt(2) >= "A" && name.charAt(2) <= "Z";
}

export function findSpreadAttr(n: Node): Node | null {
	if (n === null) { return null; }
	if (n.kind === NodeKind.JSXSpreadAttribute) { return n; }
	const c = childCount(n);
	for (let i = 0; i < c; i = i + 1) {
		const found = findSpreadAttr(childAt(n, i));
		if (found !== null) { return found; }
	}
	return null;
}
