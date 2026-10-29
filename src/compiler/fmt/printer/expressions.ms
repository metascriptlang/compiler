// Expression Printers — binary, unary, call, member, literals (object/array), etc.

import {
	Node, NodeKind, NodeFlag,
	BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData,
	ArrayAccessData, HiddenDerefData, ObjectLiteralData, ComputedPropertyData, ArrayLiteralData, ArrowFunctionData,
	ConditionalExprData, SpreadExprData, TypeAssertionData,
	MatchExprData, MatchCaseData, TryExprData, MoveExprData,
	OutExprData, SizeofExprData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	IdentifierData, NewExprData, MacroInvocationData, FunctionExprData, AwaitExprData, YieldExprData, BlockStmtData, ReturnStmtData,
} from "../../../ast/node";
import { isAssignOp } from "../../../ast/operators";
import { SourceComment } from "../comments";
import { withComments, danglingOf, hasCommentsOutside, commentLeadingBefore, commentLeading, commentTrailing, takeOwnLineTrailing, commentsOfRun } from "./commentDocs";
import { FormatOptions, CommaContext, wantsTrailingComma } from "../options";
import {
	Doc, docText, docSourceText, docGroup, docGroupBreak, docIndent,
	docLine, docSoftLine, docHardLine, docIfBreak, docNil, docJoin,
	docCommaSepList, docWithoutSoftLines, docWillBreak,
} from "../doc";
import { callPrintNode, printedAncestor } from "./callbacks";
import { AssignmentShape, printAssignmentLike, isShortKey } from "./assignment";
export { printConditionalExpr } from "./conditional";
import { rawTemplateAt, rawObjectKeyAt, rawGenericsAt, sourceByteAt } from "./literals";
import { flagHas, buildParamList, paramListInParens, hugsObjectParam, isParamPatternDecl, headerAsWritten, typedAsWritten, printCollapsibleBody } from "./statements";
import { printTypeAnnotation } from "./types";

export function printBinaryExpr(node: Node, options: FormatOptions): Doc {
	const template = rawTemplateAt(node, options);
	if (template != "") return docText(template);
	const d = node.data as BinaryExprData;
	if (isAssignOp(d.operator)) return printAssignmentExpr(node, options);
	if (!isBinaryLikeOp(d.operator)) {
		return docGroup([
			printBinaryOperand(d.left, d.operator, false, options),
			docText(" " + d.operator + " "),
			docIndent([docSoftLine(), printBinaryOperand(d.right, d.operator, true, options)]),
		]);
	}
	const spine: Node[] = [node];
	let bottom = node;
	while (true) {
		const left = (bottom.data as BinaryExprData).left;
		if (left == null || left.flags.has(NodeFlag.Parenthesized) || !isBinaryLike(left, options)) break;
		if (!shouldFlatten((bottom.data as BinaryExprData).operator, (left.data as BinaryExprData).operator)) break;
		spine.push(left);
		bottom = left;
	}
	const bd = bottom.data as BinaryExprData;
	const first = docGroup([printBinaryOperand(bd.left, bd.operator, false, options)]);
	const parent = printedAncestor(1);
	const tail: Doc[] = [];
	for (let i = spine.length - 1; i >= 0; i -= 1) {
		const sideParent = i == 0 ? parent : spine[i - 1];
		for (const part of binaryRightSide(spine[i], i > 0, sideParent, options)) tail.push(part);
	}
	if (bindsAsOperandHead(parent, node)) return docGroup([docIndent([docSoftLine(), first, ...tail]), docSoftLine()]);
	const arrowBody = parent != null && parent.kind == NodeKind.ArrowFunction
		&& (writtenArrowBody((parent.data as ArrowFunctionData).arrowBody, options) == node || (parent.data as ArrowFunctionData).arrowBody == node);
	const inlines = inlinesLogicalOperand(node);
	if (arrowBody || (inlines && spine.length == 1) || (!inlines && indentsItsValue(parent))) return docGroup([first, ...tail]);
	return docGroup([first, docIndent(tail)]);
}

function conditionalParentIndents(): boolean {
	const great = printedAncestor(2);
	return great != null && great.kind != NodeKind.ReturnStmt && great.kind != NodeKind.ThrowStmt && great.kind != NodeKind.CallExpr && great.kind != NodeKind.NewExpr;
}

function indentsItsValue(parent: Node | null): boolean {
	if (parent == null) return false;
	return match (parent.kind) {
		NodeKind.ConditionalExpr => conditionalParentIndents(),
		NodeKind.ObjectLiteral | NodeKind.ComputedProperty | NodeKind.VariableDecl | NodeKind.DestructuringDecl | NodeKind.PropertyDecl => true,
		_ => isAssignmentNode(parent),
	};
}

function isAssignmentNode(node: Node | null): boolean {
	return node != null && node.kind == NodeKind.BinaryExpr && isAssignOp((node.data as BinaryExprData).operator);
}

function assignmentChainEligible(node: Node, rightIsTail: boolean): boolean {
	const parent = printedAncestor(1);
	if (parent == null) return false;
	if (parent.kind == NodeKind.VariableDecl || parent.kind == NodeKind.DestructuringDecl) return !rightIsTail;
	if (parent.kind == NodeKind.PropertyDecl) return true;
	if (!isAssignmentNode(parent)) return false;
	const great = printedAncestor(2);
	return !rightIsTail || great == null || (great.kind != NodeKind.ExprStmt && great.kind != NodeKind.VariableDecl && great.kind != NodeKind.DestructuringDecl);
}

function printAssignmentExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as BinaryExprData;
	const shape: AssignmentShape = { leftIsShort: false, breakLeftHandSide: false, inChain: assignmentChainEligible(node, !isAssignmentNode(d.right)) };
	const left = printBinaryOperand(d.left, d.operator, false, options);
	return printAssignmentLike([left], " " + d.operator, d.right, printBinaryOperand(d.right, d.operator, true, options), shape, options);
}

function isBinaryLikeOp(op: string): boolean {
	return !isAssignOp(op) && op != "|>" && opPrecedence(op) != 0;
}

function isBinaryLike(node: Node, options: FormatOptions): boolean {
	return node.kind == NodeKind.BinaryExpr && isBinaryLikeOp((node.data as BinaryExprData).operator) && rawTemplateAt(node, options) == "";
}

function isLogicalOp(op: string): boolean {
	return op == "&&" || op == "||" || op == "??";
}

function shouldFlatten(parentOp: string, op: string): boolean {
	const prec = opPrecedence(op);
	if (prec != opPrecedence(parentOp) || parentOp == "**") return false;
	if (prec == EQUALITY_PREC || prec == SHIFT_PREC) return false;
	if (prec == MULTIPLICATIVE_PREC) return parentOp == op && op != "%";
	return true;
}

function inlinesLogicalOperand(node: Node): boolean {
	const d = node.data as BinaryExprData;
	if (!isLogicalOp(d.operator)) return false;
	return match (d.right.kind) {
		NodeKind.ObjectLiteral => (d.right.data as ObjectLiteralData).keys.length > 0,
		NodeKind.ArrayLiteral => (d.right.data as ArrayLiteralData).elements.length > 0,
		_ => false,
	};
}

function sharesBinaryKind(op: string, other: Node | null, options: FormatOptions): boolean {
	return other != null && isBinaryLike(other, options) && isLogicalOp((other.data as BinaryExprData).operator) == isLogicalOp(op);
}

function binaryRightSide(node: Node, isInner: boolean, parent: Node | null, options: FormatOptions): Doc[] {
	const d = node.data as BinaryExprData;
	const right = printBinaryOperand(d.right, d.operator, true, options);
	const side: Doc[] = inlinesLogicalOperand(node)
		? [docText(" " + d.operator + " "), right]
		: [docText(" " + d.operator), docLine(), right];
	const grouped = !(isInner || sharesBinaryKind(d.operator, parent, options)
		|| sharesBinaryKind(d.operator, d.left, options) || sharesBinaryKind(d.operator, d.right, options));
	const body: Doc[] = grouped ? [docGroup(side)] : side;
	if (!isInner) return body;
	return [...commentLeading(node), ...body, ...commentTrailing(node)];
}

function bindsAsOperandHead(parent: Node | null, node: Node): boolean {
	if (parent == null) return false;
	if (parent.kind == NodeKind.UnaryExpr) return (parent.data as UnaryExprData).operand == node;
	if (parent.kind == NodeKind.NewExpr) return (parent.data as NewExprData).newCallee == node;
	let cur: Node = parent;
	while (true) {
		const next = match (cur.kind) {
			NodeKind.CallExpr => (cur.data as CallExprData).callee,
			NodeKind.MemberExpr => (cur.data as MemberExprData).object,
			NodeKind.ArrayAccess => (cur.data as ArrayAccessData).array,
			_ => null,
		};
		if (next == null) return false;
		if (next == node) return cur.kind != NodeKind.ArrayAccess;
		cur = next;
	}
	return false;
}

// Wrap a binary operand in `(...)` when:
//   - child is also BinaryExpr AND its precedence < parent's, OR
//   - same precedence + parent is left-assoc + child is on the RIGHT, OR
//   - same precedence + parent is right-assoc + child is on the LEFT.
// Lower-precedence non-binary kinds (TypeAssertion, ConditionalExpr,
// AssignmentExpr-as-binary, etc.) are also wrapped via printAtom rules.
function printBinaryOperand(child: Node, parentOp: string, isRight: boolean, options: FormatOptions): Doc {
	if (child == null || child.flags.has(NodeFlag.Parenthesized) || rawTemplateAt(child, options) != "") return callPrintNode(child, options);
	if (child.kind == NodeKind.TypeAssertion && !isNonNullAssertion(child) && assertionNeedsParens(child, parentOp, isRight)) {
		return docGroup([docText("("), callPrintNode(child, options), docText(")")]);
	}
	if (child.kind != NodeKind.BinaryExpr) {
		return callPrintNode(child, options);
	}
	const cd = child.data as BinaryExprData;
	const childPrec = opPrecedence(cd.operator);
	const parentPrec = opPrecedence(parentOp);
	let needs = childPrec < parentPrec;
	if (childPrec == parentPrec) {
		const rightAssoc = isRightAssocOp(parentOp);
		if (rightAssoc && !isRight) needs = true;
		if (!rightAssoc && isRight) needs = true;
	}
	if (needs) {
		return docGroup([docText("("), callPrintNode(child, options), docText(")")]);
	}
	return callPrintNode(child, options);
}

const AS_PREC = 40;
const EQUALITY_PREC = 30;
const SHIFT_PREC = 45;
const MULTIPLICATIVE_PREC = 60;
const UNBOUND_PREC = 100;

// `as` binds at relational precedence, left to right; on the left a type would swallow `|`, `&` or `<`, and a
// bare binary operand of the assertion must not bind looser than the parent.
function assertionNeedsParens(child: Node, parentOp: string, isRight: boolean): boolean {
	const parentPrec = opPrecedence(parentOp);
	if (isRight) return parentPrec >= AS_PREC;
	return parentOp == "|" || parentOp == "&" || parentOp == "<" || bareBinaryPrec((child.data as TypeAssertionData).asExpr) < parentPrec;
}

function bareBinaryPrec(node: Node): number {
	if (node.kind != NodeKind.BinaryExpr || node.flags.has(NodeFlag.Parenthesized)) return UNBOUND_PREC;
	return opPrecedence((node.data as BinaryExprData).operator);
}

function opPrecedence(op: string): number {
	if (isAssignOp(op)) return 5;
	return match (op) {
		"**" => 65,
		"*" | "/" | "%" => 60,
		"+" | "-" => 50,
		"<<" | ">>" | ">>>" => 45,
		"<" | ">" | "<=" | ">=" | "in" | "instanceof" => 40,
		"==" | "!=" | "===" | "!==" => 30,
		"&" => 27,
		"^" => 25,
		"|" => 23,
		"&&" => 20,
		"||" => 10,
		"??" => 8,
		"|>" => 3,
		_ => 0,
	};
}

function isRightAssocOp(op: string): boolean {
	return op == "**" || isAssignOp(op);
}

export function printUnaryExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as UnaryExprData;
	const isWord = d.unaryOp == "typeof" || d.unaryOp == "void" || d.unaryOp == "delete";
	const op = isWord ? d.unaryOp + " " : d.unaryOp;
	if (d.operand != null && (d.operand.kind == NodeKind.AwaitExpr || (!isWord && bindsInsideUnary(d.unaryOp, d.operand)))) {
		return docGroup([docText(op), callPrintNode(d.operand, options)]);
	}
	return docGroup([docText(op), printAtom(d.operand, options)]);
}

function bindsInsideUnary(op: string, operand: Node): boolean {
	if (operand.kind == NodeKind.TypeAssertion) return true;
	if (operand.kind != NodeKind.UnaryExpr) return false;
	const inner = (operand.data as UnaryExprData).unaryOp;
	return !((op == "-" && inner == "-") || (op == "+" && inner == "+"));
}

export function writtenTypeArgs(node: Node, callee: Node, options: FormatOptions): string {
	if (node.typeArg == "") return "";
	let raw = "";
	if (callee != null && callee.location != null && callee.kind == NodeKind.Identifier) {
		raw = rawGenericsAt(options.source, callee.location.line, callee.location.column, (callee.data as IdentifierData).name);
	} else if (callee != null && callee.location != null && callee.kind == NodeKind.MemberExpr) {
		raw = rawGenericsAt(options.source, callee.location.line, callee.location.column, "." + (callee.data as MemberExprData).property);
	}
	return raw != "" ? raw : "<" + node.typeArg + ">";
}

export function listBody(items: Doc[], trailing: boolean, endComments: SourceComment[]): Doc[] {
	if (items.length == 0 && endComments.length == 0) return [];
	const body = docCommaSepList(items, trailing);
	for (const c of endComments) {
		body.push(docHardLine());
		body.push(docSourceText(c.text));
		c.markFormatted();
	}
	return [docIndent(body), docSoftLine()];
}

// printAtom: print a sub-expression that the parent needs to bind tighter
// than. For positions where the source grammar requires the child to be a
// PrimaryExpression/MemberExpression (e.g. .field object, call callee,
// arr[i] base, new ctor), low-precedence kinds like `as` need to be
// wrapped in `(...)` — otherwise re-parsing the formatted text yields a
// different AST.
//
// This list grows test-by-test; only kinds proven needed by a roundtrip
// test go in. See src/test/fmt/cases/.
export function printAtom(node: Node, options: FormatOptions): Doc {
	if (node != null && needsAtomParens(node.kind) && !isNonNullAssertion(node) && !node.flags.has(NodeFlag.Parenthesized) && rawTemplateAt(node, options) == "") {
		return docGroup([docText("("), callPrintNode(node, options), docText(")")]);
	}
	return callPrintNode(node, options);
}

export function isNonNullAssertion(node: Node): boolean {
	return node.kind == NodeKind.TypeAssertion && (node.data as TypeAssertionData).asType == "!";
}

function needsAtomParens(kind: NodeKind): boolean {
	return match (kind) {
		NodeKind.TypeAssertion |
		NodeKind.BinaryExpr |
		NodeKind.ConditionalExpr |
		NodeKind.UnaryExpr |
		NodeKind.UpdateExpr |
		NodeKind.ArrowFunction |
		NodeKind.AwaitExpr |
		NodeKind.YieldExpr |
		NodeKind.MoveExpr |
		NodeKind.TryExpr => true,
		_ => false,
	};
}

export function printUpdateExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as UpdateExprData;
	if (d.isPrefix) {
		return docGroup([docText(d.updateOp), callPrintNode(d.updateArg, options)]);
	}
	return docGroup([callPrintNode(d.updateArg, options), docText(d.updateOp)]);
}

export function printDerefExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as HiddenDerefData;
	return docGroup([printAtom(d.expr, options), docText("[]")]);
}

export function printArrayAccess(node: Node, options: FormatOptions): Doc {
	const d = node.data as ArrayAccessData;
	return docGroup([
		printAtom(d.array, options),
		docText(node.flags.has(NodeFlag.OptionalLink) ? "?.[" : "["),
		callPrintNode(d.index, options),
		docText("]"),
	]);
}

function objectProperty(left: Doc[], keyWidth: int32, value: Node, options: FormatOptions): Doc {
	const shape: AssignmentShape = { leftIsShort: isShortKey(keyWidth, options), breakLeftHandSide: false, inChain: false };
	return printAssignmentLike(left, ":", value, callPrintNode(value, options), shape, options);
}

// Check if an object key needs quoting — not a valid identifier (contains
// hyphens, dots, starts with digit, empty).
function needsQuote(key: string): boolean {
	if (key.length == 0) return true;
	const first = key.charCodeAt(0);
	if (!((first >= "a".code && first <= "z".code) || (first >= "A".code && first <= "Z".code) || first == "_".code || first == "$".code)) return true;
	let j = 1;
	while (j < key.length) {
		const ch = key.charCodeAt(j);
		if (!((ch >= "a".code && ch <= "z".code) || (ch >= "A".code && ch <= "Z".code) || (ch >= "0".code && ch <= "9".code) || ch == "_".code || ch == "$".code)) return true;
		j = j + 1;
	}
	return false;
}

export function printObjectLiteral(node: Node, options: FormatOptions): Doc {
	const d = node.data as ObjectLiteralData;
	if (d.keys.length == 0) return docText("{}");

	let forceBreak = d.keyLocations.length > 0 && d.keyLocations[0].line > node.location.line;
	for (const prop of d.properties) {
		if (prop != null && hasCommentsOutside(prop)) forceBreak = true;
	}
	if (danglingOf(node).length > 0) forceBreak = true;

	const entries: Doc[] = [];
	for (let i = 0; i < d.keys.length; i += 1) {
		const prop = d.properties[i];
		// Extract leading comments (e.g., commented-out properties) and group them
		// with the following entry so they don't get separator commas.
		const keyLoc = i < d.keyLocations.length ? d.keyLocations[i] : null;
		const leadingComments: Doc[] = prop != null && keyLoc != null ? commentLeadingBefore(prop, keyLoc) : [];
		let entryDoc: Doc;
		const writtenKey = i < d.keyLocations.length ? rawObjectKeyAt(options.source, d.keyLocations[i].line, d.keyLocations[i].column, options.singleQuote) : "";
		if (d.keys[i] == "..." || (prop != null && prop.kind == NodeKind.ComputedProperty)) {
			entryDoc = callPrintNode(prop, options);
		} else if (writtenKey != "") {
			entryDoc = prop != null ? objectProperty([docText(writtenKey)], writtenKey.length, prop, options) : docGroup([docText(writtenKey + ": "), callPrintNode(prop, options)]);
		} else if (d.keys[i] != "") {
			// Detect shorthand: key === identifier name → emit just the key
			const keyLoc = i < d.keyLocations.length ? d.keyLocations[i] : null;
			const isShorthand = prop != null && prop.kind == NodeKind.Identifier
				&& (prop.data as { name: string }).name == d.keys[i]
				&& (keyLoc == null || (keyLoc.line == prop.location.line && keyLoc.column == prop.location.column));
			if (isShorthand) {
				entryDoc = docText(d.keys[i]);
			} else {
				const keyStr = needsQuote(d.keys[i]) ? "\"" + d.keys[i] + "\"" : d.keys[i];
				entryDoc = prop != null ? objectProperty([docText(keyStr)], keyStr.length, prop, options) : docGroup([docText(keyStr + ": "), callPrintNode(prop, options)]);
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
	for (const entry of entries) {
		if (docWillBreak(entry)) forceBreak = true;
	}
	// Collect trailing comments on the object node (before closing brace)
	const trailingComments: Doc[] = [];
	for (const comment of danglingOf(node)) {
		trailingComments.push(docSourceText(comment.text));
		comment.markFormatted();
	}

	const indentChildren: Doc[] = [docLine()];
	for (let i = 0; i < entries.length; i += 1) {
		if (i > 0) {
			indentChildren.push(docText(","));
			indentChildren.push(docLine());
		}
		indentChildren.push(entries[i]);
	}
	if (wantsTrailingComma(options, CommaContext.Collection)) {
		indentChildren.push(docIfBreak(docText(","), docNil()));
	}
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
	const endComments = danglingOf(node);
	if (d.elements.length == 0 && endComments.length == 0) return docText("[]");
	const elems: Doc[] = [];
	for (const el of d.elements) {
		elems.push(callPrintNode(el, options));
	}
	const parts: Doc[] = [docText("[")];
	for (const p of listBody(elems, wantsTrailingComma(options, CommaContext.Collection), endComments)) parts.push(p);
	parts.push(docText("]"));
	return docGroup(parts);
}

export function writtenArrowBody(body: Node, options: FormatOptions): Node {
	if (body.kind != NodeKind.BlockStmt) return body;
	const at = sourceByteAt(options.source, body.location.line, body.location.column);
	if (at == "{".code || at == -1) return body;
	const stmts = (body.data as BlockStmtData).statements;
	const last = stmts.length > 0 ? stmts[stmts.length - 1] : null;
	if (last == null || last.kind != NodeKind.ReturnStmt) return body;
	for (let i = 0; i < stmts.length - 1; i += 1) {
		if (!isParamPatternDecl(stmts[i])) return body;
	}
	const arg = (last.data as ReturnStmtData).argument;
	return arg != null ? arg : body;
}

export interface FunctionPieces {
	head: Doc[];
	body: Doc;
	verbatimHead: boolean;
	inlineBody: boolean;
	conditionalBody: boolean;
	hasComments: boolean;
}

function ownLineLeading(node: Node): boolean {
	for (const c of commentsOfRun().leading(node)) {
		if (!c.formatted && c.linesBefore > 0) return true;
	}
	return false;
}

function leftmostIsObjectOrFunction(node: Node): boolean {
	let cur: Node | null = node;
	while (cur != null) {
		if (cur.flags.has(NodeFlag.Parenthesized)) return false;
		if (cur.kind == NodeKind.ObjectLiteral || cur.kind == NodeKind.FunctionExpr) return true;
		cur = match (cur.kind) {
			NodeKind.ConditionalExpr => (cur.data as ConditionalExprData).ternaryCondition,
			NodeKind.BinaryExpr => (cur.data as BinaryExprData).left,
			NodeKind.MemberExpr => (cur.data as MemberExprData).object,
			NodeKind.CallExpr => (cur.data as CallExprData).callee,
			NodeKind.ArrayAccess => (cur.data as ArrayAccessData).array,
			NodeKind.TypeAssertion => (cur.data as TypeAssertionData).asExpr,
			_ => null,
		};
	}
	return false;
}

export function arrowPieces(node: Node, options: FormatOptions): FunctionPieces {
	const d = node.data as ArrowFunctionData;
	const isAsync = flagHas(d.arrowFlags, "async") || flagHas(d.arrowFlags, "async_generator");
	const body = writtenArrowBody(d.arrowBody, options);
	const isBlock = body.kind == NodeKind.BlockStmt;
	const hasComments = hasCommentsOutside(node) || danglingOf(node).length > 0;
	const conditionalBody = body.kind == NodeKind.ConditionalExpr && !body.flags.has(NodeFlag.Parenthesized) && !leftmostIsObjectOrFunction(body);
	const inlineBody = !ownLineLeading(body) && (isBlock
		|| body.kind == NodeKind.ArrowFunction || body.kind == NodeKind.ArrayLiteral || body.kind == NodeKind.ObjectLiteral
		|| body.kind == NodeKind.JSXElement || body.kind == NodeKind.JSXFragment
		|| rawTemplateAt(body, options).includes("\n"));
	const writtenBlock = sourceByteAt(options.source, d.arrowBody.location.line, d.arrowBody.location.column) == "{".code;
	const asWritten = writtenBlock ? headerAsWritten(node, d.arrowBody, options, null) : null;
	if (asWritten != null) {
		return { head: [docText(isAsync ? "async " : ""), asWritten], body: printCollapsibleBody(body, options), verbatimHead: true, inlineBody, conditionalBody, hasComments };
	}
	const head: Doc[] = isAsync ? [docText("async ")] : [];
	const typed = d.arrowReturnType != "" ? typedAsWritten(node.location.line, node.location.column, node.typeExpr, options) : "";
	const params = buildParamList(d.arrowParams, d.arrowParamTypes, d.arrowDefaults, options, node.paramLocations, node.typeExprs);
	if (typed != "") {
		head.push(docText(typed));
	} else {
		for (const part of paramListInParens(params, options, hugsObjectParam(d.arrowParams, d.arrowParamTypes, d.arrowDefaults, node.typeExprs, options))) head.push(part);
	}
	if (typed == "" && d.arrowReturnType != "") {
		head.push(docText(": "));
		head.push(printTypeAnnotation(node.typeExpr, d.arrowReturnType, options));
	}
	const printed = isBlock ? printCollapsibleBody(body, options) : callPrintNode(body, options);
	return { head, body: printed, verbatimHead: false, inlineBody, conditionalBody, hasComments };
}

export enum ArgHug {
	None,
	First,
	Last,
}

export function assembleArrow(p: FunctionPieces, hug: ArgHug, options: FormatOptions): Doc {
	const head = hug == ArgHug.None ? p.head : headWithoutSoftLines(p.head);
	if (p.verbatimHead) return docGroup([...head, p.body]);
	if (p.inlineBody) return docGroup([...head, docText(" => "), p.body]);
	const lastArg = hug == ArgHug.Last;
	const inner: Doc[] = [docLine()];
	if (p.conditionalBody) inner.push(docIfBreak(docNil(), docText("(")));
	inner.push(p.body);
	if (p.conditionalBody) inner.push(docIfBreak(docNil(), docText(")")));
	const parts: Doc[] = [docIndent(inner)];
	if (lastArg && wantsTrailingComma(options, CommaContext.Params)) parts.push(docIfBreak(docText(","), docNil()));
	if (lastArg && !p.hasComments) parts.push(docSoftLine());
	return docGroup([...head, docText(" =>"), docGroup(parts)]);
}

export function headWithoutSoftLines(head: Doc[]): Doc[] {
	const out: Doc[] = [];
	for (const doc of head) out.push(docWithoutSoftLines(doc));
	return out;
}

export function printArrowFunction(node: Node, options: FormatOptions): Doc {
	return assembleArrow(arrowPieces(node, options), ArgHug.None, options);
}

export function printSpreadExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as SpreadExprData;
	return docGroup([docText("..."), callPrintNode(d.spreadArg, options)]);
}

export function printComputedProperty(node: Node, options: FormatOptions): Doc {
	const d = node.data as ComputedPropertyData;
	const key = d.computedKey;
	const width = key.kind == NodeKind.Identifier ? (key.data as IdentifierData).name.length + 2 : options.tabWidth + 3;
	return objectProperty([docText("["), callPrintNode(key, options), docText("]")], width, d.computedValue, options);
}

function isUnaryLevel(node: Node): boolean {
	return node.kind == NodeKind.UnaryExpr || node.kind == NodeKind.UpdateExpr || node.kind == NodeKind.AwaitExpr;
}

export function printTypeAssertion(node: Node, options: FormatOptions): Doc {
	const d = node.data as TypeAssertionData;
	const bare = d.asExpr.kind == NodeKind.TypeAssertion || (d.asType != "!" && (isUnaryLevel(d.asExpr) || (d.asExpr.kind == NodeKind.BinaryExpr && bareBinaryPrec(d.asExpr) >= AS_PREC)));
	const inner = bare ? callPrintNode(d.asExpr, options) : printAtom(d.asExpr, options);
	if (d.asType == "!") return docGroup([inner, docText("!")]);
	return docGroup([
		inner,
		docText(" as " + d.asType),
	]);
}

export function printMatchExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as MatchExprData;
	const cases: Doc[] = [];
	for (let i = 0; i < d.matchCases.length; i += 1) {
		const c = d.matchCases[i];
		cases.push(withComments(c, printMatchCase(c, options, i == d.matchCases.length - 1)));
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

export function printMatchCase(node: Node, options: FormatOptions, isLast: boolean): Doc {
	const d = node.data as MatchCaseData;
	const pats: Doc[] = [];
	for (const p of d.casePatterns) {
		pats.push(callPrintNode(p, options));
	}
	const parts: Doc[] = [docJoin(pats, docText(" | "))];
	if (d.caseGuard != null) {
		parts.push(docText(" when "));
		parts.push(callPrintNode(d.caseGuard, options));
	}
	parts.push(docText(" => "));
	parts.push(callPrintNode(d.caseBody, options));
	if (writesCaseComma(node, d.caseBody, options, isLast)) parts.push(docText(","));
	return docGroup(parts);
}

function writesCaseComma(node: Node, body: Node, options: FormatOptions, isLast: boolean): boolean {
	if (node.flags.has(NodeFlag.CommaWritten)) return true;
	if (body.kind == NodeKind.BlockStmt) return false;
	return isLast || options.source == "";
}

export function printTryExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as TryExprData;
	const parts: Doc[] = [docText("try "), callPrintNode(d.tryArg, options)];
	if (d.hasCatch && d.catchVal != null) {
		parts.push(docText(" catch "));
		parts.push(callPrintNode(d.catchVal, options));
	}
	return docGroup(parts);
}

export function printMoveExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as MoveExprData;
	return docGroup([docText("move "), callPrintNode(d.moveArg, options)]);
}

export function printOutExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as OutExprData;
	return docGroup([docText("out "), printAtom(d.outArg, options)]);
}

export function printAwaitExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as AwaitExprData;
	return docGroup([docText("await "), printAtom(d.awaitArg, options)]);
}

export function printYieldExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as YieldExprData;
	const star = d.isDelegate ? "*" : "";
	return docGroup([docText("yield" + star + " "), callPrintNode(d.yieldArg, options)]);
}

export function printSizeofExpr(node: Node): Doc {
	const d = node.data as SizeofExprData;
	return docText("sizeof " + d.sizeofType);
}

export function printArrayPattern(node: Node, options: FormatOptions): Doc {
	const d = node.data as ArrayPatternData;
	if (d.patternElements.length == 0) return docText("[]");
	const elements: Doc[] = [];
	for (let i = 0; i < d.patternElements.length; i += 1) {
		if (i > 0) elements.push(docText(", "));
		const el = d.patternElements[i];
		const hole = el.kind == NodeKind.Identifier && (el.data as IdentifierData).name == "_"
			&& sourceByteAt(options.source, el.location.line, el.location.column) == ",".code;
		if (!hole) elements.push(callPrintNode(el, options));
		if (i < d.patternDefaults.length && d.patternDefaults[i] != null) {
			elements.push(docText(" = "));
			elements.push(callPrintNode(d.patternDefaults[i], options));
		}
	}
	return docGroup([docText("["), docGroup(elements), docText("]")]);
}

export function breaksPatternProperties(d: ObjectPatternData): boolean {
	for (const prop of d.patternProps) {
		if (prop.kind != NodeKind.ObjectPatternProp) continue;
		const pd = prop.data as ObjectPatternPropData;
		const nested = pd.propAlias != null && (pd.propAlias.kind == NodeKind.ObjectPattern || pd.propAlias.kind == NodeKind.ArrayPattern);
		if (nested && pd.propDefault == null) return true;
	}
	return false;
}

export function objectPatternContent(node: Node, options: FormatOptions): Doc[] {
	const d = node.data as ObjectPatternData;
	const inner: Doc[] = [docLine()];
	for (let i = 0; i < d.patternProps.length; i += 1) {
		if (i > 0) {
			inner.push(docText(","));
			inner.push(docLine());
		}
		inner.push(callPrintNode(d.patternProps[i], options));
	}
	if (!d.hasRestProp && wantsTrailingComma(options, CommaContext.Collection)) inner.push(docIfBreak(docText(","), docNil()));
	return [docText("{"), docIndent(inner), docLine(), docText("}")];
}

export function printObjectPattern(node: Node, options: FormatOptions): Doc {
	const d = node.data as ObjectPatternData;
	if (d.patternProps.length == 0) return docText("{}");
	const parts = objectPatternContent(node, options);
	return breaksPatternProperties(d) ? docGroupBreak(parts) : docGroup(parts);
}

export function printObjectPatternProp(node: Node, options: FormatOptions): Doc {
	const d = node.data as ObjectPatternPropData;
	// Shorthand `{ x }` when alias is an identifier with the same name.
	if (d.propAlias != null && d.propAlias.kind == NodeKind.Identifier) {
		const aliasName = (d.propAlias.data as IdentifierData).name;
		if (aliasName == d.propKey) {
			if (d.propDefault != null) return docGroup([docText(d.propKey + " = "), callPrintNode(d.propDefault, options)]);
			return docText(d.propKey);
		}
	}
	if (d.propDefault != null) return docGroup([docText(d.propKey + ": "), callPrintNode(d.propAlias, options), docText(" = "), callPrintNode(d.propDefault, options)]);
	return docGroup([docText(d.propKey + ": "), callPrintNode(d.propAlias, options)]);
}

export function printMacroInvocation(node: Node, options: FormatOptions): Doc {
	const d = node.data as MacroInvocationData;
	const parts: Doc[] = [docText("@" + d.macroName)];
	if (d.macroHasParens || d.macroArgs.length > 0) {
		const args: Doc[] = [];
		for (let i = 0; i < d.macroArgs.length; i += 1) {
			if (i > 0) args.push(docText(", "));
			args.push(callPrintNode(d.macroArgs[i], options));
		}
		parts.push(docText("("));
		parts.push(docGroup(args));
		parts.push(docText(")"));
	}
	return docGroup(parts);
}

export function functionExprPieces(node: Node, options: FormatOptions): FunctionPieces {
	const d = node.data as FunctionExprData;
	const hasComments = hasCommentsOutside(node) || danglingOf(node).length > 0;
	const asWritten = headerAsWritten(node, d.funcExprBody, options, null);
	if (asWritten != null) {
		return { head: [asWritten], body: printCollapsibleBody(d.funcExprBody, options), verbatimHead: true, inlineBody: true, conditionalBody: false, hasComments };
	}
	const isAsync = flagHas(d.funcExprFlags, "async") || flagHas(d.funcExprFlags, "async_generator");
	const isGen = flagHas(d.funcExprFlags, "generator") || flagHas(d.funcExprFlags, "async_generator");
	const head: Doc[] = [docText((isAsync ? "async " : "") + "function" + (isGen ? "*" : "") + " ")];
	const noDefaults: Node[] = [];
	const params = buildParamList(d.funcExprParams, d.funcExprParamTypes, noDefaults, options, node.paramLocations, node.typeExprs);
	for (const part of paramListInParens(params, options, hugsObjectParam(d.funcExprParams, d.funcExprParamTypes, noDefaults, node.typeExprs, options))) head.push(part);
	if (d.funcExprReturnType != "") {
		head.push(docText(": "));
		head.push(printTypeAnnotation(node.typeExpr, d.funcExprReturnType, options));
	}
	head.push(docText(" "));
	return { head, body: printCollapsibleBody(d.funcExprBody, options), verbatimHead: false, inlineBody: true, conditionalBody: false, hasComments };
}

export function assembleFunctionExpr(p: FunctionPieces, hug: ArgHug): Doc {
	return docGroup([...(hug == ArgHug.None ? p.head : headWithoutSoftLines(p.head)), p.body]);
}

export function printFunctionExpr(node: Node, options: FormatOptions): Doc {
	return assembleFunctionExpr(functionExprPieces(node, options), ArgHug.None);
}
