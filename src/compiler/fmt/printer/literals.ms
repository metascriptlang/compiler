// Literal Printers — number, string, boolean, identifier

import {
	Node,
	NumberLiteralData, StringLiteralData, BooleanLiteralData, IdentifierData,
} from "../../../ast/node";
import { FormatOptions } from "../options";
import { Doc, docText } from "../doc";

export function printNumberLiteral(node: Node): Doc {
	const d = node.data as NumberLiteralData;
	return docText(d.value.toString());
}

export function printStringLiteral(node: Node, options: FormatOptions): Doc {
	const d = node.data as StringLiteralData;
	let q = "\"";
	if (options.singleQuote) { q = "'"; }
	return docText(q + d.value + q);
}

export function printBooleanLiteral(node: Node): Doc {
	const d = node.data as BooleanLiteralData;
	if (d.boolValue) return docText("true");
	return docText("false");
}

export function printIdentifier(node: Node): Doc {
	const d = node.data as IdentifierData;
	return docText(d.name);
}
