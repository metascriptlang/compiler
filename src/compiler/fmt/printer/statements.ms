// Statement Printers — blocks, declarations, loops, etc.

import {
	Node, NodeKind, NodeFlag, ProgramData, BlockStmtData,
	ExprStmtData, BinaryExprData, ReturnStmtData, IfStmtData, WhileStmtData,
	ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	MatchStmtData, ThrowStmtData, TryCatchStmtData, DeferStmtData, FunctionDeclData,
	DestructuringDeclData, ObjectPatternData, SourceLocation, IdentifierData, ExportDeclData, DecoratedDeclData, makeLoc,
} from "../../../ast/node";
import { WhenChain, SourceComment, chainsIn, leading, trailing } from "../comments";
import { commentsOfRun, leadingDocs, trailingDocs, danglingOf, danglingBlock, commentsWithin, markWithin, interleave, boxed, withComments, startLineOf, joinKeepingBlankLines } from "./commentDocs";
import { FormatOptions, CommaContext, wantsTrailingComma } from "../options";
import { Doc, docText, docSourceText, docGroup, docIndent, docSoftLine, docHardLine, docJoin, docLine, docCommaSepList, docIfBreak, docNil, docWillBreak } from "../doc";
import { callPrintNode } from "./callbacks";
import { isAssignOp } from "../../../ast/operators";
import { printTypeAnnotation, isObjectTypeAnnotation, inlineObjectType } from "./types";
import { rawBalancedAt, rawGenericsAt, sourceByteAt, sourceSpan, writtenOptional, writtenTypeAfterOptional, unoptionalized, nativeFrom } from "./literals";

class ListItem {
	line: int32;
	column: int32;
	startLine: int32;
	stmt: Node | null;
	chain: WhenChain | null;
	broken: boolean;
}

function chainItem(chain: WhenChain): ListItem {
	const lead = chain.placed.leading;
	const startLine = lead.length > 0 ? lead[0].line : chain.line;
	return { line: chain.line, column: chain.column, startLine, stmt: null, chain, broken: true };
}

function stmtItem(stmt: Node): ListItem {
	const trail = commentsOfRun().trailing(stmt);
	const lead = commentsOfRun().leading(stmt);
	return { line: stmt.location.line, column: stmt.location.column, startLine: startLineOf(stmt), stmt, chain: null, broken: lead.length > 0 || trail.length > 0 };
}

function printChain(chain: WhenChain, options: FormatOptions): Doc {
	const text = sourceSpan(options.source, chain.line, chain.column, chain.endLine, chain.endColumn);
	const parts: Doc[] = [];
	for (const d of leadingDocs(chain.placed.leading)) parts.push(d);
	parts.push(docText(text));
	for (const d of trailingDocs(chain.placed.trailing)) parts.push(d);
	return docGroup(parts);
}

function listItems(container: Node, stmts: Node[]): ListItem[] {
	const items: ListItem[] = [];
	for (const s of unpicked(stmts)) items.push(stmtItem(s));
	for (const chain of commentsOfRun().chainsIn(container)) items.push(chainItem(chain));
	for (let i = 1; i < items.length; i += 1) {
		const moved = items[i];
		let j = i - 1;
		while (j >= 0 && (items[j].line > moved.line || (items[j].line == moved.line && items[j].column > moved.column))) {
			items[j + 1] = items[j];
			j -= 1;
		}
		items[j + 1] = moved;
	}
	return items;
}

function printListItem(item: ListItem, stmts: Node[], options: FormatOptions): Doc {
	if (item.chain != null) return printChain(item.chain, options);
	noteFollowers(stmts, item.stmt!);
	return callPrintNode(item.stmt!, options);
}

function printItems(items: ListItem[], stmts: Node[], options: FormatOptions): Doc[] {
	const docs: Doc[] = [];
	const starts: int32[] = [];
	for (const item of items) {
		docs.push(printListItem(item, stmts, options));
		starts.push(item.startLine);
	}
	return joinKeepingBlankLines(docs, starts);
}

export function printProgram(node: Node, options: FormatOptions): Doc {
	const d = node.data as ProgramData;
	const items = listItems(node, d.programStmts);
	const parts = printItems(items, d.programStmts, options);
	const orphans = danglingOf(node);
	if (items.length == 0) return docGroup([danglingBlock(orphans)]);
	return docGroup(parts);
}

function lastLineOf(node: Node): int32 {
	return node.location.endLine > 0 ? node.location.endLine : node.location.line;
}

let _structAccessors: Node[] = [];
let _listDeclarators: Node[] = [];

export function takeStructAccessors(): Node[] {
	const taken = _structAccessors;
	_structAccessors = [];
	return taken;
}

export function takeListDeclarators(): Node[] {
	const taken = _listDeclarators;
	_listDeclarators = [];
	return taken;
}

function noteFollowers(stmts: Node[], stmt: Node): void {
	_structAccessors = followersAfter(stmts, stmt, structAccessorDecl);
	_listDeclarators = followersAfter(stmts, stmt, listDeclarator);
}

function listDeclarator(s: Node): Node | null {
	const inner = s.kind == NodeKind.ExportDecl ? (s.data as ExportDeclData).exportedDecl : s;
	return inner != null && inner.flags.has(NodeFlag.ContinuesList) ? inner : null;
}

function structAccessorDecl(s: Node): Node | null {
	const inner = s.kind == NodeKind.ExportDecl ? (s.data as ExportDeclData).exportedDecl : s;
	let fn = inner.kind == NodeKind.DecoratedDecl ? (inner.data as DecoratedDeclData).decoratedNode : inner;
	if (fn != null && fn.kind == NodeKind.ExportDecl) fn = (fn.data as ExportDeclData).exportedDecl;
	return fn != null && fn.kind == NodeKind.FunctionDecl && fn.flags.has(NodeFlag.Accessor) ? inner : null;
}

function followersAfter(stmts: Node[], stmt: Node, follower: (s: Node) => Node | null): Node[] {
	const out: Node[] = [];
	let i = stmts.indexOf(stmt) + 1;
	while (i > 0 && i < stmts.length) {
		const next = follower(stmts[i]);
		if (next == null) break;
		out.push(next);
		i += 1;
	}
	return out;
}

function unpicked(stmts: Node[]): Node[] {
	const out: Node[] = [];
	for (const s of stmts) {
		if (!s.flags.has(NodeFlag.WhenPicked) && !isParamPatternDecl(s) && structAccessorDecl(s) == null && listDeclarator(s) == null) out.push(s);
	}
	return out;
}

export function isParamPatternDecl(s: Node): boolean {
	if (s.kind != NodeKind.DestructuringDecl) return false;
	const init = (s.data as DestructuringDeclData).destrInit;
	return init != null && init.kind == NodeKind.Identifier && (init.data as IdentifierData).name.startsWith("_destr")
		&& init.location.line == s.location.line && init.location.column == s.location.column;
}

function isEmptyStatement(node: Node, options: FormatOptions): boolean {
	return options.source != "" && (node.data as BlockStmtData).statements.length == 0
		&& sourceByteAt(options.source, node.location.line, node.location.column) == ";".code;
}

let collapsibleBlock: Node | null = null;

export function printCollapsibleBody(body: Node, options: FormatOptions): Doc {
	collapsibleBlock = body;
	return callPrintNode(body, options);
}

export function printBlock(node: Node, options: FormatOptions): Doc {
	const d = node.data as BlockStmtData;
	const collapsible = node == collapsibleBlock;
	collapsibleBlock = null;
	const items = listItems(node, d.statements);
	const orphans = danglingOf(node);
	if (items.length == 0) {
		if (isEmptyStatement(node, options)) return docText(";");
		if (orphans.length > 0) return boxed("{", [danglingBlock(orphans)], "}");
		if (collapsible) return docText("{}");
		return docGroup([docText("{"), docHardLine(), docText("}")]);
	}
	const stmts = printItems(items, d.statements, options);
	return docGroup([
		docText("{"),
		docIndent([docHardLine(), ...stmts]),
		docHardLine(),
		docText("}"),
	]);
}

export function printExprStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ExprStmtData;
	const parts: Doc[] = [callPrintNode(d.expr, options)];
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

function parenthesizedHeader(inner: Doc): Doc[] {
	return [docText("("), docGroup([docIndent([docSoftLine(), inner]), docSoftLine()]), docText(")")];
}

function isBinaryLike(node: Node): boolean {
	return node.kind == NodeKind.BinaryExpr && !isAssignOp((node.data as BinaryExprData).operator);
}

function returnedArgument(arg: Node, options: FormatOptions): Doc {
	if (!isBinaryLike(arg)) return callPrintNode(arg, options);
	const printed = callPrintNode(arg, options);
	return docGroup([docIfBreak(docText("("), docNil()), docIndent([docSoftLine(), printed]), docSoftLine(), docIfBreak(docText(")"), docNil())]);
}

export function printReturnStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ReturnStmtData;
	const parts: Doc[] = [docText("return")];
	if (d.argument != null) {
		parts.push(docText(" "));
		parts.push(returnedArgument(d.argument, options));
	}
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

function bracelessStatement(body: Node, options: FormatOptions): Node | null {
	if (options.source == "" || body.kind != NodeKind.BlockStmt) return null;
	const block = body.data as BlockStmtData;
	if (block.statements.length != 1) return null;
	const stmt = block.statements[0];
	if (commentsOfRun().leading(stmt).length > 0) return null;
	if (sourceByteAt(options.source, body.location.line, body.location.column) == "{".code) return null;
	return stmt;
}

function printBody(body: Node, options: FormatOptions, collapsible: boolean): Doc {
	const single = bracelessStatement(body, options);
	const printed = single != null ? single : body;
	return collapsible ? printCollapsibleBody(printed, options) : callPrintNode(printed, options);
}

function bodyGap(body: Node, options: FormatOptions): Doc {
	const single = bracelessStatement(body, options);
	const printed = single != null ? single : body;
	return docText(printed.kind == NodeKind.BlockStmt && isEmptyStatement(printed, options) ? "" : " ");
}

function commentsBeforeElse(d: IfStmtData, options: FormatOptions): SourceComment[] {
	const alt = d.alternate!;
	const out: SourceComment[] = [];
	const comments = commentsOfRun();
	for (const owner of [d.consequent, bracelessStatement(d.consequent, options)]) {
		if (owner == null) continue;
		for (const c of comments.trailing(owner)) {
			if (!c.formatted) out.push(c);
		}
	}
	for (const c of comments.leading(alt)) {
		if (!c.formatted && c.line < alt.location.line) out.push(c);
	}
	for (const c of out) c.markFormatted();
	return out;
}

function isUnwrittenElse(alt: Node, options: FormatOptions): boolean {
	if (alt.kind != NodeKind.BlockStmt || (alt.data as BlockStmtData).statements.length != 0) return false;
	return sourceByteAt(options.source, alt.location.line, alt.location.column) != "{".code;
}

export function printIfStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as IfStmtData;
	const hasElse = d.alternate != null && !isUnwrittenElse(d.alternate, options);
	const beforeElse = hasElse ? commentsBeforeElse(d, options) : [];
	const parts: Doc[] = [
		docText("if "),
		...parenthesizedHeader(callPrintNode(d.condition, options)),
		bodyGap(d.consequent, options),
		printBody(d.consequent, options, false),
	];
	if (hasElse) {
		const alt = d.alternate!;
		for (const c of beforeElse) {
			parts.push(docHardLine());
			parts.push(docSourceText(c.text));
		}
		const braceless = bracelessStatement(d.consequent, options);
		const elseOnOwnLine = beforeElse.length > 0
			|| (braceless != null && alt.location.line > lastLineOf(braceless));
		parts.push(elseOnOwnLine ? docGroup([docHardLine(), docText("else")]) : docText(" else"));
		if (alt.kind == NodeKind.IfStmt) {
			parts.push(docText(" "));
			parts.push(callPrintNode(alt, options));
		} else {
			parts.push(bodyGap(alt, options));
			parts.push(printBody(alt, options, false));
		}
	}
	return docGroup(parts);
}

export function printWhileStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as WhileStmtData;
	return docGroup([
		docText("while "),
		...parenthesizedHeader(callPrintNode(d.whileCondition, options)),
		bodyGap(d.whileBody, options),
		printBody(d.whileBody, options, true),
	]);
}

export function printForStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ForStmtData;
	return docGroup([
		docText("for ("),
		callPrintNode(d.forInit, options),
		docText(" "),
		callPrintNode(d.forCondition, options),
		docText("; "),
		callPrintNode(d.forUpdate, options),
		docText(")"),
		bodyGap(d.forBody, options),
		printBody(d.forBody, options, true),
	]);
}

export function printForOfStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ForOfStmtData;
	const asWritten = headerAsWritten(node, d.forOfBody, options, null);
	if (asWritten != null) return docGroup([asWritten, printBody(d.forOfBody, options, true)]);
	let binding = "let";
	if (d.forOfIsConst) { binding = "const"; }
	const target = d.forOfPattern != null ? callPrintNode(d.forOfPattern, options) : docText(d.forOfBinding);
	return docGroup([
		docText("for (" + binding + " "),
		target,
		docText(" of "),
		callPrintNode(d.forOfIterable, options),
		docText(")"),
		bodyGap(d.forOfBody, options),
		printBody(d.forOfBody, options, true),
	]);
}

export function printForInStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ForInStmtData;
	const binding = d.forInIsConst ? "const" : "let";
	return docGroup([
		docText("for (" + binding + " " + d.forInBinding + " in "),
		callPrintNode(d.forInObject, options),
		docText(")"),
		bodyGap(d.forInBody, options),
		printBody(d.forInBody, options, true),
	]);
}

export function printDoWhileStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as DoWhileStmtData;
	const parts: Doc[] = [
		docText("do"),
		bodyGap(d.doBody, options),
		printBody(d.doBody, options, true),
		docText(" while "),
		...parenthesizedHeader(callPrintNode(d.doCondition, options)),
	];
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printSwitchStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as SwitchStmtData;
	const head = [docText("switch "), ...parenthesizedHeader(callPrintNode(d.switchDisc, options)), docText(" ")];
	if (d.switchCases.length == 0) {
		const orphans = danglingOf(node);
		return docGroup([...head, orphans.length == 0 ? docText("{}") : boxed("{", [danglingBlock(orphans)], "}")]);
	}
	const cases: Doc[] = [];
	const starts: int32[] = [];
	for (const c of d.switchCases) {
		cases.push(withComments(c, printSwitchCase(c, options)));
		starts.push(startLineOf(c));
	}
	return docGroup([
		...head,
		docText("{"),
		docIndent([docHardLine(), ...joinKeepingBlankLines(cases, starts)]),
		docHardLine(),
		docText("}"),
	]);
}

function printSwitchCase(node: Node, options: FormatOptions): Doc {
	const d = node.data as SwitchCaseData;
	const parts: Doc[] = [];
	for (const t of d.caseTests) {
		if (parts.length > 0) parts.push(docHardLine());
		parts.push(docText("case "));
		parts.push(callPrintNode(t, options));
		parts.push(docText(":"));
	}
	if (d.isDefault) {
		if (parts.length > 0) parts.push(docHardLine());
		parts.push(docText("default:"));
	}
	if (d.caseStmts.length > 0) {
		const stmts: Doc[] = [];
		const starts: int32[] = [];
		for (const s of d.caseStmts) {
			if (listDeclarator(s) != null) continue;
			noteFollowers(d.caseStmts, s);
			stmts.push(callPrintNode(s, options));
			starts.push(startLineOf(s));
		}
		parts.push(docIndent([docHardLine(), ...joinKeepingBlankLines(stmts, starts)]));
	}
	return docGroup(parts);
}

export function printMatchStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as MatchStmtData;
	const cases: Doc[] = [];
	for (const c of d.matchStmtCases) {
		// Reuses printMatchCase from expressions.ms via callback if needed, 
		// but since it's same structure we can just implement here or export it.
		// For now, assume we'll use callPrintNode for the cases too.
		cases.push(callPrintNode(c, options));
	}
	return docGroup([
		docText("match ("),
		callPrintNode(d.matchStmtDisc, options),
		docText(") {"),
		docIndent([docHardLine(), docJoin(cases, docHardLine())]),
		docHardLine(),
		docText("}"),
	]);
}

export function printThrowStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ThrowStmtData;
	const parts: Doc[] = [docText("throw "), returnedArgument(d.throwArg, options)];
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printTryCatchStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as TryCatchStmtData;
	const hasFinally = d.finallyBody != null && !isSynthesized(node, d.finallyBody);
	const parts: Doc[] = [docText("try "), callPrintNode(d.tryBody, options)];
	if (d.hasCatchClause) {
		parts.push(docText(" catch"));
		if (d.catchName != "") {
			parts.push(docText(" (" + d.catchName + ")"));
		}
		parts.push(docText(" "));
		parts.push(hasFinally ? callPrintNode(d.catchBody, options) : printCollapsibleBody(d.catchBody, options));
	}
	if (hasFinally) {
		parts.push(docText(" finally "));
		parts.push(callPrintNode(d.finallyBody, options));
	}
	return docGroup(parts);
}

export function printDeferStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as DeferStmtData;
	const parts: Doc[] = [docText("defer "), callPrintNode(d.deferExpr, options)];
	if (options.semi && d.deferExpr.kind != NodeKind.BlockStmt) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printBreakStmt(node: Node): Doc {
	const d = node.data as { breakLabel: string };
	if (d.breakLabel != "") return docText("break " + d.breakLabel + ";");
	return docText("break;");
}

export function printContinueStmt(node: Node): Doc {
	const d = node.data as { continueLabel: string };
	if (d.continueLabel != "") return docText("continue " + d.continueLabel + ";");
	return docText("continue;");
}

// =============================================================
// Shared helpers used by all printers (declarations + expressions)
// =============================================================

// Build the Doc list for a comma-separated parameter list with optional
// default values. Used by every printer that emits `(name: T = init, ...)`:
// Function/Method/Constructor/Arrow/FunctionExpr/Macro decls.
//
// `defaults` may be shorter than `names`/`types` (or contain null entries) —
// missing defaults emit just the bare param. Pass an empty array to suppress
// defaults entirely (e.g. macro decls don't have defaults).
function inlineObjectPattern(pattern: Node, options: FormatOptions): Doc[] {
	const d = pattern.data as ObjectPatternData;
	const body: Doc[] = [docLine()];
	for (let i = 0; i < d.patternProps.length; i += 1) {
		if (i > 0) {
			body.push(docText(","));
			body.push(docLine());
		}
		body.push(callPrintNode(d.patternProps[i], options));
	}
	if (!d.hasRestProp && wantsTrailingComma(options, CommaContext.Collection)) body.push(docIfBreak(docText(","), docNil()));
	return [docText("{"), docIndent(body), docLine(), docText("}")];
}

export function buildParamList(names: string[], types: string[], defaults: Node[], options: FormatOptions, locs: SourceLocation[] | null = null, typeExprs: Node[] | null = null, patterns: (Node | null)[] | null = null): Doc[] {
	const out: Doc[] = [];
	for (let i = 0; i < names.length; i += 1) {
		const pattern = patterns != null && i < patterns.length ? patterns[i] : null;
		const typeExpr = typeExprs != null && i < typeExprs.length ? typeExprs[i] : null;
		if (pattern != null && i < types.length && types[i] != "" && (defaults.length <= i || defaults[i] == null)) {
			const inlineType = inlineObjectType(typeExpr, types[i], options);
			if (inlineType != null) {
				out.push(docGroup([...inlineObjectPattern(pattern, options), docText(": "), ...inlineType]));
				continue;
			}
		}
		let p = spellParamModifiers(names[i]);
		let written = p.startsWith("...") ? p.byteSlice(3, p.byteLength) : p;
		if (names[i].startsWith("_destr") && locs != null && i < locs.length) {
			const pattern = rawBalancedAt(options.source, locs[i].line, locs[i].column);
			if (pattern != "") { p = pattern; written = pattern; }
		}
		const optional = locs != null && i < locs.length && writtenOptional(options.source, locs[i].line, locs[i].column, written);
		const type = i < types.length ? types[i] : "";
		if (optional) p = p + "?";
		const head: Doc[] = [];
		if (type != "") {
			const keptType = optional && writtenTypeAfterOptional(options.source, locs![i].line, locs![i].column, written, type);
			head.push(docText(p + ": "));
			head.push(printTypeAnnotation(typeExprs != null && i < typeExprs.length ? typeExprs[i] : null, optional && !keptType ? unoptionalized(type) : type, options));
		} else {
			head.push(docText(p));
		}
		const def = i < defaults.length ? defaults[i] : null;
		if (def != null && !optional) {
			out.push(docGroup([...head, docText(" = "), callPrintNode(def, options)]));
		} else {
			out.push(docGroup(head));
		}
	}
	return out;
}

// Wrap a built param list in `( ... )` with the standard
// indent/softline group; returns the Doc fragments to push.
export function paramListInParens(params: Doc[], options: FormatOptions, hug: boolean = false, grouped: boolean = true): Doc[] {
	const parts: Doc[] = [docText("(")];
	if (hug && params.length == 1) {
		parts.push(params[0]);
	} else if (params.length > 0) {
		const paramParts = docCommaSepList(params, wantsTrailingComma(options, CommaContext.Params));
		const list: Doc[] = [docIndent(paramParts), docSoftLine()];
		if (grouped) parts.push(docGroup(list));
		else for (const x of list) parts.push(x);
	}
	parts.push(docText(")"));
	return parts;
}

// A sole parameter typed as an object type stays on the parenthesis line, so the type's braces break instead.
export function hugsObjectParam(names: string[], types: string[], defaults: Node[], typeExprs: Node[] | null, options: FormatOptions): boolean {
	if (names.length != 1 || types.length != 1 || typeExprs == null || typeExprs.length != 1) return false;
	if (defaults.length > 0 && defaults[0] != null) return false;
	return isObjectTypeAnnotation(typeExprs[0], types[0], options);
}

// `<T, U>` if non-empty, else `""`. Centralises the generic-clause emit
// pattern used by TypeAlias/Function/Method/Class/Interface decls.
export function writtenName(options: FormatOptions, loc: SourceLocation, name: string): string {
	if (loc == null || sourceByteAt(options.source, loc.line, loc.column) != "`".code) return name;
	return "`" + name + "`";
}

export function genericsFor(options: FormatOptions, loc: SourceLocation, name: string, names: string): string {
	const raw = loc != null ? rawGenericsAt(options.source, loc.line, loc.column, name) : "";
	return raw != "" ? raw : wrapGenerics(names);
}

export function wrapGenerics(names: string): string {
	return names != "" ? "<" + names + ">" : "";
}

// fnFlags format: pipe-separated tokens, e.g. "async|gen:T,U|ext:string".
// Returns true if `name` is present as a bare flag.
export function flagHas(flags: string, name: string): boolean {
	if (flags == name) return true;
	if (flags.length < name.length) return false;
	let i = 0;
	while (i < flags.length) {
		let j = i;
		while (j < flags.length && flags.charCodeAt(j) != "|".code) j = j + 1;
		const tok = flags.slice(i, j);
		if (tok == name) return true;
		i = j + 1;
	}
	return false;
}

// Returns the suffix of the first `name:<value>` segment, or "".
export function flagGet(flags: string, name: string): string {
	let i = 0;
	while (i < flags.length) {
		let j = i;
		while (j < flags.length && flags.charCodeAt(j) != "|".code) j = j + 1;
		const tok = flags.slice(i, j);
		if (tok.length > name.length + 1 && tok.slice(0, name.length) == name && tok.charCodeAt(name.length) == ":".code) {
			return tok.slice(name.length + 1, tok.length);
		}
		i = j + 1;
	}
	return "";
}

function spellParamModifiers(name: string): string {
	let rest = name;
	let spelled = "";
	let more = true;
	while (more) {
		more = false;
		for (const [code, word] of [["out:", "out "], ["ref:", "ref "], ["rdonly:", "readonly "], ["sink:", "sink "]]) {
			if (rest.startsWith(code) && rest.byteLength > code.byteLength) {
				spelled = spelled + word;
				rest = rest.byteSlice(code.byteLength, rest.byteLength);
				more = true;
			}
		}
	}
	return spelled + rest;
}

export function commentedList(items: Doc[], locs: SourceLocation[], inner: SourceComment[], open: string, close: string): Doc {
	const lines: int32[] = [];
	const entries: Doc[] = [];
	for (let i = 0; i < items.length; i += 1) {
		lines.push(i < locs.length ? locs[i].line : 0);
		entries.push(docGroup([items[i], docText(",")]));
	}
	return boxed(open, interleave(entries, lines, lines, inner), close);
}

function pushPlaced(holder: Node, out: SourceComment[]): void {
	const comments = commentsOfRun();
	for (const list of [comments.leading(holder), comments.dangling(holder), comments.trailing(holder)]) {
		for (const c of list) {
			if (!c.formatted) out.push(c);
		}
	}
}

function before(c: SourceComment, line: int32, column: int32): boolean {
	return c.line < line || (c.line == line && c.column < column);
}

function signatureComments(decl: Node, body: Node): SourceComment[] {
	const holders: Node[] = [decl, body];
	if (body.kind == NodeKind.BlockStmt) {
		const stmts = (body.data as BlockStmtData).statements;
		if (stmts.length > 0) holders.push(stmts[0]);
	}
	const all: SourceComment[] = [];
	for (const h of holders) pushPlaced(h, all);
	const inner: SourceComment[] = [];
	for (const c of all) {
		const afterStart = c.line > decl.location.line || (c.line == decl.location.line && c.column > decl.location.column);
		if (afterStart && before(c, body.location.line, body.location.column)) inner.push(c);
	}
	for (let i = 1; i < inner.length; i += 1) {
		const c = inner[i];
		let j = i - 1;
		while (j >= 0 && (inner[j].line > c.line || (inner[j].line == c.line && inner[j].column > c.column))) {
			inner[j + 1] = inner[j];
			j -= 1;
		}
		inner[j + 1] = c;
	}
	return inner;
}

export function paramListComments(node: Node, body: Node): SourceComment[] {
	if (body == null || isSynthesized(node, body)) return [];
	const inner: SourceComment[] = [];
	for (const c of signatureComments(node, body)) {
		if (c.line > node.location.line) inner.push(c);
	}
	return inner;
}

function onParamLines(comments: SourceComment[], decl: Node, paramLocs: SourceLocation[] | null): boolean {
	if (paramLocs == null || paramLocs.length == 0) return false;
	const lastLine = paramLocs[paramLocs.length - 1].line;
	for (const c of comments) {
		if (c.line <= decl.location.line || c.line >= lastLine) return false;
	}
	return true;
}

export function headerAsWritten(decl: Node, body: Node, options: FormatOptions, paramLocs: SourceLocation[] | null): Doc | null {
	if (options.source == "" || body == null || isSynthesized(decl, body)) return null;
	const written = commentsWithin(decl.location, body.location);
	if (written.length == 0) return null;
	const inner = signatureComments(decl, body);
	if (inner.length == written.length && onParamLines(inner, decl, paramLocs)) return null;
	const text = sourceSpan(options.source, decl.location.line, decl.location.column, body.location.line, body.location.column);
	if (text == "") return null;
	markWithin(decl.location, body.location);
	const head = text.trimEnd();
	const gap = text.byteSlice(head.byteLength, text.byteLength);
	return docGroup([docText(head), gap.includes("\n") ? docHardLine() : docText(" ")]);
}

function prefixAt(names: string[], positions: string, word: string): void {
	if (positions == "") return;
	for (const p of positions.split(",")) {
		const i = p.parseInt() as int32;
		if (i >= 0 && i < names.length) names[i] = word + names[i];
	}
}

// A type is captured as text, which skips its comments; when one is written between
// `line:column` and the type's end, the span is returned as written.
export function typedAsWritten(line: int32, column: int32, typeExpr: Node | null, options: FormatOptions): string {
	if (options.source == "" || typeExpr == null || typeExpr.location.endLine == 0) return "";
	const start = makeLoc(line, column);
	const end = makeLoc(typeExpr.location.endLine, typeExpr.location.endColumn);
	if (commentsWithin(start, end).length == 0) return "";
	const text = sourceSpan(options.source, line, column, end.line, end.column);
	if (text != "") markWithin(start, end);
	return text;
}

export function isSynthesized(decl: Node, body: Node): boolean {
	return body.location.line == decl.location.line && body.location.column == decl.location.column;
}

export function parameterPatterns(body: Node, names: string[]): (Node | null)[] {
	const out: (Node | null)[] = [];
	for (const name of names) out.push(null);
	if (body.kind != NodeKind.BlockStmt) return out;
	for (const s of (body.data as BlockStmtData).statements) {
		if (!isParamPatternDecl(s)) continue;
		const d = s.data as DestructuringDeclData;
		const at = names.indexOf((d.destrInit.data as IdentifierData).name);
		if (at >= 0 && d.destrPattern.kind == NodeKind.ObjectPattern && (d.destrPattern.data as ObjectPatternData).patternProps.length > 0) out[at] = d.destrPattern;
	}
	return out;
}

export function groupsParameters(generics: string, count: number, returnExpr: Node | null, returnText: string, returnType: Doc[], options: FormatOptions): boolean {
	if (returnText == "" || count != 1) return false;
	if (generics.contains(",") || generics.contains(" extends ") || generics.contains("=")) return false;
	if (isObjectTypeAnnotation(returnExpr, returnText, options)) return true;
	for (const part of returnType) {
		if (docWillBreak(part)) return true;
	}
	return false;
}

export function printFunctionDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as FunctionDeclData;
	// fnFlags carries: "async", "generator", "async_generator", "extern",
	// and "gen:T,U" (generics). Decode each into the appropriate keyword.
	const isExtern = flagHas(d.fnFlags, "extern");
	const isAsync = flagHas(d.fnFlags, "async") || flagHas(d.fnFlags, "async_generator");
	const isGen = flagHas(d.fnFlags, "generator") || flagHas(d.fnFlags, "async_generator");
	const head = (isExtern ? "extern " : "")
		+ (isAsync ? "async " : "")
		+ (node.flags.has(NodeFlag.Converter) ? "converter" : flagHas(d.fnFlags, "template") ? "template" : "function") + (isGen ? "*" : "") + " "
		+ writtenName(options, d.nameLocation, d.fnName) + genericsFor(options, d.nameLocation, writtenName(options, d.nameLocation, d.fnName), flagGet(d.fnFlags, "gen"));

	const parts: Doc[] = [docText(head)];
	const names: string[] = [];
	const types: string[] = [];
	const defaults: Node[] = [];
	for (let i = 0; i < d.params.length; i += 1) {
		names.push(d.params[i]);
		types.push(i < d.fnParamTypes.length ? d.fnParamTypes[i] : "");
		defaults.push(i < d.fnDefaults.length ? d.fnDefaults[i] : null as unknown as Node);
	}
	prefixAt(names, flagGet(d.fnFlags, "sink"), "sink ");
	prefixAt(names, flagGet(d.fnFlags, "rdonly"), "readonly ");
	prefixAt(names, flagGet(d.fnFlags, "ref"), "ref ");
	prefixAt(names, flagGet(d.fnFlags, "out"), "out ");
	if (flagGet(d.fnFlags, "ext") != "" && names.length > 0) names[0] = "this " + names[0];
	const params: Doc[] = [];
	const staticType = flagGet(d.fnFlags, "sext");
	const asWritten = headerAsWritten(node, d.fnBody, options, staticType == "" ? node.paramLocations : null);
	if (asWritten != null) return docGroup([asWritten, printCollapsibleBody(d.fnBody, options)]);
	if (staticType != "") params.push(docText("this typeof " + staticType));
	for (const p of buildParamList(names, types, defaults, options, node.paramLocations, node.typeExprs, parameterPatterns(d.fnBody, names))) params.push(p);
	const paramComments = paramListComments(node, d.fnBody);
	const returnType: Doc[] = [];
	if (d.fnReturnType != "") {
		returnType.push(docText(": "));
		returnType.push(printTypeAnnotation(node.typeExpr, d.fnReturnType, options));
	}
	const signature: Doc[] = [];
	if (paramComments.length > 0 && node.paramLocations != null && staticType == "") {
		signature.push(commentedList(params, node.paramLocations, paramComments, "(", ")"));
	} else {
		const groupParams = groupsParameters(flagGet(d.fnFlags, "gen"), params.length, node.typeExpr, d.fnReturnType, returnType, options);
		for (const p of paramListInParens(params, options, hugsObjectParam(names, types, defaults, node.typeExprs, options), groupParams)) signature.push(p);
	}
	for (const p of returnType) signature.push(p);
	parts.push(docGroup(signature));

	if (isSynthesized(node, d.fnBody)) {
		if (d.nativeName != "") {
			parts.push(docText(nativeFrom(d.nativeName)));
		}
		parts.push(docText(";"));
		return docGroup(parts);
	}

	parts.push(docText(" "));
	parts.push(printCollapsibleBody(d.fnBody, options));
	return docGroup(parts);
}
