// Statement Printers — blocks, declarations, loops, etc.

import {
	Node, NodeKind, DeclKind,
	ProgramData, BlockStmtData, VariableDeclData,
	ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData,
	ForStmtData, ForOfStmtData, DoWhileStmtData,
	SwitchStmtData, SwitchCaseData,
	MatchStmtData, ThrowStmtData, TryCatchStmtData, DeferStmtData,
	FunctionDeclData,
} from "../../../ast/node";
import { Token } from "../../../lexer/token";
import { FormatOptions } from "../options";
import {
	Doc, docText, docGroup, docIndent,
	docLine, docSoftLine, docHardLine, docJoin,
} from "../doc";
import { callPrintNode } from "./callbacks";

export function printProgram(node: Node, options: FormatOptions): Doc {
	const d = node.data as ProgramData;
	const parts: Doc[] = [];
	for (let i = 0; i < d.programStmts.length; i += 1) {
		const stmt = d.programStmts[i];

		// Extract inter-statement comments: comments on this statement whose line
		// is between this statement and the next. These are standalone comments
		// (e.g., `// comment` between `};` and `export default`).
		const interComments: Token[] = [];
		if (stmt.comments.length > 0) {
			const nextLine = (i + 1 < d.programStmts.length) ? d.programStmts[i + 1].location.line : 999999;
			const remaining: Token[] = [];
			for (const comment of stmt.comments) {
				if (comment.line > stmt.location.line && comment.line < nextLine) {
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

		// Emit inter-statement comments with surrounding blank lines
		for (const ic of interComments) {
			parts.push(docHardLine());
			parts.push(docHardLine());
			parts.push(docText(ic.value));
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

export function printFunctionDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as FunctionDeclData;
	const params: Doc[] = [];
	for (let i = 0; i < d.params.length; i += 1) {
		let p = d.params[i];
		if (d.fnParamTypes[i] !== "") {
			p = p + ": " + d.fnParamTypes[i];
		}
		params.push(docText(p));
	}

	let prefix = "function ";
	if (d.fnFlags === "async" || d.fnFlags === "async_generator") { prefix = "async function "; }
	const parts: Doc[] = [docText(prefix + d.fnName + "(")];
	parts.push(docGroup([
		docIndent([docSoftLine(), docJoin(params, docGroup([docText(","), docLine()]))]),
		docSoftLine(),
	]));
	parts.push(docText(")"));

	if (d.fnReturnType !== "") {
		parts.push(docText(": " + d.fnReturnType));
	}

	parts.push(docText(" "));
	parts.push(callPrintNode(d.fnBody, options));

	return docGroup(parts);
}
