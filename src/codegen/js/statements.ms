// JavaScript Codegen — Statement Emitters

import {
	Node, NodeKind, DeclKind, TypeKind,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	ExprStmtData, ReturnStmtData, BreakStmtData, ContinueStmtData,
	SwitchStmtData, SwitchCaseData, ThrowStmtData, TryCatchStmtData,
	ForStmtData, ForOfStmtData, MacroInvocationData, StringLiteralData,
	isEmptyBlock, Type,
} from "../../ast/node";
import { emit, emitNode, emitIndent, emitNewline, emitLine, JSGenerator, emitBlockInline, emitBlockOrStmt } from "./emit";
import { safeJsName, jsSymbolName } from "./expressions";
import { hasFlag, SymbolFlag } from "../../checker/symbol";

// ===== Typed Array Mapping (reference: arrayTypeForElemType) =====

function jsTypedArrayName(elemKind: TypeKind): string {
	return match (elemKind) {
		TypeKind.Int8 => "Int8Array",
		TypeKind.Int16 => "Int16Array",
		TypeKind.Int32 => "Int32Array",
		TypeKind.Int64 => "BigInt64Array",
		TypeKind.Uint8 | TypeKind.Char | TypeKind.Boolean => "Uint8Array",
		TypeKind.Uint16 => "Uint16Array",
		TypeKind.Uint32 => "Uint32Array",
		TypeKind.Uint64 => "BigUint64Array",
		TypeKind.Float32 => "Float32Array",
		TypeKind.Float64 | TypeKind.Number => "Float64Array",
		_ => "",
	};
}

// Emit default initializer for uninitialized variable based on type.
// Reference: createVar — typed arrays for numeric, inline literal for small, arrayConstr for large.
function emitDefaultInit(gen: JSGenerator, t: Type): void {
	if (t === null) return;
	if (t.kind === TypeKind.SizedArray) {
		const size = t.typeFlags;
		const elemType = t.typeReturn;
		if (elemType !== null) {
			const typedName = jsTypedArrayName(elemType.kind);
			if (typedName !== "") {
				emit(gen, ` = new ${typedName}(${size})`);
				return;
			}
		}
		// Non-numeric element type: use Array(n).fill(null)
		if (size <= 32) {
			emit(gen, " = [");
			for (let i = 0; i < size; i += 1) {
				if (i > 0) emit(gen, ", ");
				emit(gen, "null");
			}
			emit(gen, "]");
		} else {
			emit(gen, ` = new Array(${size}).fill(null)`);
		}
		return;
	}
	if (t.kind === TypeKind.Number || t.kind === TypeKind.Float32 || t.kind === TypeKind.Float64
		|| t.kind === TypeKind.Int8 || t.kind === TypeKind.Int16 || t.kind === TypeKind.Int32
		|| t.kind === TypeKind.Uint8 || t.kind === TypeKind.Uint16 || t.kind === TypeKind.Uint32) {
		emit(gen, " = 0");
		return;
	}
	if (t.kind === TypeKind.Int64 || t.kind === TypeKind.Uint64) {
		emit(gen, " = 0n");
		return;
	}
	if (t.kind === TypeKind.Boolean) {
		emit(gen, " = false");
		return;
	}
	if (t.kind === TypeKind.String) {
		if (gen.bundleMode) {
			emit(gen, " = []");  // byte array (reference parity)
		} else {
			emit(gen, " = \"\"");
		}
		return;
	}
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
	emit(gen, jsSymbolName(node.resolvedSym, d.declName));
	if (d.initializer !== null) {
		emit(gen, " = ");
		emitNode(gen, d.initializer);
	} else {
		emitDefaultInit(gen, node.nodeType);
	}
}

export function emitVariableDecl(gen: JSGenerator, node: Node): void {
	if (node.resolvedSym !== null && hasFlag(node.resolvedSym, SymbolFlag.ComptimeNodeAlias)) return;
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
