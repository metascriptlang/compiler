// JavaScript Codegen — Statement Emitters

import {
	Node, NodeKind, DeclKind,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	BlockStmtData, ExprStmtData, ReturnStmtData,
	BreakStmtData, ContinueStmtData,
	SwitchStmtData, SwitchCaseData,
	ThrowStmtData, TryCatchStmtData,
	ForStmtData, ForOfStmtData,
	UnreachableStmtData,
	MacroInvocationData, StringLiteralData,
} from "../../ast/node";
import { emit, emitNode, emitIndent, emitNewline, emitLine, JSGenerator, emitBlockInline, emitBlockOrStmt } from "./emit";

// ===== Variable Declaration =====

export function emitVariableDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as VariableDeclData;
	emitIndent(gen);
	if (d.declKind === DeclKind.Const) {
		emit(gen, "const ");
	} else if (d.declKind === DeclKind.Var) {
		emit(gen, "var ");
	} else {
		emit(gen, "let ");
	}
	emit(gen, d.declName);
	if (d.initializer !== null) {
		emit(gen, " = ");
		emitNode(gen, d.initializer);
	}
	emit(gen, ";\n");
}

// ===== If Statement =====

// Check if a node is an empty block (null or BlockStmt with no statements)
function isEmptyBlock(node: Node): boolean {
	if (node === null) return true;
	if (node.kind !== NodeKind.BlockStmt) return false;
	const d = node.data as BlockStmtData;
	return d.statements.length === 0;
}

function emitIfStmtInner(gen: JSGenerator, node: Node, withIndent: boolean): void {
	const d = node.data as IfStmtData;
	if (withIndent) emitIndent(gen);
	emit(gen, "if (");
	emitNode(gen, d.condition);
	emit(gen, ") ");
	emitBlockOrStmt(gen, d.consequent);
	if (!isEmptyBlock(d.alternate)) {
		emit(gen, " else ");
		if (d.alternate.kind === NodeKind.IfStmt) {
			emitIfStmtInner(gen, d.alternate, false);
		} else {
			emitBlockOrStmt(gen, d.alternate);
			emitNewline(gen);
		}
	} else {
		emitNewline(gen);
	}
}

export function emitIfStmt(gen: JSGenerator, node: Node): void {
	emitIfStmtInner(gen, node, true);
}

// ===== While Statement =====

export function emitWhileStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as WhileStmtData;
	emitIndent(gen);
	emit(gen, "while (");
	emitNode(gen, d.whileCondition);
	emit(gen, ") ");
	emitBlockOrStmt(gen, d.whileBody);
	emitNewline(gen);
}

// ===== Do-While Statement =====

export function emitDoWhileStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as DoWhileStmtData;
	emitIndent(gen);
	emit(gen, "do ");
	emitBlockOrStmt(gen, d.doBody);
	emit(gen, " while (");
	emitNode(gen, d.doCondition);
	emit(gen, ");\n");
}

// ===== Block Statement =====

export function emitBlockStmt(gen: JSGenerator, node: Node): void {
	emitIndent(gen);
	emitBlockInline(gen, node);
	emitNewline(gen);
}

// ===== Expression Statement =====

export function emitExprStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as ExprStmtData;
	// @emit: raw JS injection (reference emit generation parity)
	if (d.expr.kind === NodeKind.MacroInvocation) {
		const mi = d.expr.data as MacroInvocationData;
		if (mi.macroName === "emit" && mi.macroArgs.length > 0) {
			emitIndent(gen);
			for (let i = 0; i < mi.macroArgs.length; i += 1) {
				const arg = mi.macroArgs[i];
				if (arg.kind === NodeKind.StringLiteral) {
					emit(gen, (arg.data as StringLiteralData).value);
				} else {
					// reference parity: gen(p, it, r) for symbols and expressions
					emitNode(gen, arg);
				}
			}
			emit(gen, "\n");
		}
		return;
	}
	emitIndent(gen);
	emitNode(gen, d.expr);
	emit(gen, ";\n");
}

// ===== Return Statement =====

export function emitReturnStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as ReturnStmtData;
	emitIndent(gen);
	if (d.argument !== null) {
		emit(gen, "return ");
		emitNode(gen, d.argument);
		emit(gen, ";\n");
	} else {
		emit(gen, "return;\n");
	}
}

// ===== Break Statement =====

export function emitBreakStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as BreakStmtData;
	emitIndent(gen);
	if (d.breakLabel !== "") {
		emit(gen, "break ");
		emit(gen, d.breakLabel);
		emit(gen, ";\n");
	} else {
		emit(gen, "break;\n");
	}
}

// ===== Continue Statement =====

export function emitContinueStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as ContinueStmtData;
	emitIndent(gen);
	if (d.continueLabel !== "") {
		emit(gen, "continue ");
		emit(gen, d.continueLabel);
		emit(gen, ";\n");
	} else {
		emit(gen, "continue;\n");
	}
}

// ===== Switch Statement =====

export function emitSwitchStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as SwitchStmtData;
	emitIndent(gen);
	emit(gen, "switch (");
	emitNode(gen, d.switchDisc);
	emit(gen, ") {\n");
	for (let i = 0; i < d.switchCases.length; i += 1) {
		emitSwitchCase(gen, d.switchCases[i]);
	}
	emitIndent(gen);
	emit(gen, "}\n");
}

export function emitSwitchCase(gen: JSGenerator, node: Node): void {
	const d = node.data as SwitchCaseData;
	if (d.isDefault) {
		emitIndent(gen);
		emit(gen, "  default:\n");
	} else {
		for (let ti = 0; ti < d.caseTests.length; ti += 1) {
			emitIndent(gen);
			emit(gen, "  case ");
			emitNode(gen, d.caseTests[ti]);
			emit(gen, ":\n");
		}
	}
	gen.indentLevel = gen.indentLevel + 2;
	for (let si = 0; si < d.caseStmts.length; si += 1) {
		emitNode(gen, d.caseStmts[si]);
	}
	gen.indentLevel = gen.indentLevel - 2;
}

// ===== Throw Statement =====

export function emitThrowStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as ThrowStmtData;
	emitIndent(gen);
	emit(gen, "throw ");
	emitNode(gen, d.throwArg);
	emit(gen, ";\n");
}

// ===== Try-Catch Statement =====

export function emitTryCatchStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as TryCatchStmtData;
	emitIndent(gen);
	emit(gen, "try ");
	emitBlockOrStmt(gen, d.tryBody);
	if (d.catchBody !== null) {
		if (d.catchName !== "") {
			emit(gen, " catch (");
			emit(gen, d.catchName);
			emit(gen, ") ");
		} else {
			emit(gen, " catch ");
		}
		emitBlockOrStmt(gen, d.catchBody);
	}
	if (d.finallyBody !== null) {
		emit(gen, " finally ");
		emitBlockOrStmt(gen, d.finallyBody);
	}
	emitNewline(gen);
}

// ===== For Statement (fallback if not lowered) =====

export function emitForStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as ForStmtData;
	emitIndent(gen);
	emit(gen, "for (");
	if (d.forInit !== null) emitNode(gen, d.forInit);
	emit(gen, "; ");
	if (d.forCondition !== null) emitNode(gen, d.forCondition);
	emit(gen, "; ");
	if (d.forUpdate !== null) emitNode(gen, d.forUpdate);
	emit(gen, ") ");
	emitBlockOrStmt(gen, d.forBody);
	emitNewline(gen);
}

// ===== For-Of Statement (fallback if not lowered) =====

export function emitForOfStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as ForOfStmtData;
	emitIndent(gen);
	if (d.forOfIsConst) {
		emit(gen, "for (const ");
	} else {
		emit(gen, "for (let ");
	}
	emit(gen, d.forOfBinding);
	emit(gen, " of ");
	emitNode(gen, d.forOfIterable);
	emit(gen, ") ");
	emitBlockOrStmt(gen, d.forOfBody);
	emitNewline(gen);
}

// ===== Unreachable Statement =====

export function emitUnreachableStmt(gen: JSGenerator, node: Node): void {
	emitLine(gen, "throw new Error(\"unreachable\");");
}
