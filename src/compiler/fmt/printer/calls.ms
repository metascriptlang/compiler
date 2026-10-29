import {
	Node, NodeKind, NodeFlag,
	CallExprData, MemberExprData, ArrayAccessData, NewExprData, ObjectLiteralData, ArrayLiteralData,
	ArrowFunctionData, FunctionExprData, TypeAssertionData, UnaryExprData, UpdateExprData, IdentifierData,
	RegexLiteralData, StringLiteralData, BinaryExprData,
} from "../../../ast/node";
import { SourceComment } from "../comments";
import { commentsOfRun, commentLeading, commentTrailing, danglingOf, hasCommentsOutside, leadingDocs, takeOwnLineTrailing } from "./commentDocs";
import { FormatOptions, CommaContext, wantsTrailingComma } from "../options";
import {
	Doc, docText, docSourceText, docGroup, docGroupBreak, docIndent, docLine, docSoftLine, docHardLine, docIfBreak, docNil,
	docBreakParent, docBestFitting, docWillBreak,
} from "../doc";
import { isAssignOp } from "../../../ast/operators";
import { callPrintNode, isStatementExpression, printedAncestor } from "./callbacks";
import { rawTemplateAt, blankLineBefore, sourceSpan } from "./literals";
import {
	printAtom, writtenTypeArgs, listBody, writtenArrowBody,
	ArgHug, arrowPieces, headWithoutSoftLines, assembleArrow, functionExprPieces, assembleFunctionExpr,
} from "./expressions";

function hasUnformatted(list: SourceComment[]): boolean {
	for (const c of list) {
		if (!c.formatted) return true;
	}
	return false;
}

function hasLeadingComments(node: Node): boolean {
	return hasUnformatted(commentsOfRun().leading(node));
}

function hasTrailingComments(node: Node): boolean {
	return hasUnformatted(commentsOfRun().trailing(node));
}

function hasAnyComments(node: Node): boolean {
	return hasCommentsOutside(node) || danglingOf(node).length > 0;
}

function isNonNull(node: Node): boolean {
	return node.kind == NodeKind.TypeAssertion && (node.data as TypeAssertionData).asType == "!";
}

function isFunctionLike(node: Node): boolean {
	return node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr;
}

function isStringLiteral(node: Node, options: FormatOptions): boolean {
	return node.kind == NodeKind.StringLiteral && rawTemplateAt(node, options) == "";
}

function isTemplate(node: Node, options: FormatOptions): boolean {
	return rawTemplateAt(node, options) != "";
}

function isBlockBodied(node: Node, options: FormatOptions): boolean {
	if (node.kind == NodeKind.FunctionExpr) return true;
	return node.kind == NodeKind.ArrowFunction && writtenArrowBody((node.data as ArrowFunctionData).arrowBody, options).kind == NodeKind.BlockStmt;
}


function isWordChar(code: int32): boolean {
	return (code >= "a".code && code <= "z".code) || (code >= "A".code && code <= "Z".code) || (code >= "0".code && code <= "9".code) || code == "_".code || code == "$".code;
}

function isSimpleImpl(node: Node | null, depth: int32, options: FormatOptions): boolean {
	if (depth >= 2 || node == null) return false;
	if (node.flags.has(NodeFlag.Parenthesized)) return false;
	const raw = rawTemplateAt(node, options);
	if (raw != "") return !raw.includes("\n") && !raw.includes("${");
	return match (node.kind) {
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral | NodeKind.NullLiteral | NodeKind.BigIntLiteral | NodeKind.Identifier => true,
		NodeKind.RegexLiteral => (node.data as RegexLiteralData).regexPattern.length <= 5,
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			for (let i = 0; i < d.keys.length; i += 1) {
				const prop = d.properties[i];
				if (d.keys[i] == "..." || prop == null || prop.kind == NodeKind.ComputedProperty) return false;
				if (!isSimpleImpl(prop, depth + 1, options)) return false;
			}
			return true;
		},
		NodeKind.ArrayLiteral => {
			for (const el of (node.data as ArrayLiteralData).elements) {
				if (!isSimpleImpl(el, depth + 1, options)) return false;
			}
			return true;
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			return (d.unaryOp == "!" || d.unaryOp == "-" || d.unaryOp == "+" || d.unaryOp == "~") && isSimpleImpl(d.operand, depth, options);
		},
		NodeKind.UpdateExpr => isSimpleImpl((node.data as UpdateExprData).updateArg, depth, options),
		NodeKind.TypeAssertion => isNonNull(node) && isSimpleImpl((node.data as TypeAssertionData).asExpr, depth, options),
		NodeKind.MemberExpr => isSimpleImpl((node.data as MemberExprData).object, depth, options),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			return isSimpleImpl(d.index, depth, options) && isSimpleImpl(d.array, depth, options);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			return isSimpleCall(d.callee, d.arguments, depth, options);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			return isSimpleCall(d.newCallee, d.newArguments, depth, options);
		},
		_ => false,
	};
}

function isSimpleCall(callee: Node, args: Node[], depth: int32, options: FormatOptions): boolean {
	if (!isSimpleImpl(callee, depth, options)) return false;
	if (args.length + depth > 2) return false;
	for (const arg of args) {
		if (!isSimpleImpl(arg, depth + 1, options)) return false;
	}
	return true;
}

function isSimple(node: Node, options: FormatOptions): boolean {
	return isSimpleImpl(node, 0, options);
}

const keywordTypes: string[] = [
	"any", "bigint", "boolean", "never", "null", "object", "number", "string", "symbol", "undefined", "unknown", "void", "this", "true", "false",
];

function isIdentifierPath(type: string): boolean {
	if (type.length == 0) return false;
	for (let i = 0; i < type.length; i += 1) {
		const code = type.charCodeAt(i);
		if (!isWordChar(code) && code != ".".code) return false;
	}
	const first = type.charCodeAt(0);
	return !(first >= "0".code && first <= "9".code);
}

function isLiteralType(type: string): boolean {
	const first = type.charCodeAt(0);
	if (first == "\"".code || first == "'".code || first == "`".code) return true;
	return (first >= "0".code && first <= "9".code) || first == "-".code;
}

function isSimpleType(written: string): boolean {
	let type = written.trim();
	if (type.endsWith("[]")) {
		const inner = type.slice(0, type.length - 2);
		let element = inner.endsWith("[]") ? inner.slice(0, inner.length - 2) : inner;
		const open = element.indexOf("<");
		if (open > 0 && element.endsWith(">") && isIdentifierPath(element.slice(0, open))) {
			const argument = element.slice(open + 1, element.length - 1);
			if (!argument.includes(",") && !argument.includes("<")) element = argument;
		}
		type = element;
	}
	if (keywordTypes.includes(type) || isLiteralType(type)) return true;
	return isIdentifierPath(type);
}

function isRelativelyShort(node: Node, options: FormatOptions): boolean {
	return match (node.kind) {
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			return isSimple(d.left, options) && isSimple(d.right, options);
		},
		NodeKind.TypeAssertion => {
			if (isNonNull(node)) return isSimple(node, options);
			const d = node.data as TypeAssertionData;
			return isSimpleType(d.asType) && isSimple(d.asExpr, options);
		},
		NodeKind.RegexLiteral => true,
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			if (d.arguments.length == 0) return true;
			return d.arguments.length == 1 && isSimple(node, options);
		},
		_ => isSimple(node, options),
	};
}


function canConciselyPrintArray(node: Node): boolean {
	const elements = (node.data as ArrayLiteralData).elements;
	if (elements.length <= 1) return false;
	for (const el of elements) {
		let operand = el;
		if (el.kind == NodeKind.UnaryExpr) {
			const op = (el.data as UnaryExprData).unaryOp;
			if (op != "-" && op != "+") return false;
			operand = (el.data as UnaryExprData).operand;
		}
		if (operand.kind != NodeKind.NumberLiteral || hasAnyComments(el)) return false;
	}
	return true;
}

function isReferenceType(written: string): boolean {
	const type = written.trim();
	const open = type.indexOf("<");
	const name = open > 0 && type.endsWith(">") ? type.slice(0, open) : type;
	return isIdentifierPath(name) && !keywordTypes.includes(name);
}

function canGroup(node: Node, isArrowRecursion: boolean, options: FormatOptions): boolean {
	return match (node.kind) {
		NodeKind.ObjectLiteral => (node.data as ObjectLiteralData).keys.length > 0 || hasAnyComments(node),
		NodeKind.ArrayLiteral => (node.data as ArrayLiteralData).elements.length > 0 || hasAnyComments(node),
		NodeKind.TypeAssertion => !isNonNull(node) && canGroup((node.data as TypeAssertionData).asExpr, false, options),
		NodeKind.FunctionExpr => true,
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			const body = writtenArrowBody(d.arrowBody, options);
			let canGroupType = true;
			if (d.arrowReturnType != "" && isReferenceType(d.arrowReturnType)) {
				canGroupType = body.kind == NodeKind.BlockStmt && ((body.data as { statements: Node[] }).statements.length > 0 || hasAnyComments(body));
			}
			const canGroupBody = match (body.kind) {
				NodeKind.BlockStmt | NodeKind.ObjectLiteral | NodeKind.ArrayLiteral | NodeKind.JSXElement | NodeKind.JSXFragment => true,
				NodeKind.ArrowFunction => canGroup(body, true, options),
				NodeKind.CallExpr | NodeKind.ConditionalExpr => !isArrowRecursion,
				_ => false,
			};
			return canGroupBody && canGroupType;
		},
		_ => false,
	};
}

function shouldGroupFirst(args: Node[], options: FormatOptions): boolean {
	if (args.length != 2) return false;
	const first = args[0];
	const second = args[1];
	if (first.kind == NodeKind.ArrowFunction) {
		if (!isBlockBodied(first, options)) return false;
	} else if (first.kind != NodeKind.FunctionExpr) {
		return false;
	}
	if (second.kind == NodeKind.ArrowFunction || second.kind == NodeKind.FunctionExpr || second.kind == NodeKind.ConditionalExpr) return false;
	return !hasAnyComments(first) && !canGroup(second, false, options) && isRelativelyShort(second, options);
}

function shouldGroupLast(args: Node[], options: FormatOptions): boolean {
	const last = args[args.length - 1];
	if (hasLeadingComments(last) || hasTrailingComments(last)) return false;
	if (!canGroup(last, false, options)) return false;
	const penultimate = args.length > 1 ? args[args.length - 2] : null;
	if (penultimate != null && penultimate.kind == last.kind) return false;
	if (last.kind == NodeKind.ArrayLiteral && args.length > 1) {
		if (args.length == 2 && penultimate!.kind == NodeKind.ArrowFunction) return false;
		if (canConciselyPrintArray(last)) return false;
	}
	return true;
}

function isFunctionComposition(args: Node[]): boolean {
	if (args.length <= 1) return false;
	let seenFunction = false;
	for (const arg of args) {
		if (isFunctionLike(arg)) {
			if (seenFunction) return true;
			seenFunction = true;
		} else if (arg.kind == NodeKind.CallExpr) {
			for (const inner of (arg.data as CallExprData).arguments) {
				if (isFunctionLike(inner)) return true;
			}
		}
	}
	return false;
}


function isRequireCall(callee: Node | null, args: Node[], options: FormatOptions): boolean {
	if (callee == null || callee.kind != NodeKind.Identifier || (callee.data as IdentifierData).name != "require") return false;
	if (args.length == 0) return false;
	if (args.length == 1) return isStringLiteral(args[0], options);
	return true;
}

function isMultilineTemplateOnly(args: Node[], options: FormatOptions): boolean {
	return args.length == 1 && rawTemplateAt(args[0], options).includes("\n");
}

function isReactHookWithDeps(args: Node[], options: FormatOptions): boolean {
	if (args.length < 2 || args.length > 3) return false;
	const callback = args[args.length - 2];
	const deps = args[args.length - 1];
	if (callback.kind != NodeKind.ArrowFunction || deps.kind != NodeKind.ArrayLiteral) return false;
	if (hasAnyComments(callback) || hasAnyComments(deps)) return false;
	return (callback.data as ArrowFunctionData).arrowParams.length == 0 && isBlockBodied(callback, options);
}

function calleeNames(callee: Node): string[] | null {
	if (callee.kind == NodeKind.Identifier) return [(callee.data as IdentifierData).name];
	if (callee.kind != NodeKind.MemberExpr || callee.flags.has(NodeFlag.Parenthesized)) return null;
	const d = callee.data as MemberExprData;
	const names = calleeNames(d.object);
	if (names == null) return null;
	names.push(d.property);
	return names;
}

const describeModifiers: string[] = ["concurrent", "sequential", "only", "skip", "fixme", "todo", "shuffle"];
const testModifiers: string[] = ["concurrent", "sequential", "only", "skip", "fixme", "todo", "fails", "failing"];
const skippedRunners: string[] = ["skip", "xit", "xdescribe", "xtest", "fit", "fdescribe", "ftest", "fsuite", "xsuite"];

function namesAt(names: string[], from: int32): string | null {
	return from < names.length ? names[from] : null;
}

function containsTestPattern(callee: Node): boolean {
	const names = calleeNames(callee);
	if (names == null) return false;
	for (let i = 0; i < names.length; i += 1) {
		for (let j = i + 1; j < names.length; j += 1) {
			if (names[i] == names[j]) return false;
		}
	}
	const first = names[0];
	const second = namesAt(names, 1);
	const third = namesAt(names, 2);
	const fourth = namesAt(names, 3);
	const fifth = namesAt(names, 4);
	if (first == "describe" || first == "suite") {
		if (second == null) return true;
		return describeModifiers.includes(second) && (third == null || describeModifiers.includes(third));
	}
	if (first == "it" || first == "test") {
		if (second == null) return true;
		if (second == "step") return third == null || ((third == "skip" || third == "fixme") && fourth == null);
		if (testModifiers.includes(second)) return third == null || testModifiers.includes(third);
		if (second == "describe" || second == "suite") {
			if (third == null) return true;
			if (third == "only" || third == "skip" || third == "fixme") return fourth == null;
			if (third == "parallel" || third == "serial") return fourth == null || ((fourth == "only" || fourth == "skip" || fourth == "fixme") && fifth == null);
		}
		return false;
	}
	if (first == "Deno") return second == "test" && third == null;
	return skippedRunners.includes(first);
}

function hasAtMostOneParam(node: Node): boolean {
	if (node.kind == NodeKind.ArrowFunction) return (node.data as ArrowFunctionData).arrowParams.length <= 1;
	return (node.data as FunctionExprData).funcExprParams.length <= 1;
}

function isFunctionWithBlockBody(node: Node, options: FormatOptions): boolean {
	return isFunctionLike(node) && isBlockBodied(node, options) && hasAtMostOneParam(node);
}

function isTestCall(callee: Node | null, args: Node[], options: FormatOptions): boolean {
	if (callee == null || args.length < 2 || args.length > 3 || !containsTestPattern(callee)) return false;
	const second = args[1];
	const third = args.length == 3 ? args[2] : null;
	if (isFunctionLike(second)) {
		if (args.length == 2) return true;
		return isFunctionWithBlockBody(second, options) && third != null && third.kind == NodeKind.NumberLiteral;
	}
	return second.kind == NodeKind.ObjectLiteral && third != null && isFunctionWithBlockBody(third, options);
}


function emptyLineBefore(args: Node[], index: int32, options: FormatOptions): boolean {
	if (index == 0) return false;
	const previous = args[index - 1].location;
	if (previous.endLine == 0) return false;
	const text = sourceSpan(options.source, previous.endLine, previous.endColumn, previous.endLine + 30, 1);
	const comma = text.indexOf(",");
	if (comma < 0) return false;
	let newlines = 0;
	for (let i = comma + 1; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		if (code == 10) newlines += 1;
		else if (code != 32 && code != 9 && code != 13) break;
	}
	return newlines >= 2;
}

function allBrokenOut(open: string, docs: Doc[], args: Node[], expand: boolean, options: FormatOptions): Doc {
	const inner: Doc[] = [docSoftLine()];
	for (let i = 0; i < docs.length; i += 1) {
		if (i > 0) {
			if (emptyLineBefore(args, i, options)) {
				inner.push(docHardLine());
				inner.push(docHardLine());
			} else {
				inner.push(docLine());
			}
		}
		inner.push(docs[i]);
		if (i < docs.length - 1) inner.push(docText(","));
	}
	if (wantsTrailingComma(options, CommaContext.Params)) inner.push(docIfBreak(docText(","), docNil()));
	const parts: Doc[] = [docText(open), docIndent(inner), docSoftLine(), docText(")")];
	return expand ? docGroupBreak(parts) : docGroup(parts);
}

function spaced(open: string, docs: Doc[]): Doc[] {
	const parts: Doc[] = [docText(open)];
	for (let i = 0; i < docs.length; i += 1) {
		if (i > 0) parts.push(docText(", "));
		parts.push(docs[i]);
	}
	parts.push(docText(")"));
	return parts;
}

function joinedOnOneLine(open: string, docs: Doc[], grouped: int32, hugged: Doc | null): Doc[] {
	const parts: Doc[] = [docText(open)];
	for (let i = 0; i < docs.length; i += 1) {
		if (i > 0) parts.push(docLine());
		const doc = i == grouped && hugged != null ? hugged : docs[i];
		parts.push(doc);
		if (i < docs.length - 1) parts.push(docText(","));
	}
	parts.push(docText(")"));
	return parts;
}

function huggedArgument(node: Node, hug: ArgHug, onlyArgument: boolean, options: FormatOptions): { normal: Doc, hugged: Doc | null, poor: boolean } {
	if (node.kind == NodeKind.ArrowFunction) {
		const pieces = arrowPieces(node, options);
		const hugged = assembleArrow(pieces, hug, options);
		return { normal: assembleArrow(pieces, ArgHug.None, options), hugged, poor: signatureWillBreak(pieces.head) };
	}
	const pieces = functionExprPieces(node, options);
	const normal = assembleFunctionExpr(pieces, ArgHug.None);
	const params = (node.data as FunctionExprData).funcExprParams;
	const reformats = hug == ArgHug.Last && (!onlyArgument || hasSimpleParams(params, (node.data as FunctionExprData).funcExprParamTypes));
	if (!reformats) return { normal, hugged: null, poor: false };
	const hugged = assembleFunctionExpr(pieces, hug);
	return { normal, hugged, poor: signatureWillBreak(pieces.head) };
}

function hasSimpleParams(names: string[], types: string[]): boolean {
	for (let i = 0; i < names.length; i += 1) {
		if (names[i].startsWith("_destr") || names[i].startsWith("...") || (i < types.length && types[i] != "")) return false;
	}
	return true;
}

function signatureWillBreak(head: Doc[]): boolean {
	for (const doc of headWithoutSoftLines(head)) {
		if (docWillBreak(doc)) return true;
	}
	return false;
}

export function printCallArguments(call: Node | null, args: Node[], node: Node, prefix: string, options: FormatOptions): Doc[] {
	const open = prefix + "(";
	const endComments = danglingOf(node);
	if (args.length == 0 || endComments.length > 0) {
		const docs: Doc[] = [];
		for (const arg of args) docs.push(callPrintNode(arg, options));
		const parts: Doc[] = [docText(open)];
		for (const p of listBody(docs, wantsTrailingComma(options, CommaContext.Params), endComments)) parts.push(p);
		parts.push(docText(")"));
		return parts;
	}
	const callee = call != null ? (call.data as CallExprData).callee : null;
	const firstIsStringOrTemplate = args.length != 2 || isStringLiteral(args[0], options) || isTemplate(args[0], options);
	if (isRequireCall(callee, args, options) || isMultilineTemplateOnly(args, options) || isReactHookWithDeps(args, options)
		|| (call != null && isTestCall(callee, args, options) && firstIsStringOrTemplate)) {
		const docs: Doc[] = [];
		for (const arg of args) docs.push(callPrintNode(arg, options));
		return spaced(open, docs);
	}

	let hasEmptyLine = false;
	for (let i = 1; i < args.length; i += 1) {
		if (emptyLineBefore(args, i, options)) hasEmptyLine = true;
	}
	if (hasEmptyLine || isFunctionComposition(args)) {
		const docs: Doc[] = [];
		for (const arg of args) docs.push(callPrintNode(arg, options));
		return [allBrokenOut(open, docs, args, true, options)];
	}

	let hug = ArgHug.None;
	if (shouldGroupFirst(args, options)) hug = ArgHug.First;
	else if (shouldGroupLast(args, options)) hug = ArgHug.Last;

	const groupedIndex = hug == ArgHug.First ? 0 : args.length - 1;
	const docs: Doc[] = [];
	let hugged: Doc | null = null;
	let poor = false;
	for (let i = 0; i < args.length; i += 1) {
		const arg = args[i];
		const huggable = hug != ArgHug.None && i == groupedIndex && isFunctionLike(arg)
			&& !arg.flags.has(NodeFlag.Parenthesized) && !arg.flags.has(NodeFlag.ExternC);
		if (huggable) {
			const pieces = huggedArgument(arg, hug, args.length == 1, options);
			docs.push(pieces.normal);
			hugged = pieces.hugged;
			poor = pieces.poor;
		} else {
			docs.push(callPrintNode(arg, options));
		}
	}
	if (hug == ArgHug.None) return [allBrokenOut(open, docs, args, false, options)];

	for (let i = 0; i < docs.length; i += 1) {
		if (i != groupedIndex && docWillBreak(docs[i])) return [allBrokenOut(open, docs, args, true, options)];
	}
	const expanded = allBrokenOut(open, docs, args, true, options);
	if (poor) return [expanded];
	const groupedBreaks = docWillBreak(docs[groupedIndex]);

	const flat = joinedOnOneLine(open, docs, groupedIndex, hugged);
	const middle: Doc[] = [docText(open)];
	for (let i = 0; i < docs.length; i += 1) {
		if (i > 0) middle.push(docLine());
		const inner = i == groupedIndex && hugged != null ? hugged : docs[i];
		middle.push(i == groupedIndex ? docGroupBreak([inner]) : inner);
		if (i < docs.length - 1) middle.push(docText(","));
	}
	middle.push(docText(")"));

	if (groupedBreaks) return [docBreakParent(), docBestFitting([middle, [expanded]])];
	return [docBestFitting([flat, middle, [expanded]])];
}


enum ChainKind {
	Static,
	Call,
	Computed,
	NonNull,
	Plain,
}

enum CallPosition {
	Start,
	Middle,
	End,
}

interface ChainMember {
	kind: ChainKind;
	node: Node;
	position: CallPosition;
	leading: boolean;
	trailing: boolean;
	moved: SourceComment[];
}

function newMember(kind: ChainKind, node: Node, position: CallPosition): ChainMember {
	return { kind, node, position, leading: hasLeadingComments(node), trailing: hasTrailingComments(node), moved: [] };
}

export function printMemberExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as MemberExprData;
	const op = d.isOptional ? "?." : ".";
	const ownLine = takeOwnLineTrailing(d.object);
	if (ownLine.length > 0) {
		const lines: Doc[] = [];
		for (const c of ownLine) {
			lines.push(docHardLine());
			lines.push(docSourceText(c.text));
		}
		lines.push(docHardLine());
		lines.push(docText(op + d.property));
		return docGroup([printAtom(d.object, options), docIndent(lines)]);
	}
	if (!staticMemberBreaksAfterObject(node, d.object, options)) return docGroup([printAtom(d.object, options), docText(op + d.property)]);
	return docGroup([printAtom(d.object, options), docGroup([docIndent([docSoftLine(), docText(op + d.property)])])]);
}

function isMemberLike(node: Node): boolean {
	return node.kind == NodeKind.MemberExpr || node.kind == NodeKind.ArrayAccess;
}

function callsWithArguments(node: Node): boolean {
	if (node.kind == NodeKind.TypeAssertion && isNonNull(node)) return callsWithArguments((node.data as TypeAssertionData).asExpr);
	return node.kind == NodeKind.CallExpr && (node.data as CallExprData).arguments.length > 0;
}

function isLabelledMemberChain(node: Node): boolean {
	if (node.kind != NodeKind.CallExpr) return false;
	const callee = (node.data as CallExprData).callee;
	return isChainStep(callee) && callee.kind != NodeKind.CallExpr && isMemberCallChain(node);
}

function staticMemberBreaksAfterObject(node: Node, object: Node, options: FormatOptions): boolean {
	const parent = printedAncestor(1);
	const bindsValue = parent != null && (parent.kind == NodeKind.VariableDecl || parent.kind == NodeKind.DestructuringDecl
		|| (parent.kind == NodeKind.BinaryExpr && isAssignOp((parent.data as BinaryExprData).operator)));
	if (bindsValue && (callsWithArguments(object) || isLabelledMemberChain(object))) return false;
	const nested = parent != null && isMemberLike(parent);
	if (!nested && object.kind == NodeKind.Identifier && (object.data as IdentifierData).name != "this") return false;
	let levels = 1;
	let ancestor = parent;
	while (ancestor != null && isMemberLike(ancestor)) {
		levels += 1;
		ancestor = printedAncestor(levels);
	}
	if (ancestor == null) return true;
	if (ancestor.kind == NodeKind.NewExpr) return false;
	if (ancestor.kind == NodeKind.BinaryExpr && isAssignOp((ancestor.data as BinaryExprData).operator)) {
		return (ancestor.data as BinaryExprData).left.kind == NodeKind.Identifier;
	}
	return true;
}

function isChainStep(node: Node): boolean {
	return !node.flags.has(NodeFlag.Parenthesized)
		&& (node.kind == NodeKind.MemberExpr || node.kind == NodeKind.ArrayAccess || node.kind == NodeKind.CallExpr);
}

function collectMembers(root: Node): ChainMember[] {
	const out: ChainMember[] = [];
	let current: Node | null = root;
	let isRoot = true;
	while (current != null) {
		const node: Node = current;
		current = null;
		if (node.flags.has(NodeFlag.Parenthesized) && !isRoot) {
			out.push(newMember(ChainKind.Plain, node, CallPosition.Start));
			break;
		}
		if (node.kind == NodeKind.CallExpr) {
			const callee = (node.data as CallExprData).callee;
			const chained = isChainStep(callee);
			if (chained) current = callee;
			out.push(newMember(ChainKind.Call, node, isRoot ? CallPosition.End : (!chained ? CallPosition.Start : CallPosition.Middle)));
		} else if (node.kind == NodeKind.MemberExpr) {
			current = (node.data as MemberExprData).object;
			out.push(newMember(ChainKind.Static, node, CallPosition.Start));
		} else if (node.kind == NodeKind.ArrayAccess) {
			current = (node.data as ArrayAccessData).array;
			out.push(newMember(ChainKind.Computed, node, CallPosition.Start));
		} else if (isNonNull(node)) {
			current = (node.data as TypeAssertionData).asExpr;
			out.push(newMember(ChainKind.NonNull, node, CallPosition.Start));
		} else {
			out.push(newMember(ChainKind.Plain, node, CallPosition.Start));
		}
		isRoot = false;
	}
	out.reverse();
	for (let i = 1; i < out.length; i += 1) {
		out[i].moved = takeOwnLineTrailing(out[i - 1].node);
		if (out[i].moved.length > 0) {
			out[i].leading = true;
			out[i - 1].trailing = hasTrailingComments(out[i - 1].node);
		}
	}
	return out;
}

function isCallLike(m: ChainMember): boolean {
	return m.kind == ChainKind.Call || (m.kind == ChainKind.Plain && (m.node.kind == NodeKind.CallExpr || m.node.kind == NodeKind.NewExpr));
}

function isNumberIndex(m: ChainMember): boolean {
	return m.kind == ChainKind.Computed && (m.node.data as ArrayAccessData).index.kind == NodeKind.NumberLiteral;
}

interface ChainGroups {
	head: ChainMember[];
	tail: ChainMember[][];
}

function splitHead(members: ChainMember[]): ChainGroups {
	let accessStart = members.length;
	for (let i = 1; i < members.length; i += 1) {
		const m = members[i];
		if (m.kind == ChainKind.Call || m.kind == ChainKind.NonNull) continue;
		if (m.kind == ChainKind.Computed && isNumberIndex(m)) continue;
		accessStart = i;
		break;
	}
	let headEnd = accessStart;
	if (members[0].kind != ChainKind.Call) {
		let memberEnd = members.length - accessStart;
		for (let i = accessStart; i < members.length; i += 1) {
			const m = members[i];
			if (m.kind == ChainKind.Static || m.kind == ChainKind.Computed) {
				const nextIsMember = i + 1 < members.length && (members[i + 1].kind == ChainKind.Computed || members[i + 1].kind == ChainKind.Static);
				if (!nextIsMember) {
					memberEnd = i - accessStart;
					break;
				}
			} else {
				memberEnd = i - accessStart;
				break;
			}
		}
		headEnd = accessStart + memberEnd;
	}
	return { head: members.slice(0, headEnd), tail: remainingGroups(members.slice(headEnd)) };
}

function remainingGroups(members: ChainMember[]): ChainMember[][] {
	const groups: ChainMember[][] = [];
	let current: ChainMember[] = [];
	let seenCall = false;
	for (const m of members) {
		const startsGroup = (m.kind == ChainKind.Static || m.kind == ChainKind.Computed) && !isNumberIndex(m) && seenCall;
		if (startsGroup) {
			groups.push(current);
			current = [];
			seenCall = false;
		}
		const isMember = m.kind == ChainKind.Static || m.kind == ChainKind.Computed;
		if (!isMember && m.kind != ChainKind.NonNull && m.kind != ChainKind.Call && !isCallLike(m) && current.length == 0) {
			throw new Error("internal: a member chain group continues before it starts");
		}
		current.push(m);
		if (m.kind == ChainKind.Call || (m.kind == ChainKind.Plain && isCallLike(m))) seenCall = true;
		if (m.trailing) {
			groups.push(current);
			current = [];
			seenCall = false;
		}
	}
	if (current.length > 0) groups.push(current);
	return groups;
}

function isFactoryName(name: string): boolean {
	if (name.length == 0) return false;
	const first = name.charCodeAt(0);
	if (first == "_".code || first == "$".code) {
		for (let i = 1; i < name.length; i += 1) {
			const c = name.charCodeAt(i);
			if (c != "_".code && c != "$".code) return false;
		}
		return true;
	}
	return first >= "A".code && first <= "Z".code;
}

function shouldMergeTailWithHead(groups: ChainGroups, root: Node, options: FormatOptions): boolean {
	if (groups.tail.length == 0) return false;
	const firstMember = groups.tail[0][0];
	if (firstMember.leading || firstMember.trailing) return false;
	const hasComputed = firstMember.kind == ChainKind.Computed;
	if (groups.head.length == 1) {
		const only = groups.head[0];
		if (only.kind != ChainKind.Plain) return false;
		if (only.node.kind != NodeKind.Identifier) return false;
		const name = (only.node.data as IdentifierData).name;
		if (name == "this") return true;
		return hasComputed || isFactoryName(name) || (isStatementExpression(root) && name.length <= options.tabWidth);
	}
	const last = groups.head[groups.head.length - 1];
	if (last.kind == ChainKind.Static) return hasComputed || isFactoryName((last.node.data as MemberExprData).property);
	return false;
}

function memberDocs(m: ChainMember, isRoot: boolean, options: FormatOptions): Doc[] {
	const docs: Doc[] = [];
	if (m.kind == ChainKind.Plain) {
		docs.push(printAtom(m.node, options));
		return docs;
	}
	if (m.kind == ChainKind.Call && m.position == CallPosition.Start) {
		docs.push(callPrintNode(m.node, options));
		return docs;
	}
	for (const d of leadingDocs(m.moved)) docs.push(d);
	if (!isRoot) for (const d of commentLeading(m.node)) docs.push(d);
	if (m.kind == ChainKind.Static) {
		const d = m.node.data as MemberExprData;
		docs.push(docText((d.isOptional ? "?." : ".") + d.property));
	} else if (m.kind == ChainKind.Computed) {
		const d = m.node.data as ArrayAccessData;
		docs.push(docText(m.node.flags.has(NodeFlag.OptionalLink) ? "?.[" : "["));
		docs.push(callPrintNode(d.index, options));
		docs.push(docText("]"));
	} else if (m.kind == ChainKind.NonNull) {
		docs.push(docText("!"));
	} else {
		const d = m.node.data as CallExprData;
		const prefix = (m.node.flags.has(NodeFlag.OptionalLink) ? "?." : "") + writtenTypeArgs(m.node, d.callee, options);
		for (const part of printCallArguments(m.node, d.arguments, m.node, prefix, options)) docs.push(part);
	}
	if (!isRoot) for (const d of commentTrailing(m.node)) docs.push(d);
	return docs;
}

function groupDocs(group: ChainMember[], rootNode: Node, options: FormatOptions): Doc[] {
	const docs: Doc[] = [];
	for (const m of group) {
		for (const d of memberDocs(m, m.node == rootNode, options)) docs.push(d);
	}
	return docs;
}

function anyWillBreak(docs: Doc[]): boolean {
	for (const d of docs) {
		if (docWillBreak(d)) return true;
	}
	return false;
}

function chainHasComments(groups: ChainGroups, root: Node): boolean {
	const members: ChainMember[] = [...groups.head];
	for (const g of groups.tail) for (const m of g) members.push(m);
	if (members.length > 0 && members[0].trailing) return true;
	for (let i = 1; i < members.length; i += 1) {
		if (members[i].node == root) continue;
		if (members[i].leading || members[i].trailing) return true;
	}
	return false;
}

function groupCallArguments(call: Node): Node[] {
	return (call.data as CallExprData).arguments;
}

function hasFunctionArgument(call: Node): boolean {
	for (const arg of groupCallArguments(call)) {
		if (isFunctionLike(arg)) return true;
	}
	return false;
}

function isMemberCallChain(call: Node): boolean {
	const groups = buildGroups(call);
	return groups.tail.length > 1 || chainHasComments(groups, call);
}

function isShortArgument(arg: Node, threshold: int32, options: FormatOptions): boolean {
	if (hasAnyComments(arg)) return false;
	const raw = rawTemplateAt(arg, options);
	if (raw != "") return !raw.includes("${") && !raw.includes("\n") && raw.length - 2 <= threshold;
	return match (arg.kind) {
		NodeKind.Identifier => (arg.data as IdentifierData).name.length <= threshold || (arg.data as IdentifierData).name == "this",
		NodeKind.UnaryExpr => {
			const d = arg.data as UnaryExprData;
			return (d.unaryOp == "-" || d.unaryOp == "+") && d.operand.kind == NodeKind.NumberLiteral && !hasAnyComments(d.operand);
		},
		NodeKind.RegexLiteral => (arg.data as RegexLiteralData).regexPattern.length <= threshold,
		NodeKind.StringLiteral => (arg.data as StringLiteralData).value.length + 2 <= threshold,
		NodeKind.NumberLiteral | NodeKind.BooleanLiteral | NodeKind.NullLiteral | NodeKind.BigIntLiteral => true,
		_ => false,
	};
}

function hasComplexTypeArguments(call: Node): boolean {
	const written = call.typeArg;
	return written.includes(",") || written.includes("|") || written.includes("&") || written.includes("{");
}

export function isPoorlyBreakableMemberOrCallChain(expression: Node, options: FormatOptions): boolean {
	const threshold = options.printWidth / 4;
	let isChain = false;
	let headIsSimple = false;
	const calls: Node[] = [];
	let current: Node | null = expression;
	while (current != null) {
		const node: Node = current;
		current = null;
		if (node.flags.has(NodeFlag.Parenthesized)) break;
		if (isNonNull(node)) {
			current = (node.data as TypeAssertionData).asExpr;
		} else if (node.kind == NodeKind.CallExpr) {
			isChain = true;
			calls.push(node);
			current = (node.data as CallExprData).callee;
		} else if (node.kind == NodeKind.MemberExpr) {
			isChain = true;
			current = (node.data as MemberExprData).object;
		} else if (node.kind == NodeKind.ArrayAccess) {
			isChain = true;
			current = (node.data as ArrayAccessData).array;
		} else if (node.kind == NodeKind.Identifier) {
			headIsSimple = true;
		}
	}
	if (!isChain || !headIsSimple) return false;
	for (const call of calls) {
		if (isMemberCallChain(call)) return false;
		const args = (call.data as CallExprData).arguments;
		if (args.length > 1 || (args.length == 1 && !isShortArgument(args[0], threshold, options))) return false;
		if (hasComplexTypeArguments(call)) return false;
	}
	return true;
}

function buildGroups(root: Node): ChainGroups {
	const members = collectMembers(root);
	return splitHead(members);
}

function printMemberChain(root: Node, options: FormatOptions): Doc {
	const groups = buildGroups(root);
	const hasComments = chainHasComments(groups, root);
	if (shouldMergeTailWithHead(groups, root, options)) {
		const first = groups.tail.shift()!;
		for (const m of first) groups.head.push(m);
	}
	const headDocs = groupDocs(groups.head, root, options);
	const tailDocs: Doc[][] = [];
	for (const g of groups.tail) tailDocs.push(groupDocs(g, root, options));

	const oneLine: Doc[] = [...headDocs];
	for (const g of tailDocs) for (const d of g) oneLine.push(d);

	if (groups.tail.length <= 1 && !hasComments) {
		const callee = (root.data as CallExprData).callee;
		if (groups.head.length >= 2 && isTestCall(callee, groupCallArguments(root), options)) {
			const tailOnly: Doc[] = [docLine()];
			for (const g of tailDocs) for (const d of g) tailOnly.push(d);
			return docGroup([...headDocs, docIndent(tailOnly)]);
		}
		return docGroup(oneLine);
	}

	const tail: Doc[] = [];
	for (let i = 0; i < tailDocs.length; i += 1) {
		const firstOfGroup = groups.tail[i][0];
		if (emptyLineBeforeMember(firstOfGroup)) {
			tail.push(docHardLine());
			tail.push(docHardLine());
		} else {
			tail.push(docHardLine());
		}
		for (const d of tailDocs[i]) tail.push(d);
	}
	const expanded: Doc[] = [...headDocs, docIndent([docGroup(tail)])];

	if (chainShouldBreak(groups, headDocs, tailDocs, hasComments, options)) return docGroup(expanded);

	const parts: Doc[] = [];
	const emptyLineBeforeTail = groups.tail.length > 0 && emptyLineBeforeMember(groups.tail[0][0]);
	const lastDocs = tailDocs.length > 0 ? tailDocs[tailDocs.length - 1] : headDocs;
	if (emptyLineBeforeTail || anyWillBreak(lastDocs)) parts.push(docBreakParent());
	parts.push(docBestFitting([oneLine, expanded]));
	return docGroup(parts);
}

function emptyLineBeforeMember(m: ChainMember): boolean {
	if (m.kind != ChainKind.Static && m.kind != ChainKind.Computed) return false;
	if (m.moved.length > 0) return false;
	const inner = m.kind == ChainKind.Static ? (m.node.data as MemberExprData).object : (m.node.data as ArrayAccessData).array;
	return inner.location.endLine > 0 && m.node.location.line > inner.location.endLine && blankLineBefore(m.node.location.line);
}

function chainShouldBreak(groups: ChainGroups, headDocs: Doc[], tailDocs: Doc[][], hasComments: boolean, options: FormatOptions): boolean {
	if (hasComments) return true;
	const calls: Node[] = [];
	const all: ChainMember[] = [...groups.head];
	for (const g of groups.tail) for (const m of g) all.push(m);
	for (const m of all) {
		if (m.kind == ChainKind.Call) calls.push(m.node);
	}
	let anyFunctionArgument = false;
	let anyComplexArgs = false;
	for (let i = 0; i < calls.length; i += 1) {
		if (i < calls.length - 1 && hasFunctionArgument(calls[i])) anyFunctionArgument = true;
		for (const arg of groupCallArguments(calls[i])) {
			if (!isSimple(arg, options)) anyComplexArgs = true;
		}
	}
	if (calls.length > 2 && anyComplexArgs) return true;
	const lastGroup = tailDocs.length > 0 ? groups.tail[groups.tail.length - 1] : groups.head;
	const lastDocs = tailDocs.length > 0 ? tailDocs[tailDocs.length - 1] : headDocs;
	if (lastGroup[lastGroup.length - 1].kind == ChainKind.Call && anyWillBreak(lastDocs) && anyFunctionArgument) return true;
	if (tailDocs.length > 0 && anyWillBreak(headDocs)) return true;
	for (let i = 0; i < tailDocs.length - 1; i += 1) {
		if (anyWillBreak(tailDocs[i])) return true;
	}
	for (let i = 1; i < groups.tail.length; i += 1) {
		if (emptyLineBeforeMember(groups.tail[i][0])) return true;
	}
	return false;
}


export function printCallExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as CallExprData;
	if (isChainStep(d.callee) && d.callee.kind != NodeKind.CallExpr) return printMemberChain(node, options);
	const prefix = (node.flags.has(NodeFlag.OptionalLink) ? "?." : "") + writtenTypeArgs(node, d.callee, options);
	return docGroup([printAtom(d.callee, options), ...printCallArguments(node, d.arguments, node, prefix, options)]);
}

export function printNewExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as NewExprData;
	const prefix = writtenTypeArgs(node, d.newCallee, options);
	return docGroup([docText("new "), printAtom(d.newCallee, options), ...printCallArguments(null, d.newArguments, node, prefix, options)]);
}
