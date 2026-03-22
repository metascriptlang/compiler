// Expression Printers — binary, unary, call, member, literals (object/array), etc.

import {
	Node, NodeKind,
	BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData,
	ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ArrowFunctionData,
	ConditionalExprData, SpreadExprData, NewExprData, TypeAssertionData,
	MatchExprData, MatchCaseData, TryExprData, MoveExprData,
} from "../../../ast/node";
import { Token } from "../../../lexer/token";
import { FormatOptions } from "../options";
import {
	Doc, docText, docGroup, docGroupBreak, docIndent,
	docLine, docSoftLine, docHardLine, docIfBreak, docNil, docBreakParent, docJoin, docJoinFlat,
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

	// Force multi-line: objects with 2+ properties, nested complex values,
	// or internal comments (commented-out properties) always expand.
	let forceBreak = d.keys.length >= 2;
	if (!forceBreak) {
		for (const prop of d.properties) {
			if (prop !== null && (prop.kind === NodeKind.ObjectLiteral || prop.kind === NodeKind.ArrayLiteral || prop.kind === NodeKind.ArrowFunction)) {
				forceBreak = true;
			}
			if (prop !== null && prop.comments.length > 0) {
				forceBreak = true;
			}
		}
	}
	// Also check the object node itself for trailing comments
	if (!forceBreak && node.comments.length > 0) {
		forceBreak = true;
	}

	const entries: Doc[] = [];
	for (let i = 0; i < d.keys.length; i += 1) {
		const prop = d.properties[i];
		// Extract leading comments (e.g., commented-out properties) and group them
		// with the following entry so they don't get separator commas.
		const leadingComments: Doc[] = [];
		if (prop !== null && prop.comments.length > 0) {
			const remaining: Token[] = [];
			for (const comment of prop.comments) {
				if (comment.line < prop.location.line) {
					leadingComments.push(docText(comment.value));
					leadingComments.push(docHardLine());
				} else {
					remaining.push(comment);
				}
			}
			prop.comments = remaining;
		}
		let entryDoc: Doc;
		if (d.keys[i] !== "") {
			// Detect shorthand: key === identifier name → emit just the key
			const isShorthand = prop !== null && prop.kind === NodeKind.Identifier
				&& (prop.data as { name: string }).name === d.keys[i];
			if (isShorthand) {
				entryDoc = docText(d.keys[i]);
			} else {
				entryDoc = docGroup([
					docText(d.keys[i] + ": "),
					callPrintNode(prop, options),
				]);
			}
		} else {
			entryDoc = callPrintNode(prop, options);
		}
		if (leadingComments.length > 0) {
			leadingComments.push(entryDoc);
			entries.push(docGroup(leadingComments));
		} else {
			entries.push(entryDoc);
		}
	}
	// Collect trailing comments on the object node (before closing brace)
	const trailingComments: Doc[] = [];
	if (node.comments.length > 0) {
		for (const comment of node.comments) {
			trailingComments.push(docText(comment.value));
		}
		node.comments = [];
	}

	// When forced to break, separators must not be wrapped in a group
	// (groups measure independently and would flatten comma+line to comma+space)
	const sep = forceBreak
		? [docText(","), docHardLine()]
		: [docGroup([docText(","), docLine()])];
	const indentChildren: Doc[] = [docLine()];
	for (let i = 0; i < entries.length; i += 1) {
		if (i > 0) {
			for (const s of sep) { indentChildren.push(s); }
		}
		indentChildren.push(entries[i]);
	}
	indentChildren.push(docIfBreak(docNil(), docText(",")));
	// Append trailing comments after entries (on their own lines)
	for (const tc of trailingComments) {
		indentChildren.push(docLine());
		indentChildren.push(tc);
	}

	const inner: Doc[] = [
		docText("{"),
		docIndent(indentChildren),
		docLine(),
		docText("}"),
	];
	if (forceBreak) {
		return docGroupBreak(inner);
	}
	return docGroup(inner);
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
	const parts: Doc[] = [docJoin(pats, docText(" | "))];
	if (d.caseGuard !== null) {
		parts.push(docText(" when "));
		parts.push(callPrintNode(d.caseGuard, options));
	}
	parts.push(docText(" => "));
	parts.push(callPrintNode(d.caseBody, options));
	parts.push(docText(","));
	return docGroup(parts);
}

export function printTryExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as TryExprData;
	const parts: Doc[] = [docText("try "), callPrintNode(d.tryArg, options)];
	if (d.hasCatch && d.catchVal !== null) {
		parts.push(docText(" catch "));
		parts.push(callPrintNode(d.catchVal, options));
	}
	return docGroup(parts);
}

export function printMoveExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as MoveExprData;
	return docGroup([docText("move "), callPrintNode(d.moveArg, options)]);
}
