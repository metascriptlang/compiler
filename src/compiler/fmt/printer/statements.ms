// Statement Printers — blocks, declarations, loops, etc.

import {
	Node, NodeKind, NodeFlag, DeclKind, ProgramData, BlockStmtData, VariableDeclData,
	ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData,
	ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	MatchStmtData, ThrowStmtData, TryCatchStmtData, DeferStmtData, FunctionDeclData,
	DestructuringDeclData, SourceLocation, IdentifierData,
} from "../../../ast/node";
import { Token } from "../../../lexer/token";
import { FormatOptions, CommaContext, wantsTrailingComma } from "../options";
import { Doc, docText, docGroup, docIndent, docLine, docSoftLine, docHardLine, docLineSuffix, docBreakParent, docJoin, docCommaSepList } from "../doc";
import { callPrintNode } from "./callbacks";
import { rawBalancedAt, rawGenericsAt, sourceByteAt } from "./literals";

export function printProgram(node: Node, options: FormatOptions): Doc {
	const d = node.data as ProgramData;
	const written = unpicked(d.programStmts);
	const parts: Doc[] = [];
	for (let i = 0; i < written.length; i += 1) {
		const stmt = written[i];

		// Extract inter-statement comments: comments AFTER this statement
		// (line > stmt.endLine) but before the next statement. These are
		// standalone comments between sibling stmts. Comments INSIDE the
		// stmt's body (line ≤ endLine) belong to inner nodes (enum members,
		// interface fields, etc.) — leave them on stmt.comments so the
		// inner printers can attach them.
		const interComments: Token[] = [];
		if (stmt.comments.length > 0) {
			const stmtEnd = stmt.location.endLine > 0 ? stmt.location.endLine : stmt.location.line;
			const nextLine = (i + 1 < written.length) ? written[i + 1].location.line : 999999;
			const remaining: Token[] = [];
			for (const comment of stmt.comments) {
				if (comment.line > stmtEnd && comment.line < nextLine) {
					interComments.push(comment);
				} else {
					remaining.push(comment);
				}
			}
			stmt.comments = remaining;
		}

		if (i > 0) {
			parts.push(docHardLine());
			// Preserve one blank line between statement groups (Prettier convention)
			const prev = written[i - 1].location;
			const prevEnd = prev.endLine > 0 ? prev.endLine : prev.line;
			const currLine = written[i].location.line;
			if (currLine - prevEnd > 1) {
				parts.push(docHardLine());
			}
		}
		parts.push(callPrintNode(stmt, options));

		// Emit inter-statement comments: blank line before first, single newline between
		for (let ci = 0; ci < interComments.length; ci += 1) {
			parts.push(docHardLine());
			if (ci == 0) parts.push(docHardLine());
			parts.push(docText(interComments[ci].value));
		}
	}
	return docGroup(parts);
}

function unpicked(stmts: Node[]): Node[] {
	const out: Node[] = [];
	for (const s of stmts) {
		if (!s.flags.has(NodeFlag.WhenPicked) && !isParamPatternDecl(s)) out.push(s);
	}
	return out;
}

export function isParamPatternDecl(s: Node): boolean {
	if (s.kind != NodeKind.DestructuringDecl) return false;
	const init = (s.data as DestructuringDeclData).destrInit;
	return init != null && init.kind == NodeKind.Identifier && (init.data as IdentifierData).name.startsWith("_destr")
		&& init.location.line == s.location.line && init.location.column == s.location.column;
}

export function wrapNodeComments(node: Node, innerDoc: Doc): Doc {
	// Wrap with comments if present.
	// 3 buckets by relative line:
	//   - leading: comment.line < node.line (before)
	//   - trailing: comment.line === node.line (same line, end-of-line comment)
	//   - below: comment.line > node.line (standalone line(s) after the stmt)
	if (node.comments.length > 0) {
		const leading: Doc[] = [];
		const trailing: Doc[] = [];
		const below: Doc[] = [];
		for (const comment of node.comments) {
			if (comment.line < node.location.line) {
				leading.push(docText(comment.value));
				leading.push(docHardLine());
			} else if (comment.line == node.location.line) {
				trailing.push(docLineSuffix([docText(" " + comment.value)]));
				if (comment.value.startsWith("//")) trailing.push(docBreakParent());
			} else {
				below.push(docHardLine());
				below.push(docText(comment.value));
			}
		}
		if (leading.length > 0 || trailing.length > 0 || below.length > 0) {
			const parts: Doc[] = [];
			for (const l of leading) { parts.push(l); }
			parts.push(innerDoc);
			for (const t of trailing) { parts.push(t); }
			for (const b of below) { parts.push(b); }
			return docGroup(parts);
		}
	}

	return innerDoc;
}

export function printBlock(node: Node, options: FormatOptions): Doc {
	const d = node.data as BlockStmtData;
	const inner: Token[] = [];
	const outer: Token[] = [];
	const loc = node.location;
	for (const c of node.comments) {
		const afterOpen = c.line > loc.line || (c.line == loc.line && c.column > loc.column);
		const beforeClose = loc.endLine == 0 || c.line < loc.endLine || (c.line == loc.endLine && c.column < loc.endColumn);
		if (afterOpen && beforeClose) {
			inner.push(c);
		} else {
			outer.push(c);
		}
	}
	node.comments = outer;
	const written = unpicked(d.statements);
	if (written.length == 0 && inner.length == 0) return docText("{}");
	const stmts: Doc[] = [];
	for (const s of written) {
		stmts.push(callPrintNode(s, options));
	}
	for (const c of inner) {
		stmts.push(docText(c.value));
	}
	if (inner.length > 0) {
		return docGroup([
			docText("{"),
			docIndent([docHardLine(), docJoin(stmts, docHardLine())]),
			docHardLine(),
			docText("}"),
		]);
	}

	// Single-statement block can stay inline (`{ stmt }`) when it fits
	// printWidth. Multi-stmt blocks always break — flattening multiple
	// statements onto one line is unreadable. Statements with leading
	// comments also break, so the comments don't get smushed inline.
	if (written.length == 1 && written[0].comments.length == 0) {
		return docGroup([
			docText("{"),
			docIndent([docLine(), stmts[0]]),
			docLine(),
			docText("}"),
		]);
	}

	return docGroup([
		docText("{"),
		docIndent([docHardLine(), docJoin(stmts, docHardLine())]),
		docHardLine(),
		docText("}"),
	]);
}

export function printVariableDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as VariableDeclData;
	const kind = match (d.declKind) {
		DeclKind.Const => "const",
		DeclKind.Let => "let",
		DeclKind.Var => "var",
		_ => "let",
	};

	const storage = node.flags.has(NodeFlag.StaticStorage) ? "static " : "";
	const parts: Doc[] = [docText(storage + kind + " " + d.declName)];
	if (d.declType != "") {
		parts.push(docText(": " + d.declType));
	}
	if (d.initializer != null) {
		parts.push(docText(" = "));
		parts.push(callPrintNode(d.initializer, options));
	}
	if (options.semi) {
		parts.push(docText(";"));
	}

	return docGroup(parts);
}

export function printExprStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ExprStmtData;
	const parts: Doc[] = [callPrintNode(d.expr, options)];
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printReturnStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ReturnStmtData;
	const parts: Doc[] = [docText("return")];
	if (d.argument != null) {
		parts.push(docText(" "));
		parts.push(callPrintNode(d.argument, options));
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
	for (const c of stmt.comments) {
		if (c.line < stmt.location.line) return null;
	}
	if (sourceByteAt(options.source, body.location.line, body.location.column) == "{".code) return null;
	return stmt;
}

function printBody(body: Node, options: FormatOptions): Doc {
	const single = bracelessStatement(body, options);
	return callPrintNode(single != null ? single : body, options);
}

export function printIfStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as IfStmtData;
	const parts: Doc[] = [
		docText("if ("),
		callPrintNode(d.condition, options),
		docText(") "),
		printBody(d.consequent, options),
	];
	// Skip empty else blocks (parser may create a BlockStmt with 0 statements)
	if (d.alternate != null) {
		let isEmpty = false;
		if (d.alternate.kind == NodeKind.BlockStmt) {
			const altData = d.alternate.data as BlockStmtData;
			if (altData.statements.length == 0) { isEmpty = true; }
		}
		if (!isEmpty) {
			const beforeElse: Token[] = [];
			const kept: Token[] = [];
			for (const c of d.alternate.comments) {
				if (c.line < d.alternate.location.line) beforeElse.push(c); else kept.push(c);
			}
			d.alternate.comments = kept;
			for (const c of beforeElse) {
				parts.push(docHardLine());
				parts.push(docText(c.value));
			}
			const braceless = bracelessStatement(d.consequent, options);
			const elseOnOwnLine = beforeElse.length > 0
				|| (braceless != null && d.alternate.location.line > braceless.location.line);
			parts.push(elseOnOwnLine ? docGroup([docHardLine(), docText("else ")]) : docText(" else "));
			parts.push(d.alternate.kind == NodeKind.IfStmt
				? callPrintNode(d.alternate, options)
				: printBody(d.alternate, options));
		}
	}
	return docGroup(parts);
}

export function printWhileStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as WhileStmtData;
	return docGroup([
		docText("while ("),
		callPrintNode(d.whileCondition, options),
		docText(") "),
		printBody(d.whileBody, options),
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
		docText(") "),
		printBody(d.forBody, options),
	]);
}

export function printForOfStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ForOfStmtData;
	let binding = "let";
	if (d.forOfIsConst) { binding = "const"; }
	const target = d.forOfPattern != null ? callPrintNode(d.forOfPattern, options) : docText(d.forOfBinding);
	return docGroup([
		docText("for (" + binding + " "),
		target,
		docText(" of "),
		callPrintNode(d.forOfIterable, options),
		docText(") "),
		printBody(d.forOfBody, options),
	]);
}

export function printForInStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ForInStmtData;
	const binding = d.forInIsConst ? "const" : "let";
	return docGroup([
		docText("for (" + binding + " " + d.forInBinding + " in "),
		callPrintNode(d.forInObject, options),
		docText(") "),
		printBody(d.forInBody, options),
	]);
}

export function printDestructuringDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as DestructuringDeclData;
	const kind = d.destrIsConst ? "const" : "let";
	const parts: Doc[] = [
		docText(kind + " "),
		callPrintNode(d.destrPattern, options),
		docText(" = "),
		callPrintNode(d.destrInit, options),
	];
	if (options.semi) parts.push(docText(";"));
	return docGroup(parts);
}

export function printDoWhileStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as DoWhileStmtData;
	const parts: Doc[] = [
		docText("do "),
		callPrintNode(d.doBody, options),
		docText(" while ("),
		callPrintNode(d.doCondition, options),
		docText(")"),
	];
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printSwitchStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as SwitchStmtData;
	const cases: Doc[] = [];
	for (const c of d.switchCases) {
		cases.push(printSwitchCase(c, options));
	}
	return docGroup([
		docText("switch ("),
		callPrintNode(d.switchDisc, options),
		docText(") {"),
		docIndent([docHardLine(), docJoin(cases, docHardLine())]),
		docHardLine(),
		docText("}"),
	]);
}

function printSwitchCase(node: Node, options: FormatOptions): Doc {
	const d = node.data as SwitchCaseData;
	const parts: Doc[] = [];
	if (d.isDefault) {
		parts.push(docText("default:"));
	} else {
		for (const t of d.caseTests) {
			parts.push(docText("case "));
			parts.push(callPrintNode(t, options));
			parts.push(docText(":"));
		}
	}
	if (d.caseStmts.length > 0) {
		const stmts: Doc[] = [];
		for (const s of d.caseStmts) {
			stmts.push(callPrintNode(s, options));
		}
		parts.push(docIndent([docHardLine(), docJoin(stmts, docHardLine())]));
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
	const parts: Doc[] = [docText("throw "), callPrintNode(d.throwArg, options)];
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printTryCatchStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as TryCatchStmtData;
	const parts: Doc[] = [docText("try "), callPrintNode(d.tryBody, options)];
	if (d.hasCatchClause) {
		parts.push(docText(" catch"));
		if (d.catchName != "") {
			parts.push(docText(" (" + d.catchName + ")"));
		}
		parts.push(docText(" "));
		parts.push(callPrintNode(d.catchBody, options));
	}
	if (d.finallyBody != null && !isSynthesized(node, d.finallyBody)) {
		parts.push(docText(" finally "));
		parts.push(callPrintNode(d.finallyBody, options));
	}
	return docGroup(parts);
}

export function printDeferStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as DeferStmtData;
	const parts: Doc[] = [docText("defer "), callPrintNode(d.deferExpr, options)];
	if (options.semi) {
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
export function buildParamList(names: string[], types: string[], defaults: Node[], options: FormatOptions, locs: SourceLocation[] | null = null): Doc[] {
	const out: Doc[] = [];
	for (let i = 0; i < names.length; i += 1) {
		let p = spellParamModifiers(names[i]);
		if (names[i].startsWith("_destr") && locs != null && i < locs.length) {
			const pattern = rawBalancedAt(options.source, locs[i].line, locs[i].column);
			if (pattern != "") p = pattern;
		}
		if (i < types.length && types[i] != "") {
			p = p + ": " + types[i];
		}
		const def = i < defaults.length ? defaults[i] : null;
		if (def != null) {
			out.push(docGroup([docText(p + " = "), callPrintNode(def, options)]));
		} else {
			out.push(docText(p));
		}
	}
	return out;
}

// Wrap a built param list in `( ... )` with the standard
// indent/softline group; returns the Doc fragments to push.
export function paramListInParens(params: Doc[], options: FormatOptions): Doc[] {
	const parts: Doc[] = [docText("(")];
	if (params.length > 0) {
		const paramParts = docCommaSepList(params, wantsTrailingComma(options, CommaContext.Params));
		parts.push(docGroup([docIndent(paramParts), docSoftLine()]));
	}
	parts.push(docText(")"));
	return parts;
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

export function commentedList(items: Doc[], locs: SourceLocation[], inner: Token[], open: string, close: string): Doc {
	const lines: Doc[] = [];
	let ci = 0;
	for (let i = 0; i < items.length; i += 1) {
		const line = i < locs.length ? locs[i].line : 0;
		while (ci < inner.length && inner[ci].line < line) {
			lines.push(docText(inner[ci].value));
			ci += 1;
		}
		const lastOnLine = i + 1 >= items.length || (i + 1 < locs.length && locs[i + 1].line != line);
		const entry: Doc[] = [items[i], docText(",")];
		while (lastOnLine && ci < inner.length && inner[ci].line == line) {
			entry.push(docLineSuffix([docText(" " + inner[ci].value)]));
			ci += 1;
		}
		lines.push(docGroup(entry));
	}
	while (ci < inner.length) {
		lines.push(docText(inner[ci].value));
		ci += 1;
	}
	return docGroup([docText(open), docIndent([docHardLine(), docJoin(lines, docHardLine())]), docHardLine(), docText(close)]);
}

export function paramListComments(node: Node, body: Node): Token[] {
	if (body == null || isSynthesized(node, body)) return [];
	const inner: Token[] = [];
	takeSignatureComments(node, node, body, inner);
	takeSignatureComments(body, node, body, inner);
	if (body.kind == NodeKind.BlockStmt) {
		const stmts = (body.data as BlockStmtData).statements;
		if (stmts.length > 0) takeSignatureComments(stmts[0], node, body, inner);
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

function takeSignatureComments(holder: Node, decl: Node, body: Node, into: Token[]): void {
	const rest: Token[] = [];
	for (const c of holder.comments) {
		const beforeBody = c.line < body.location.line || (c.line == body.location.line && c.column < body.location.column);
		if (c.line > decl.location.line && beforeBody) into.push(c); else rest.push(c);
	}
	holder.comments = rest;
}

function prefixAt(names: string[], positions: string, word: string): void {
	if (positions == "") return;
	for (const p of positions.split(",")) {
		const i = p.parseInt() as int32;
		if (i >= 0 && i < names.length) names[i] = word + names[i];
	}
}

export function isSynthesized(decl: Node, body: Node): boolean {
	return body.location.line == decl.location.line && body.location.column == decl.location.column;
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
	const staticType = flagGet(d.fnFlags, "sext");
	if (staticType != "") {
		names.push("this typeof " + staticType);
		types.push("");
		defaults.push(null as unknown as Node);
	}
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
	const params = buildParamList(names, types, defaults, options, node.paramLocations);
	const paramComments = paramListComments(node, d.fnBody);
	if (paramComments.length > 0 && node.paramLocations != null && staticType == "") {
		parts.push(commentedList(params, node.paramLocations, paramComments, "(", ")"));
	} else {
		for (const p of paramListInParens(params, options)) parts.push(p);
	}

	if (d.fnReturnType != "") {
		parts.push(docText(": " + d.fnReturnType));
	}

	if (isSynthesized(node, d.fnBody)) {
		if (d.nativeName != "") {
			parts.push(docText(" from \"" + d.nativeName + "\""));
		}
		parts.push(docText(";"));
		return docGroup(parts);
	}

	parts.push(docText(" "));
	parts.push(callPrintNode(d.fnBody, options));
	return docGroup(parts);
}
