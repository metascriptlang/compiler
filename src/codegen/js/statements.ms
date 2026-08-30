// JavaScript Codegen — Statement Emitters

import {
	Node, NodeKind, DeclKind, TypeKind,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	ExprStmtData, ReturnStmtData, BreakStmtData, ContinueStmtData,
	SwitchStmtData, SwitchCaseData, ThrowStmtData, TryCatchStmtData,
	ForStmtData, ForOfStmtData, MacroInvocationData, StringLiteralData,
	AssertStmtData, isEmptyBlock, Type,
} from "../../ast/node";
import { emit, emitNode, emitIndent, emitNewline, emitLine, JSGenerator, emitBlockInline, emitBlockOrStmt, jsTypedArrayName, escapeJSString } from "./emit";
import { safeJsName, jsSymbolName } from "./expressions";
import { emitCopyOnRead } from "./valueCopy";
import { hasFlag, SymbolFlag } from "../../checker/symbol";

// A failing assert must abandon the rest of its test body — the C harness does
// this with `goto` after setting msErr, so the JS side throws and lets the
// generated runner catch per test. Outside a test build there is no harness to
// report to, so the throw is the report.
export function emitAssertStmt(gen: JSGenerator, node: Node): void {
	const d = node.data as AssertStmtData;
	emitIndent(gen);
	emit(gen, "if (!(");
	emitNode(gen, d.assertExpr);
	emit(gen, ")) { ");
	if (gen.isTestBuild) {
		emit(gen, "__msAssertFail(");
		if (d.assertMessageExpr !== null) {
			emitNode(gen, d.assertMessageExpr);
		} else {
			const raw = d.assertMessage.length > 0 ? d.assertMessage : d.assertSource;
			emit(gen, `"${escapeJSString(raw)}"`);
		}
		emit(gen, `, "${escapeJSString(gen.currentModulePath)}", ${node.location.line.toString()});`);
	} else {
		emit(gen, "throw new Error(\"assert failed: ");
		const raw = d.assertMessage.length > 0 ? d.assertMessage : d.assertSource;
		emit(gen, `${escapeJSString(raw)}");`);
	}
	emit(gen, " }\n");
}

// Emit default initializer for uninitialized variable based on type.
// Reference: createVar — typed arrays for numeric, inline literal for small, arrayConstr for large.
function jsDefaultValue(t: Type): string {
	if (t === null) return "";
	if (t.kind === TypeKind.SizedArray) {
		const size = t.typeFlags;
		const elemType = t.typeReturn;
		let fill = "null";
		if (elemType !== null) {
			const typedName = jsTypedArrayName(elemType.kind);
			if (typedName !== "") return `new ${typedName}(${size})`;
			const elemInit = jsDefaultValue(elemType);
			if (elemInit !== "") fill = elemInit;
		}
		if (size > 32) return `new Array(${size}).fill(${fill})`;
		let out = "[";
		for (let i = 0; i < size; i += 1) {
			if (i > 0) out = out + ", ";
			out = out + fill;
		}
		return out + "]";
	}
	if (t.kind === TypeKind.Number || t.kind === TypeKind.Float32 || t.kind === TypeKind.Float64
		|| t.kind === TypeKind.Int8 || t.kind === TypeKind.Int16 || t.kind === TypeKind.Int32
		|| t.kind === TypeKind.Uint8 || t.kind === TypeKind.Uint16 || t.kind === TypeKind.Uint32) {
		return "0";
	}
	if (t.kind === TypeKind.Int64 || t.kind === TypeKind.Uint64) return "0n";
	if (t.kind === TypeKind.Boolean) return "false";
	if (t.kind === TypeKind.String) return "\"\"";
	return "";
}

function emitDefaultInit(gen: JSGenerator, t: Type): void {
	const v = jsDefaultValue(t);
	if (v !== "") emit(gen, " = " + v);
}

// ===== Variable Declaration =====

// Emit a variable declaration without trailing ;\n or indent.
// Used by emitVariableDecl (full statement) and emitForStmt (inline init).
function emitVariableDeclCore(gen: JSGenerator, node: Node): void {
	const d = node.data as VariableDeclData;
	match (d.declKind) {
		DeclKind.Const => { emit(gen, "const "); },
		DeclKind.Var => { emit(gen, "var "); },
		_ => { emit(gen, "let "); },
	};
	emit(gen, jsSymbolName(gen, node.resolvedSym, d.declName));
	if (d.initializer !== null) {
		emit(gen, " = ");
		emitCopyOnRead(gen, d.initializer);
	} else {
		emitDefaultInit(gen, node.nodeType!);
	}
}

// Storage hoisted to the module, initializer left where it was written — the
// same split the C backend makes. Reads already resolve to the module-scope name
// (jsSymbolName routes a global through mangledGlobalName), so only the
// placement and the run-once guard are emitted here.
function emitStaticStorageDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as VariableDeclData;
	const slot = jsSymbolName(gen, node.resolvedSym, d.declName);
	gen.staticSlots.push("let " + slot + ";\n");
	if (d.initializer === null) return;
	if (d.declKind !== DeclKind.Const) {
		emitIndent(gen);
		emit(gen, slot + " = ");
		emitCopyOnRead(gen, d.initializer);
		emit(gen, ";\n");
		return;
	}
	const guard = slot + "__once";
	gen.staticSlots.push("let " + guard + " = false;\n");
	emitIndent(gen);
	emit(gen, "if (!" + guard + ") { " + guard + " = true; " + slot + " = ");
	emitNode(gen, d.initializer);
	emit(gen, "; }\n");
}

export function emitVariableDecl(gen: JSGenerator, node: Node): void {
	if (node.resolvedSym !== null && hasFlag(node.resolvedSym, SymbolFlag.ComptimeNodeAlias)) return;
	if (node.resolvedSym !== null && hasFlag(node.resolvedSym, SymbolFlag.StaticLocal)) {
		emitStaticStorageDecl(gen, node);
		return;
	}
	emitIndent(gen);
	emitVariableDeclCore(gen, node);
	emit(gen, ";\n");
}

// ===== If Statement =====

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
	if (d.whileLabel !== "") {
		emit(gen, d.whileLabel);
		emit(gen, ": ");
	}
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
			for (const arg of mi.macroArgs) {
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
		emitCopyOnRead(gen, d.argument);
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
	for (const sc of d.switchCases) {
		emitSwitchCase(gen, sc);
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
		for (const test of d.caseTests) {
			emitIndent(gen);
			emit(gen, "  case ");
			emitNode(gen, test);
			emit(gen, ":\n");
		}
	}
	gen.indentLevel = gen.indentLevel + 2;
	for (const stmt of d.caseStmts) {
		emitNode(gen, stmt);
	}
	emitIndent(gen);
	emit(gen, "break;\n");
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
	if (d.hasCatchClause) {
		if (d.catchName !== "") {
			emit(gen, " catch (");
			emit(gen, safeJsName(d.catchName));
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
	if (d.forInit !== null && d.forInit.kind === NodeKind.VariableDecl) {
		emitVariableDeclCore(gen, d.forInit);
	} else if (d.forInit !== null && d.forInit.kind === NodeKind.ExprStmt) {
		// Unwrap ExprStmt to avoid trailing ;\n
		emitNode(gen, (d.forInit.data as ExprStmtData).expr);
	} else if (d.forInit !== null) {
		emitNode(gen, d.forInit);
	}
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
	emit(gen, safeJsName(d.forOfBinding));
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
