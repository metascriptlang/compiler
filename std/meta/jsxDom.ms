// jsxDom — reference JSX → DOM-tree macro.
//
// JSX in MetaScript is pure AST: the compiler produces JSXElement/JSXText/... `Node`s but
// assigns no meaning. A macro decides what `<div>` means. `jsxDom` makes it mean "build a
// DomNode tree": it rewrites JSX into plain `el()/txt()/attr()` runtime calls at compile time
// (the same idea as React's JSX → React.createElement, but the translation lives in userland).
//
//   const v = jsxDom(<div id="app">Hello</div>);
//   //  ↓ expands at compile time to
//   const v = el("div", [attr("id", "app")], [txt("Hello")]);
//
// Copy this file as a starting point for your own JSX target (virtual DOM, SSR string, etc.).

import { Node, NodeKind } from "std/meta";

// ===== Runtime DOM model — what the macro emits calls to (ordinary functions) =====

export interface DomAttr { name: string; value: string; }
export interface DomNode { tag: string; attrs: DomAttr[]; kids: DomNode[]; text: string; }

export function attr(name: string, value: string): DomAttr {
	return { name, value };
}
export function el(tag: string, attrs: DomAttr[], kids: DomNode[]): DomNode {
	return { tag, attrs, kids, text: "" };
}
export function txt(s: string): DomNode {
	return { tag: "", attrs: [], kids: [], text: s };
}

// Serialize a built tree back to an HTML-ish string (for tests / debugging).
export function render(n: DomNode): string {
	if (n.tag === "") { return n.text; }
	let s = "<" + n.tag;
	for (const a of n.attrs) { s = s + " " + a.name + "=\"" + a.value + "\""; }
	s = s + ">";
	for (const k of n.kids) { s = s + render(k); }
	return s + "</" + n.tag + ">";
}

// ===== The macro: JSXElement Node → el(...) CallExpr Node =====
//
// Everything is built INLINE in the macro body. Macro helper functions cannot navigate JSX
// (`Node` has no flat `jsxChildren` field outside the macro body) nor build flat node literals
// (`{kind, line, column, ...}` is only accepted in a macro's return position) — so a recursive
// `buildElement()` helper, as a JSX framework would write, does not type-check here.
//
// Recursion is therefore via RE-EXPANSION: a nested <Element/> child is emitted as a fresh
// `jsxDom(child)` call, which the macro expander re-walks. String attributes and text/`{expr}`
// children are handled; bare-boolean / non-string attribute values are left to a real target.

export macro jsxDom(node: Node): Node {
	let attrEls: Node[] = [];
	for (const a of node.jsxAttrs) {
		if (a.kind === NodeKind.JSXAttribute) {
			attrEls.push({
				kind: NodeKind.CallExpr, line: a.line, column: a.column,
				callee: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "attr" },
				arguments: [
					{ kind: NodeKind.StringLiteral, line: a.line, column: a.column, value: a.jsxAttrName },
					a.jsxAttrValue,
				],
			});
		}
	}

	let kidEls: Node[] = [];
	for (const c of node.jsxChildren) {
		if (c.kind === NodeKind.JSXText) {
			kidEls.push({
				kind: NodeKind.CallExpr, line: c.line, column: c.column,
				callee: { kind: NodeKind.Identifier, line: c.line, column: c.column, name: "txt" },
				arguments: [{ kind: NodeKind.StringLiteral, line: c.line, column: c.column, value: c.jsxText }],
			});
		} else if (c.kind === NodeKind.JSXExpressionContainer) {
			kidEls.push({
				kind: NodeKind.CallExpr, line: c.line, column: c.column,
				callee: { kind: NodeKind.Identifier, line: c.line, column: c.column, name: "txt" },
				arguments: [c.jsxExpr],
			});
		} else if (c.kind === NodeKind.JSXElement) {
			kidEls.push({
				kind: NodeKind.CallExpr, line: c.line, column: c.column,
				callee: { kind: NodeKind.Identifier, line: c.line, column: c.column, name: "jsxDom" },
				arguments: [c],
			});
		}
	}

	return {
		kind: NodeKind.CallExpr, line: node.line, column: node.column,
		callee: { kind: NodeKind.Identifier, line: node.line, column: node.column, name: "el" },
		arguments: [
			{ kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: node.jsxTag },
			{ kind: NodeKind.ArrayLiteral, line: node.line, column: node.column, elements: attrEls },
			{ kind: NodeKind.ArrayLiteral, line: node.line, column: node.column, elements: kidEls },
		],
	};
}
