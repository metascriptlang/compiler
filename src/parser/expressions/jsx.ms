// JSX expression parser (docs/JSX-ROADMAP.md Phase 3): consumes the lexer's JSX token stream
// into the 6 JSX AST kinds. The lexer already resolved `<` disambiguation, so this is straight
// recursive descent with no lookahead. `parseExpr` is threaded in from parsePrimary (a callback,
// to avoid an import cycle with core.ms) for `{expr}` containers and attribute values.

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, Expression, createNode,
	JSXElementData, JSXFragmentData, JSXTextData,
	JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData } from "../../ast/node";
import { ParserState, current, advance, isAtEnd } from "../context";
import { exprNode, exprKind, parseOk } from "./util";

type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: number) => ExprResult;

// Tag/closing name flattened to a string ("Foo.Bar", "svg:rect") — macros split it at expansion
// time, so member/namespace names need no dedicated NodeKind.
function parseJsxName(state: ParserState): Result<string, string> {
	if (current(state).kind !== TokenKind.Ident) {
		return Result.err(`Expected JSX tag name at line ${current(state).line}`);
	}
	let name = current(state).value;
	advance(state);
	while (!isAtEnd(state) && current(state).kind === TokenKind.Dot) {
		advance(state);
		if (current(state).kind !== TokenKind.Ident) return Result.err("Expected name after '.' in JSX tag");
		name = name + "." + current(state).value;
		advance(state);
	}
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		if (current(state).kind !== TokenKind.Ident) return Result.err("Expected name after ':' in JSX tag");
		name = name + ":" + current(state).value;
		advance(state);
	}
	return Result.ok(name);
}

function parseJsxAttributes(state: ParserState, parseExpr: ExprParser): Result<Node[], string> {
	const attrs: Node[] = [];
	while (!isAtEnd(state)) {
		const tok = current(state);
		const k = tok.kind;
		if (k === TokenKind.Slash || k === TokenKind.Gt) break;

		if (k === TokenKind.LBrace) {
			advance(state);
			if (current(state).kind !== TokenKind.DotDotDot) return Result.err("Expected '...' in JSX spread attribute");
			advance(state);
			const arg = try parseExpr(state, 0);
			if (current(state).kind !== TokenKind.RBrace) return Result.err("Expected '}' after JSX spread attribute");
			advance(state);
			attrs.push(createNode(NodeKind.JSXSpreadAttribute, { jsxSpreadArg: arg }, tok));
			continue;
		}

		if (k === TokenKind.Ident) {
			let attrName = tok.value;
			advance(state);
			if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
				advance(state);
				attrName = attrName + ":" + current(state).value;
				advance(state);
			}
			let valNode: Node;
			if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
				advance(state);
				const vk = current(state).kind;
				if (vk === TokenKind.String) {
					const sTok = current(state);
					advance(state);
					valNode = createNode(NodeKind.StringLiteral, { value: sTok.value }, sTok);
				} else if (vk === TokenKind.LBrace) {
					advance(state);
					valNode = try parseExpr(state, 0);
					if (current(state).kind !== TokenKind.RBrace) return Result.err("Expected '}' after JSX attribute expression");
					advance(state);
				} else {
					return Result.err("Expected string or '{' for JSX attribute value");
				}
			} else {
				valNode = createNode(NodeKind.BooleanLiteral, { boolValue: true }, tok);
			}
			attrs.push(createNode(NodeKind.JSXAttribute, { jsxAttrName: attrName, jsxAttrValue: valNode }, tok));
			continue;
		}

		return Result.err(`Unexpected token in JSX attributes at line ${tok.line}`);
	}
	return Result.ok(attrs);
}

function parseJsxChildren(state: ParserState, parseExpr: ExprParser): Result<Node[], string> {
	const children: Node[] = [];
	while (!isAtEnd(state)) {
		const tok = current(state);
		const k = tok.kind;
		if (k === TokenKind.JsxClose) break;

		if (k === TokenKind.JsxText) {
			advance(state);
			children.push(createNode(NodeKind.JSXText, { jsxText: tok.value }, tok));
			continue;
		}
		if (k === TokenKind.JsxTagStart) {
			const child = try parseJsxRoot(state, parseExpr);
			children.push(child);
			continue;
		}
		if (k === TokenKind.LBrace) {
			advance(state);
			// empty `{}` carries no expression — drop it so walkers never see a null jsxExpr
			if (current(state).kind === TokenKind.RBrace) { advance(state); continue; }
			const expr = try parseExpr(state, 0);
			if (current(state).kind !== TokenKind.RBrace) return Result.err("Expected '}' in JSX expression container");
			advance(state);
			children.push(createNode(NodeKind.JSXExpressionContainer, { jsxExpr: expr }, tok));
			continue;
		}
		return Result.err(`Unexpected token in JSX children at line ${tok.line}`);
	}
	if (isAtEnd(state)) return Result.err("Unterminated JSX element (missing closing tag)");
	return Result.ok(children);
}

function parseJsxClose(state: ParserState): Result<string, string> {
	if (current(state).kind !== TokenKind.JsxClose) return Result.err("Expected JSX closing tag");
	advance(state);
	const name = try parseJsxName(state);
	if (current(state).kind !== TokenKind.Gt) return Result.err("Expected '>' in JSX closing tag");
	advance(state);
	return Result.ok(name);
}

function parseJsxElement(state: ParserState, parseExpr: ExprParser, start: Token): ExprResult {
	const tag = try parseJsxName(state);
	const attrs = try parseJsxAttributes(state, parseExpr);

	if (current(state).kind === TokenKind.Slash) {
		advance(state);
		if (current(state).kind !== TokenKind.Gt) return Result.err("Expected '>' after '/' in self-closing JSX element");
		advance(state);
		return Result.ok(createNode(NodeKind.JSXElement, { jsxTag: tag, jsxAttrs: attrs, jsxChildren: [], jsxSelfClosing: true }, start));
	}

	if (current(state).kind !== TokenKind.Gt) return Result.err("Expected '>' or '/>' to end JSX opening tag");
	advance(state);
	const children = try parseJsxChildren(state, parseExpr);
	const closeTag = try parseJsxClose(state);
	if (closeTag !== tag) return Result.err(`JSX closing tag </${closeTag}> does not match <${tag}>`);
	return Result.ok(createNode(NodeKind.JSXElement, { jsxTag: tag, jsxAttrs: attrs, jsxChildren: children, jsxSelfClosing: false }, start));
}

function parseJsxFragment(state: ParserState, parseExpr: ExprParser, start: Token): ExprResult {
	advance(state);
	const children = try parseJsxChildren(state, parseExpr);
	if (current(state).kind !== TokenKind.JsxClose) return Result.err("Expected '</>' to close JSX fragment");
	advance(state);
	if (current(state).kind !== TokenKind.Gt) return Result.err("Expected '>' after '</' in fragment close");
	advance(state);
	return Result.ok(createNode(NodeKind.JSXFragment, { jsxFragChildren: children }, start));
}

export function parseJsxRoot(state: ParserState, parseExpr: ExprParser): ExprResult {
	const start = current(state);
	advance(state);
	if (current(state).kind === TokenKind.Gt) {
		return parseJsxFragment(state, parseExpr, start);
	}
	return parseJsxElement(state, parseExpr, start);
}

// ===== JSX Parser Tests (docs/JSX-ROADMAP.md Phase 3) =====

test "jsx parse self-closing element" {
	assert exprKind("<a/>") === NodeKind.JSXElement;
	const d = exprNode("<a/>").data as JSXElementData;
	assert d.jsxTag === "a";
	assert d.jsxSelfClosing;
	assert d.jsxChildren.length === 0;
	assert d.jsxAttrs.length === 0;
}

test "jsx parse element with text child" {
	const d = exprNode("<p>hi</p>").data as JSXElementData;
	assert d.jsxTag === "p";
	assert !d.jsxSelfClosing;
	assert d.jsxChildren.length === 1;
	assert d.jsxChildren[0].kind === NodeKind.JSXText;
	assert (d.jsxChildren[0].data as JSXTextData).jsxText === "hi";
}

test "jsx parse fragment" {
	assert exprKind("<></>") === NodeKind.JSXFragment;
	assert (exprNode("<></>").data as JSXFragmentData).jsxFragChildren.length === 0;
	assert (exprNode("<><a/></>").data as JSXFragmentData).jsxFragChildren.length === 1;
}

test "jsx parse string attribute" {
	const d = exprNode("<a href=\"x\"/>").data as JSXElementData;
	assert d.jsxAttrs.length === 1;
	assert d.jsxAttrs[0].kind === NodeKind.JSXAttribute;
	const a = d.jsxAttrs[0].data as JSXAttributeData;
	assert a.jsxAttrName === "href";
	assert a.jsxAttrValue.kind === NodeKind.StringLiteral;
}

test "jsx parse expression attribute" {
	const a = (exprNode("<a x={y}/>").data as JSXElementData).jsxAttrs[0].data as JSXAttributeData;
	assert a.jsxAttrName === "x";
	assert a.jsxAttrValue.kind === NodeKind.Identifier;
}

test "jsx parse bare attribute is boolean true" {
	const a = (exprNode("<input disabled/>").data as JSXElementData).jsxAttrs[0].data as JSXAttributeData;
	assert a.jsxAttrName === "disabled";
	assert a.jsxAttrValue.kind === NodeKind.BooleanLiteral;
}

test "jsx parse spread attribute" {
	const d = exprNode("<a {...p}/>").data as JSXElementData;
	assert d.jsxAttrs[0].kind === NodeKind.JSXSpreadAttribute;
	assert (d.jsxAttrs[0].data as JSXSpreadAttributeData).jsxSpreadArg.kind === NodeKind.Identifier;
}

test "jsx parse expression container child" {
	const d = exprNode("<p>{x}</p>").data as JSXElementData;
	assert d.jsxChildren.length === 1;
	assert d.jsxChildren[0].kind === NodeKind.JSXExpressionContainer;
	assert (d.jsxChildren[0].data as JSXExpressionContainerData).jsxExpr.kind === NodeKind.Identifier;
}

test "jsx parse nested element" {
	const d = exprNode("<a><b/></a>").data as JSXElementData;
	assert d.jsxChildren.length === 1;
	assert d.jsxChildren[0].kind === NodeKind.JSXElement;
	assert (d.jsxChildren[0].data as JSXElementData).jsxTag === "b";
}

test "jsx parse member and namespace tag names" {
	assert (exprNode("<Foo.Bar/>").data as JSXElementData).jsxTag === "Foo.Bar";
	assert (exprNode("<svg:rect/>").data as JSXElementData).jsxTag === "svg:rect";
}

test "jsx parse multiple attributes" {
	assert (exprNode("<a x=\"1\" y=\"2\"/>").data as JSXElementData).jsxAttrs.length === 2;
}

test "jsx parse text element text mix" {
	const d = exprNode("<p>a<b/>c</p>").data as JSXElementData;
	assert d.jsxChildren.length === 3;
	assert d.jsxChildren[0].kind === NodeKind.JSXText;
	assert d.jsxChildren[1].kind === NodeKind.JSXElement;
	assert d.jsxChildren[2].kind === NodeKind.JSXText;
}

test "jsx parse element inside expression container" {
	const c = (exprNode("<p>{<b/>}</p>").data as JSXElementData).jsxChildren[0].data as JSXExpressionContainerData;
	assert c.jsxExpr.kind === NodeKind.JSXElement;
}

test "jsx parse empty expression container is dropped" {
	assert (exprNode("<p>{}</p>").data as JSXElementData).jsxChildren.length === 0;
}

test "jsx parse rejects mismatched closing tag" {
	assert !parseOk("<a></b>");
}

test "jsx parse accepts valid forms" {
	assert parseOk("<a/>");
	assert parseOk("<a>x</a>");
	assert parseOk("<></>");
	assert parseOk("<a b=\"c\" {...d}>{e}</a>");
}

test "jsx parse empty element" {
	const d = exprNode("<a></a>").data as JSXElementData;
	assert !d.jsxSelfClosing;
	assert d.jsxChildren.length === 0;
}

test "jsx parse preserves whitespace text children (raw, macro decides)" {
	const d = exprNode("<a> <b/> </a>").data as JSXElementData;
	assert d.jsxChildren.length === 3;
	assert (d.jsxChildren[0].data as JSXTextData).jsxText === " ";
	assert d.jsxChildren[1].kind === NodeKind.JSXElement;
	assert (d.jsxChildren[2].data as JSXTextData).jsxText === " ";
}
