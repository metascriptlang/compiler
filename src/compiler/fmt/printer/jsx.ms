import {
	Node, NodeKind,
	JSXElementData, JSXFragmentData, JSXTextData, JSXExpressionContainerData,
	JSXAttributeData, JSXSpreadAttributeData,
} from "../../../ast/node";
import { FormatOptions } from "../options";
import { Doc, docText, docGroup, docIndent, docLine, docSoftLine } from "../doc";
import { callPrintNode } from "./callbacks";

function printJsxChildren(children: Node[], options: FormatOptions): Doc[] {
	const parts: Doc[] = [];
	for (const child of children) {
		parts.push(callPrintNode(child, options));
	}
	return parts;
}

function printJsxOpening(tag: string, attrs: Node[], closer: string, options: FormatOptions): Doc {
	const parts: Doc[] = [];
	for (const attr of attrs) {
		parts.push(docLine());
		parts.push(callPrintNode(attr, options));
	}
	const tail = closer == "/>" ? docLine() : docSoftLine();
	return docGroup([docText("<" + tag), docIndent(parts), tail, docText(closer)]);
}

export function printJsxElement(node: Node, options: FormatOptions): Doc {
	const d = node.data as JSXElementData;
	if (d.jsxSelfClosing) {
		return printJsxOpening(d.jsxTag, d.jsxAttrs, "/>", options);
	}
	const parts: Doc[] = [printJsxOpening(d.jsxTag, d.jsxAttrs, ">", options)];
	for (const child of printJsxChildren(d.jsxChildren, options)) {
		parts.push(child);
	}
	parts.push(docText("</" + d.jsxTag + ">"));
	return docGroup(parts);
}

export function printJsxFragment(node: Node, options: FormatOptions): Doc {
	const d = node.data as JSXFragmentData;
	const parts: Doc[] = [docText("<>")];
	for (const child of printJsxChildren(d.jsxFragChildren, options)) {
		parts.push(child);
	}
	parts.push(docText("</>"));
	return docGroup(parts);
}

export function printJsxText(node: Node): Doc {
	return docText((node.data as JSXTextData).jsxText);
}

export function printJsxExpressionContainer(node: Node, options: FormatOptions): Doc {
	const d = node.data as JSXExpressionContainerData;
	return docGroup([docText("{"), callPrintNode(d.jsxExpr, options), docText("}")]);
}

export function printJsxAttribute(node: Node, options: FormatOptions): Doc {
	const d = node.data as JSXAttributeData;
	const value = d.jsxAttrValue;
	const isBare = value.kind == NodeKind.BooleanLiteral && value.location.line == node.location.line && value.location.column == node.location.column;
	if (isBare) return docText(d.jsxAttrName);
	if (value.kind == NodeKind.StringLiteral) {
		return docGroup([docText(d.jsxAttrName + "="), callPrintNode(value, options)]);
	}
	return docGroup([docText(d.jsxAttrName + "={"), callPrintNode(value, options), docText("}")]);
}

export function printJsxSpreadAttribute(node: Node, options: FormatOptions): Doc {
	const d = node.data as JSXSpreadAttributeData;
	return docGroup([docText("{..."), callPrintNode(d.jsxSpreadArg, options), docText("}")]);
}
