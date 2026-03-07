// Expression Printers — binary, unary, call, member, literals (object/array), etc.

import {
	Node,
	BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData,
	ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ArrowFunctionData,
	ConditionalExprData, SpreadExprData, NewExprData, TypeAssertionData,
	MatchExprData, MatchCaseData,
} from "../../../ast/node";
import { FormatOptions } from "../options";
import {
	Doc, docText, docGroup, docIndent,
	docLine, docSoftLine, docJoin,
} from "../doc";
import { callPrintNode } from "./callbacks";

export function printBinaryExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as BinaryExprData;
	return docGroup([
		callPrintNode(d.left, options),
		docText(" " + d.operator + " "),
		docIndent([docSoftLine(), callPrintNode(d.right, options)]),
	]);
}

export function printUnaryExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as UnaryExprData;
	return docGroup([docText(d.unaryOp), callPrintNode(d.operand, options)]);
}

export function printCallExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as CallExprData;
	const args: Doc[] = [];
	for (const arg of d.arguments) {
		args.push(callPrintNode(arg, options));
	}

	return docGroup([
		callPrintNode(d.callee, options),
		docText("("),
		docIndent([
			docSoftLine(),
			docJoin(args, docGroup([docText(","), docLine()])),
		]),
		docSoftLine(),
		docText(")"),
	]);
}

export function printMemberExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as MemberExprData;
	let op = ".";
	if (d.isOptional) { op = "?."; }
	return docGroup([
		callPrintNode(d.object, options),
		docText(op + d.property),
	]);
}

export function printUpdateExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as UpdateExprData;
	if (d.isPrefix) {
		return docGroup([docText(d.updateOp), callPrintNode(d.updateArg, options)]);
	}
	return docGroup([callPrintNode(d.updateArg, options), docText(d.updateOp)]);
}

export function printArrayAccess(node: Node, options: FormatOptions): Doc {
	const d = node.data as ArrayAccessData;
	return docGroup([
		callPrintNode(d.array, options),
		docText("["),
		callPrintNode(d.index, options),
		docText("]"),
	]);
}

export function printObjectLiteral(node: Node, options: FormatOptions): Doc {
	const d = node.data as ObjectLiteralData;
	if (d.keys.length === 0) return docText("{}");
	const entries: Doc[] = [];
	for (let i = 0; i < d.keys.length; i += 1) {
		if (d.keys[i] !== "") {
			entries.push(docGroup([
				docText(d.keys[i] + ": "),
				callPrintNode(d.properties[i], options),
			]));
		} else {
			entries.push(callPrintNode(d.properties[i], options));
		}
	}
	return docGroup([
		docText("{"),
		docIndent([
			docLine(),
			docJoin(entries, docGroup([docText(","), docLine()])),
		]),
		docLine(),
		docText("}"),
	]);
}

export function printArrayLiteral(node: Node, options: FormatOptions): Doc {
	const d = node.data as ArrayLiteralData;
	if (d.elements.length === 0) return docText("[]");
	const elems: Doc[] = [];
	for (const el of d.elements) {
		elems.push(callPrintNode(el, options));
	}
	return docGroup([
		docText("["),
		docIndent([
			docSoftLine(),
			docJoin(elems, docGroup([docText(","), docLine()])),
		]),
		docSoftLine(),
		docText("]"),
	]);
}

export function printArrowFunction(node: Node, options: FormatOptions): Doc {
	const d = node.data as ArrowFunctionData;
	const params: Doc[] = [];
	for (let i = 0; i < d.arrowParams.length; i += 1) {
		let p = d.arrowParams[i];
		if (d.arrowParamTypes[i] !== "") {
			p = p + ": " + d.arrowParamTypes[i];
		}
		params.push(docText(p));
	}
	const parts: Doc[] = [docText("(")];
	parts.push(docJoin(params, docGroup([docText(","), docLine()])));
	parts.push(docText(")"));
	if (d.arrowReturnType !== "") {
		parts.push(docText(": " + d.arrowReturnType));
	}
	parts.push(docText(" => "));
	parts.push(callPrintNode(d.arrowBody, options));
	return docGroup(parts);
}

export function printConditionalExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as ConditionalExprData;
	return docGroup([
		callPrintNode(d.ternaryCondition, options),
		docIndent([
			docLine(),
			docText("? "),
			callPrintNode(d.ternaryConsequent, options),
			docLine(),
			docText(": "),
			callPrintNode(d.ternaryAlternate, options),
		]),
	]);
}

export function printSpreadExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as SpreadExprData;
	return docGroup([docText("..."), callPrintNode(d.spreadArg, options)]);
}

export function printNewExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as NewExprData;
	const args: Doc[] = [];
	for (const arg of d.newArguments) {
		args.push(callPrintNode(arg, options));
	}
	return docGroup([
		docText("new "),
		callPrintNode(d.newCallee, options),
		docText("("),
		docIndent([
			docSoftLine(),
			docJoin(args, docGroup([docText(","), docLine()])),
		]),
		docSoftLine(),
		docText(")"),
	]);
}

export function printTypeAssertion(node: Node, options: FormatOptions): Doc {
	const d = node.data as TypeAssertionData;
	return docGroup([
		callPrintNode(d.asExpr, options),
		docText(" as " + d.asType),
	]);
}

export function printMatchExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as MatchExprData;
	const cases: Doc[] = [];
	for (const c of d.matchCases) {
		cases.push(printMatchCase(c, options));
	}
	return docGroup([
		docText("match ("),
		callPrintNode(d.matchDisc, options),
		docText(") {"),
		docIndent([docSoftLine(), docJoin(cases, docSoftLine())]),
		docSoftLine(),
		docText("}"),
	]);
}

export function printMatchCase(node: Node, options: FormatOptions): Doc {
	const d = node.data as MatchCaseData;
	const pats: Doc[] = [];
	for (const p of d.casePatterns) {
		pats.push(callPrintNode(p, options));
	}
	return docGroup([
		docJoin(pats, docText(" | ")),
		docText(" => "),
		callPrintNode(d.caseBody, options),
		docText(","),
	]);
}
