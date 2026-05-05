// Statement Printers — blocks, declarations, loops, etc.

import {
	Node, NodeKind, DeclKind, ProgramData, BlockStmtData, VariableDeclData,
	ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData,
	ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	MatchStmtData, ThrowStmtData, TryCatchStmtData, DeferStmtData, FunctionDeclData,
	DestructuringDeclData,
} from "../../../ast/node";
import { Token } from "../../../lexer/token";
import { FormatOptions, CommaContext, wantsTrailingComma } from "../options";
import { Doc, docText, docGroup, docIndent, docLine, docSoftLine, docHardLine, docJoin, docCommaSepList } from "../doc";
import { callPrintNode } from "./callbacks";

export function printProgram(node: Node, options: FormatOptions): Doc {
	const d = node.data as ProgramData;
	const parts: Doc[] = [];
	for (let i = 0; i < d.programStmts.length; i += 1) {
		const stmt = d.programStmts[i];

		// Extract inter-statement comments: comments AFTER this statement
		// (line > stmt.endLine) but before the next statement. These are
		// standalone comments between sibling stmts. Comments INSIDE the
		// stmt's body (line ≤ endLine) belong to inner nodes (enum members,
		// interface fields, etc.) — leave them on stmt.comments so the
		// inner printers can attach them.
		const interComments: Token[] = [];
		if (stmt.comments.length > 0) {
			const stmtEnd = stmt.location.endLine > 0 ? stmt.location.endLine : stmt.location.line;
			const nextLine = (i + 1 < d.programStmts.length) ? d.programStmts[i + 1].location.line : 999999;
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
			const prevLine = d.programStmts[i - 1].location.line;
			const currLine = d.programStmts[i].location.line;
			if (currLine - prevLine > 1) {
				parts.push(docHardLine());
			}
		}
		parts.push(callPrintNode(stmt, options));

		// Emit inter-statement comments: blank line before first, single newline between
		for (let ci = 0; ci < interComments.length; ci += 1) {
			parts.push(docHardLine());
			if (ci === 0) parts.push(docHardLine());
			parts.push(docText(interComments[ci].value));
		}
	}
	return docGroup(parts);
}

export function printBlock(node: Node, options: FormatOptions): Doc {
	const d = node.data as BlockStmtData;
	if (d.statements.length === 0) return docText("{}");
	const stmts: Doc[] = [];
	for (const s of d.statements) {
		stmts.push(callPrintNode(s, options));
	}

	// Single-statement block can stay inline (`{ stmt }`) when it fits
	// printWidth. Multi-stmt blocks always break — flattening multiple
	// statements onto one line is unreadable. Statements with leading
	// comments also break, so the comments don't get smushed inline.
	if (d.statements.length === 1 && d.statements[0].comments.length === 0) {
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

	const parts: Doc[] = [docText(kind + " " + d.declName)];
	if (d.declType !== "") {
		parts.push(docText(": " + d.declType));
	}
	if (d.initializer !== null) {
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
	if (d.argument !== null) {
		parts.push(docText(" "));
		parts.push(callPrintNode(d.argument, options));
	}
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printIfStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as IfStmtData;
	const parts: Doc[] = [
		docText("if ("),
		callPrintNode(d.condition, options),
		docText(") "),
		callPrintNode(d.consequent, options),
	];
	// Skip empty else blocks (parser may create a BlockStmt with 0 statements)
	if (d.alternate !== null) {
		let isEmpty = false;
		if (d.alternate.kind === NodeKind.BlockStmt) {
			const altData = d.alternate.data as BlockStmtData;
			if (altData.statements.length === 0) { isEmpty = true; }
		}
		if (!isEmpty) {
			parts.push(docText(" else "));
			parts.push(callPrintNode(d.alternate, options));
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
		callPrintNode(d.whileBody, options),
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
		callPrintNode(d.forBody, options),
	]);
}

export function printForOfStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ForOfStmtData;
	let binding = "let";
	if (d.forOfIsConst) { binding = "const"; }
	return docGroup([
		docText("for (" + binding + " " + d.forOfBinding + " of "),
		callPrintNode(d.forOfIterable, options),
		docText(") "),
		callPrintNode(d.forOfBody, options),
	]);
}

export function printForInStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as ForInStmtData;
	const binding = d.forInIsConst ? "const" : "let";
	return docGroup([
		docText("for (" + binding + " " + d.forInBinding + " in "),
		callPrintNode(d.forInObject, options),
		docText(") "),
		callPrintNode(d.forInBody, options),
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
	if (d.catchBody !== null) {
		parts.push(docText(" catch"));
		if (d.catchName !== "") {
			parts.push(docText(" (" + d.catchName + ")"));
		}
		parts.push(docText(" "));
		parts.push(callPrintNode(d.catchBody, options));
	}
	if (d.finallyBody !== null) {
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
	if (d.breakLabel !== "") return docText("break " + d.breakLabel + ";");
	return docText("break;");
}

export function printContinueStmt(node: Node): Doc {
	const d = node.data as { continueLabel: string };
	if (d.continueLabel !== "") return docText("continue " + d.continueLabel + ";");
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
export function buildParamList(names: string[], types: string[], defaults: Node[], options: FormatOptions): Doc[] {
	const out: Doc[] = [];
	for (let i = 0; i < names.length; i += 1) {
		let p = names[i];
		if (i < types.length && types[i] !== "") {
			p = p + ": " + types[i];
		}
		const def = i < defaults.length ? defaults[i] : null;
		if (def !== null) {
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
export function wrapGenerics(names: string): string {
	return names !== "" ? "<" + names + ">" : "";
}

// fnFlags format: pipe-separated tokens, e.g. "async|gen:T,U|ext:string".
// Returns true if `name` is present as a bare flag.
export function flagHas(flags: string, name: string): boolean {
	if (flags === name) return true;
	if (flags.length < name.length) return false;
	let i = 0;
	while (i < flags.length) {
		let j = i;
		while (j < flags.length && flags.charCodeAt(j) !== "|".code) j = j + 1;
		const tok = flags.slice(i, j);
		if (tok === name) return true;
		i = j + 1;
	}
	return false;
}

// Returns the suffix of the first `name:<value>` segment, or "".
export function flagGet(flags: string, name: string): string {
	let i = 0;
	while (i < flags.length) {
		let j = i;
		while (j < flags.length && flags.charCodeAt(j) !== "|".code) j = j + 1;
		const tok = flags.slice(i, j);
		if (tok.length > name.length + 1 && tok.slice(0, name.length) === name && tok.charCodeAt(name.length) === ":".code) {
			return tok.slice(name.length + 1, tok.length);
		}
		i = j + 1;
	}
	return "";
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
		+ "function" + (isGen ? "*" : "") + " "
		+ d.fnName + wrapGenerics(flagGet(d.fnFlags, "gen"));

	const parts: Doc[] = [docText(head)];
	const params = buildParamList(d.params, d.fnParamTypes, d.fnDefaults, options);
	for (const p of paramListInParens(params, options)) parts.push(p);

	if (d.fnReturnType !== "") {
		parts.push(docText(": " + d.fnReturnType));
	}

	// Extern functions have no body — emit `;` only.
	if (isExtern) {
		if (d.nativeName !== "") {
			parts.push(docText(" from \"" + d.nativeName + "\""));
		}
		parts.push(docText(";"));
		return docGroup(parts);
	}

	parts.push(docText(" "));
	parts.push(callPrintNode(d.fnBody, options));
	return docGroup(parts);
}
