// Raiser codegen — Expression compilation
// AST expression nodes → typed bytecode instructions.

import {
	Node, NodeKind, NodeFlag, TypeKind, SymbolKind,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	BinaryExprData, UnaryExprData,
	CallExprData, IdentifierData, MemberExprData,
	ConditionalExprData, TypeAssertionData, UpdateExprData,
	ArrayLiteralData, ArrayAccessData, ObjectLiteralData,
	MoveExprData,
	HiddenDerefData, HiddenStdConvData
} from "../../ast/node";
import { RaiserOpcode, raiserABC } from "../../raiser/bytecode";
import { raiserInt, raiserFloat, raiserNil, raiserBool, raiserString } from "../../raiser/value";
import {
	RaiserCompState, emitInst, allocReg, addConst, emitLoadConst, resolveLocal,
	resolveFunc, isLocalString, isEnumName, findEnumConstant,
	emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, codeLen,
	markRegFloat, isRegFloat, callRaiserOnDemand, queueRaiserCompileError
} from "./context";

// --- Float detection ---
// Check if a number has a fractional part by examining its string representation.
// "3.14" contains "." → float, "2" does not → int, "2.0" → "2" (no dot) → int (correct: same value)

function numberIsFloat(v: number): boolean {
	const s = "" + v;
	for (let i = 0; i < s.length; i = i + 1) {
		if (s.slice(i, i + 1) === ".") return true;
	}
	return false;
}

// --- Operator → Opcode mapping ---

function arithmeticOpcode(op: string): RaiserOpcode {
	return match (op) {
		"+" => RaiserOpcode.AddI64,
		"-" => RaiserOpcode.SubI64,
		"*" => RaiserOpcode.MulI64,
		"/" => RaiserOpcode.DivI64,
		"%" => RaiserOpcode.ModI64,
		_ => RaiserOpcode.AddI64,
	};
}

function arithmeticOpcodeF64(op: string): RaiserOpcode {
	return match (op) {
		"+" => RaiserOpcode.AddF64,
		"-" => RaiserOpcode.SubF64,
		"*" => RaiserOpcode.MulF64,
		"/" => RaiserOpcode.DivF64,
		"%" => RaiserOpcode.ModI64,
		_ => RaiserOpcode.AddF64,
	};
}

function comparisonOpcodeF64(op: string): RaiserOpcode {
	return match (op) {
		"==" | "===" => RaiserOpcode.BeqF64,
		"!=" | "!==" => RaiserOpcode.BneF64,
		"<" => RaiserOpcode.BltF64,
		"<=" => RaiserOpcode.BleF64,
		">" => RaiserOpcode.BgtF64,
		">=" => RaiserOpcode.BgeF64,
		_ => RaiserOpcode.BeqF64,
	};
}

function comparisonOpcode(op: string): RaiserOpcode {
	return match (op) {
		"==" | "===" => RaiserOpcode.BeqI64,
		"!=" | "!==" => RaiserOpcode.BneI64,
		"<" => RaiserOpcode.BltI64,
		"<=" => RaiserOpcode.BleI64,
		">" => RaiserOpcode.BgtI64,
		">=" => RaiserOpcode.BgeI64,
		_ => RaiserOpcode.BeqI64,
	};
}

function isComparisonOp(op: string): boolean {
	return match (op) {
		"==" | "===" | "!=" | "!==" | "<" | "<=" | ">" | ">=" => true,
		_ => false,
	};
}

function isArithmeticOp(op: string): boolean {
	return match (op) {
		"+" | "-" | "*" | "/" | "%" => true,
		_ => false,
	};
}

function isLogicalOp(op: string): boolean {
	return match (op) {
		"&&" | "||" => true,
		_ => false,
	};
}

function isBitwiseOp(op: string): boolean {
	return match (op) {
		"&" | "|" | "^" | "<<" | ">>" => true,
		_ => false,
	};
}

function bitwiseOpcode(op: string): RaiserOpcode {
	return match (op) {
		"&" => RaiserOpcode.BitAnd,
		"|" => RaiserOpcode.BitOr,
		"^" => RaiserOpcode.BitXor,
		"<<" => RaiserOpcode.ShiftLeft,
		">>" => RaiserOpcode.ShiftRight,
		_ => RaiserOpcode.BitAnd,
	};
}

function isCompoundAssignOp(op: string): boolean {
	return match (op) {
		"+=" | "-=" | "*=" | "/=" | "%=" => true,
		_ => false,
	};
}

function compoundBaseOpcode(op: string): RaiserOpcode {
	return match (op) {
		"+=" => RaiserOpcode.AddI64,
		"-=" => RaiserOpcode.SubI64,
		"*=" => RaiserOpcode.MulI64,
		"/=" => RaiserOpcode.DivI64,
		"%=" => RaiserOpcode.ModI64,
		_ => RaiserOpcode.AddI64,
	};
}

// --- String type inference (checker-resolved type first, AST as fallback) ---

export function exprIsString(s: RaiserCompState, node: Node): boolean {
	// Nim's vmgen dispatches string-vs-seq on the operand's SEMANTIC type
	// (`n[1].typ.skipTypes(...)`, vmgen.nim:1122) — never on a syntactic guess.
	// The checker-resolved type is therefore the authority here; the AST arms
	// below only cover nodes the Raiser's mini-pipeline left untyped. Asking the
	// AST first made a string-typed PARAMETER (an Identifier that `isLocalString`
	// cannot know) answer false, so `s.length` emitted ArrayLen against a string
	// handle and `s.charAt` missed its fast path entirely.
	if (node.nodeType !== null) {
		const tk = node.nodeType.kind;
		if (tk === TypeKind.String || tk === TypeKind.StringLiteral) return true;
	}
	const k = node.kind;
	if (k === NodeKind.StringLiteral) return true;
	if (k === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		return isLocalString(s, d.name);
	}
	if (k === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator === "+") {
			return exprIsString(s, d.left) || exprIsString(s, d.right);
		}
		return false;
	}
	if (k === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		return exprIsString(s, d.ternaryConsequent) || exprIsString(s, d.ternaryAlternate);
	}
	return false;
}

// --- Expression compilation ---
// Returns the register holding the result.

export function compileExpr(s: RaiserCompState, node: Node): int32 {
	return match (node.kind) {
		NodeKind.NumberLiteral => {
			const d = node.data as NumberLiteralData;
			const reg = allocReg(s);
			if (numberIsFloat(d.value)) {
				emitLoadConst(s, reg, raiserFloat(d.value));
				markRegFloat(s, reg);
			} else {
				emitLoadConst(s, reg, raiserInt(d.value));
			}
			return reg;
		},
		NodeKind.StringLiteral => {
			const d = node.data as StringLiteralData;
			const reg = allocReg(s);
			emitLoadConst(s, reg, raiserString(d.value));
			return reg;
		},
		NodeKind.BooleanLiteral => {
			const d = node.data as BooleanLiteralData;
			const reg = allocReg(s);
			emitLoadConst(s, reg, raiserBool(d.boolValue));
			return reg;
		},
		NodeKind.NullLiteral => {
			const reg = allocReg(s);
			emitLoadConst(s, reg, raiserNil());
			return reg;
		},
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			const reg = resolveLocal(s, d.name);
			if (reg >= 0) return reg;
			// The checker rewrites `Enum.Member` into an Identifier "Enum_Member".
			// Raiser emits no enum declaration, so that name has no binding —
			// inline the ordinal from the enum table. Key by the symbol's enum name
			// + member (not the mangled identifier) so it can't collide.
			if (node.resolvedSym !== null && node.resolvedSym.symbolKind === SymbolKind.EnumMember
				&& node.resolvedSym.symbolType !== null) {
				// Self-contained ordinal (primary): the member's EnumLiteral carries
				// the full enum Type on typeReturn (createEnumLiteral), whose
				// typeChildren[i].typeFlags hold the ordinals (createEnum). Reading
				// it here means the ordinal no longer depends on the EnumDecl being
				// physically injected into the comptime synthetic program — fixes
				// single-file/local enums the same way as cross-module ones.
				const enumTy = node.resolvedSym.symbolType.typeReturn;
				if (enumTy !== null) {
					let ei = 0;
					while (ei < enumTy.typeNames.length) {
						if (enumTy.typeNames[ei] === node.resolvedSym.name) {
							const ord = (enumTy.typeChildren !== null && ei < enumTy.typeChildren.length)
								? enumTy.typeChildren[ei].typeFlags : ei;
							const r0 = allocReg(s);
							emitLoadConst(s, r0, raiserInt(ord));
							return r0;
						}
						ei = ei + 1;
					}
				}
				// Fallback: physically-injected EnumDecl → enumMap (legacy path).
				const ec = findEnumConstant(s, `${node.resolvedSym.symbolType.typeName}.${node.resolvedSym.name}`);
				if (ec >= 0) {
					const r = allocReg(s);
					emitLoadConst(s, r, raiserInt(s.enumMap.items[ec].index));
					return r;
				}
			}
			const funcIdx = resolveFunc(s, d.name);
			if (funcIdx >= 0) {
				const r = allocReg(s);
				emitLoadConst(s, r, raiserInt(funcIdx));
				return r;
			}
			// Nothing the bytecode compiler can execute bound this name (module-
			// level consts and other non-routine symbols land here). Report it
			// instead of silently splicing nil into the macro's output.
			queueRaiserCompileError(
				`cannot evaluate '${d.name}' at comptime: no local, function, enum constant, or builtin binding reached the bytecode compiler`,
				node.location.line, node.location.column);
			const fallback = allocReg(s);
			emitLoadConst(s, fallback, raiserNil());
			return fallback;
		},
		NodeKind.BinaryExpr => { return compileBinaryExpr(s, node); },
		NodeKind.UnaryExpr => { return compileUnaryExpr(s, node); },
		NodeKind.CallExpr => { return compileCallExpr(s, node); },
		NodeKind.ConditionalExpr => { return compileConditionalExpr(s, node); },
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			return compileExpr(s, d.asExpr);
		},
		NodeKind.UpdateExpr => { return compileUpdateExpr(s, node); },
		NodeKind.ArrayLiteral => { return compileArrayLiteral(s, node); },
		NodeKind.ArrayAccess => { return compileArrayAccess(s, node); },
		NodeKind.MemberExpr => { return compileMemberExpr(s, node); },
		NodeKind.ObjectLiteral => { return compileObjectLiteral(s, node); },
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			return compileExpr(s, d.moveArg);
		},
		// Hidden* nodes are checker-inserted markers (deref point for Ref<Struct>,
		// implicit type conversion). Raiser VM is dynamically typed and has no
		// pointer-vs-value distinction — passthrough compile the inner expr.
		// Mirrors C backend (expressions.ms:852,860,868) and JS backend
		// (jsgen.ms:81-82). Without these arms the chain `o.inner.msg` on a
		// Ref<Struct> field silently fell through to LoadConst nil, breaking
		// every @comptime access on cross-module Ref<Struct> types.
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const hd = node.data as HiddenDerefData;
			return compileExpr(s, hd.expr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const hd = node.data as HiddenStdConvData;
			return compileExpr(s, hd.convExpr);
		},
		_ => {
			// Unsupported node kind: report instead of silently splicing nil.
			queueRaiserCompileError(
				`cannot compile node kind ${node.kind} at comptime: unsupported by the Raiser bytecode compiler`,
				node.location.line, node.location.column);
			const reg = allocReg(s);
			emitLoadConst(s, reg, raiserNil());
			return reg;
		},
	};
}

// --- Binary ---

function compileBinaryExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as BinaryExprData;
	const op = d.operator;

	// Assignment: x = expr  or  arr[i] = expr
	if (op === "=") {
		const srcReg = compileExpr(s, d.right);
		if (d.left.kind === NodeKind.Identifier) {
			const id = d.left.data as IdentifierData;
			const targetReg = resolveLocal(s, id.name);
			if (targetReg >= 0) {
				emitInst(s, raiserABC(RaiserOpcode.Move, targetReg, srcReg, 0));
				return targetReg;
			}
		}
		if (d.left.kind === NodeKind.ArrayAccess) {
			const ad = d.left.data as ArrayAccessData;
			const arrReg = compileExpr(s, ad.array);
			const idxReg = compileExpr(s, ad.index);
			emitInst(s, raiserABC(RaiserOpcode.StoreIndex, arrReg, idxReg, srcReg));
			return srcReg;
		}
		if (d.left.kind === NodeKind.MemberExpr) {
			const md = d.left.data as MemberExprData;
			const objReg = compileExpr(s, md.object);
			const nameIdx = addConst(s, raiserString(md.property));
			emitInst(s, raiserABC(RaiserOpcode.StoreField, objReg, nameIdx, srcReg));
			return srcReg;
		}
		return srcReg;
	}

	// Compound assignment: x += expr → x = x + expr
	if (isCompoundAssignOp(op)) {
		return compileCompoundAssign(s, node);
	}

	// Logical operators: short-circuit evaluation
	if (isLogicalOp(op)) {
		return compileLogicalExpr(s, node);
	}

	// String concat: "+" where either operand is a string
	if (op === "+" && (exprIsString(s, d.left) || exprIsString(s, d.right))) {
		const lReg = compileExpr(s, d.left);
		const rReg = compileExpr(s, d.right);
		const dest = allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.ConcatStr, dest, lReg, rReg));
		return dest;
	}

	// Null comparison: `expr === null` / `expr !== null` (and `==`/`!=`).
	// BeqI64/BneI64 only compare intVal — Array(handle=0) shares intVal=0 with
	// nil and would compare equal under the generic path. Mirror Nim's opcIsNil
	// and HashLink's OJNotNull: emit a kind-aware check via the dedicated
	// IsNil opcode whenever one side is a NullLiteral.
	const isEqOp = op === "===" || op === "==" || op === "!==" || op === "!=";
	const hasNullLit = d.left.kind === NodeKind.NullLiteral || d.right.kind === NodeKind.NullLiteral;
	if (isEqOp && hasNullLit) {
		const otherSide: Node = d.left.kind === NodeKind.NullLiteral ? d.right : d.left;
		const valReg = compileExpr(s, otherSide);
		const dest = allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.IsNil, dest, valReg, 0));
		if (op === "===" || op === "==") return dest;
		// `!== null` → bool XOR 1 negates without a separate Not opcode.
		const oneReg = allocReg(s);
		emitLoadConst(s, oneReg, raiserInt(1));
		emitInst(s, raiserABC(RaiserOpcode.BitXor, dest, dest, oneReg));
		return dest;
	}

	// String comparison: == / != / === / !== where either operand is a string
	const isStrCmp = isComparisonOp(op) && (exprIsString(s, d.left) || exprIsString(s, d.right));
	if (isStrCmp && (op === "==" || op === "===")) {
		const lReg = compileExpr(s, d.left);
		const rReg = compileExpr(s, d.right);
		const dest = allocReg(s);
		emitLoadConst(s, dest, raiserBool(true));
		emitInst(s, raiserABC(RaiserOpcode.EqStr, lReg, rReg, 1));
		emitLoadConst(s, dest, raiserBool(false));
		return dest;
	}
	if (isStrCmp && (op === "!=" || op === "!==")) {
		const lReg = compileExpr(s, d.left);
		const rReg = compileExpr(s, d.right);
		const dest = allocReg(s);
		emitLoadConst(s, dest, raiserBool(true));
		emitInst(s, raiserABC(RaiserOpcode.NeStr, lReg, rReg, 1));
		emitLoadConst(s, dest, raiserBool(false));
		return dest;
	}
	// Ordering. Nim has magics for `<` and `<=` only and derives `>`/`>=` by
	// swapping operands (lib/system/comparisons.nim); same here, so two opcodes
	// cover four operators. Falling through to the numeric tail instead — which
	// is what happened before these arms existed — compares string HANDLES.
	if (isStrCmp && (op === "<" || op === "<=" || op === ">" || op === ">=")) {
		const lReg = compileExpr(s, d.left);
		const rReg = compileExpr(s, d.right);
		const swapped = op === ">" || op === ">=";
		const aReg = swapped ? rReg : lReg;
		const bReg = swapped ? lReg : rReg;
		const strict = op === "<" || op === ">";
		const dest = allocReg(s);
		emitLoadConst(s, dest, raiserBool(true));
		emitInst(s, raiserABC(strict ? RaiserOpcode.LtStr : RaiserOpcode.LeStr, aReg, bReg, 1));
		emitLoadConst(s, dest, raiserBool(false));
		return dest;
	}

	const lReg = compileExpr(s, d.left);
	const rReg = compileExpr(s, d.right);
	const dest = allocReg(s);
	const useFloat = isRegFloat(s, lReg) || isRegFloat(s, rReg);

	// Bitwise operators
	if (isBitwiseOp(op)) {
		emitInst(s, raiserABC(bitwiseOpcode(op), dest, lReg, rReg));
		return dest;
	}

	// Comparison: R_result = true; BxxI64/BxxF64 L R 1; R_result = false
	if (isComparisonOp(op)) {
		emitLoadConst(s, dest, raiserBool(true));
		if (useFloat) {
			emitInst(s, raiserABC(comparisonOpcodeF64(op), lReg, rReg, 1));
		} else {
			emitInst(s, raiserABC(comparisonOpcode(op), lReg, rReg, 1));
		}
		emitLoadConst(s, dest, raiserBool(false));
		return dest;
	}

	// Arithmetic
	if (isArithmeticOp(op)) {
		if (useFloat) {
			emitInst(s, raiserABC(arithmeticOpcodeF64(op), dest, lReg, rReg));
			markRegFloat(s, dest);
		} else {
			emitInst(s, raiserABC(arithmeticOpcode(op), dest, lReg, rReg));
		}
		return dest;
	}

	emitLoadConst(s, dest, raiserInt(0));
	return dest;
}

// --- Unary ---

function compileUnaryExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as UnaryExprData;
	const srcReg = compileExpr(s, d.operand);
	const dest = allocReg(s);

	if (d.unaryOp === "-") {
		if (isRegFloat(s, srcReg)) {
			emitInst(s, raiserABC(RaiserOpcode.NegF64, dest, srcReg, 0));
			markRegFloat(s, dest);
		} else {
			emitInst(s, raiserABC(RaiserOpcode.NegI64, dest, srcReg, 0));
		}
	} else if (d.unaryOp === "~") {
		emitInst(s, raiserABC(RaiserOpcode.BitNot, dest, srcReg, 0));
	} else if (d.unaryOp === "!") {
		// Logical NOT: result = (src == 0) ? true : false
		const zeroReg = allocReg(s);
		emitLoadConst(s, zeroReg, raiserInt(0));
		emitLoadConst(s, dest, raiserBool(true));
		emitInst(s, raiserABC(RaiserOpcode.BeqI64, srcReg, zeroReg, 1));
		emitLoadConst(s, dest, raiserBool(false));
	} else {
		emitInst(s, raiserABC(RaiserOpcode.Move, dest, srcReg, 0));
	}
	return dest;
}

// --- Logical (short-circuit) ---

function compileLogicalExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as BinaryExprData;
	const dest = allocReg(s);

	// Compile left operand
	const lReg = compileExpr(s, d.left);
	emitInst(s, raiserABC(RaiserOpcode.Move, dest, lReg, 0));

	if (d.operator === "&&") {
		// a && b: if a is falsy, skip b (result = a)
		const jumpPastB = emitBranchIfFalsy(s, dest);
		const rReg = compileExpr(s, d.right);
		emitInst(s, raiserABC(RaiserOpcode.Move, dest, rReg, 0));
		patchJumpTo(s, jumpPastB, codeLen(s));
	} else {
		// a || b: if a is falsy, evaluate b. If truthy, skip b.
		const jumpToB = emitBranchIfFalsy(s, dest);
		const jumpPastB = emitJumpPlaceholder(s);
		patchJumpTo(s, jumpToB, codeLen(s));
		const rReg = compileExpr(s, d.right);
		emitInst(s, raiserABC(RaiserOpcode.Move, dest, rReg, 0));
		patchJumpTo(s, jumpPastB, codeLen(s));
	}

	return dest;
}

// --- Compound assignment (+=, -=, *=, /=, %=) ---

function compileCompoundAssign(s: RaiserCompState, node: Node): number {
	const d = node.data as BinaryExprData;
	const op = d.operator;

	if (d.left.kind === NodeKind.Identifier) {
		const id = d.left.data as IdentifierData;
		const targetReg = resolveLocal(s, id.name);
		if (targetReg >= 0) {
			const rhsReg = compileExpr(s, d.right);
			// String concat: += on string variable
			if (op === "+=" && (exprIsString(s, d.left) || exprIsString(s, d.right))) {
				emitInst(s, raiserABC(RaiserOpcode.ConcatStr, targetReg, targetReg, rhsReg));
			} else {
				emitInst(s, raiserABC(compoundBaseOpcode(op), targetReg, targetReg, rhsReg));
			}
			return targetReg;
		}
	}

	// Compound assign on member: obj.field += val → LoadField + op + StoreField
	if (d.left.kind === NodeKind.MemberExpr) {
		const md = d.left.data as MemberExprData;
		const objReg = compileExpr(s, md.object);
		const nameIdx = addConst(s, raiserString(md.property));
		const tmpReg = allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.LoadField, tmpReg, objReg, nameIdx));
		const rhsReg = compileExpr(s, d.right);
		if (op === "+=" && (exprIsString(s, d.left) || exprIsString(s, d.right))) {
			emitInst(s, raiserABC(RaiserOpcode.ConcatStr, tmpReg, tmpReg, rhsReg));
		} else {
			emitInst(s, raiserABC(compoundBaseOpcode(op), tmpReg, tmpReg, rhsReg));
		}
		emitInst(s, raiserABC(RaiserOpcode.StoreField, objReg, nameIdx, tmpReg));
		return tmpReg;
	}

	// Compound assign on array: arr[i] += val → LoadIndex + op + StoreIndex
	if (d.left.kind === NodeKind.ArrayAccess) {
		const ad = d.left.data as ArrayAccessData;
		const arrReg = compileExpr(s, ad.array);
		const idxReg = compileExpr(s, ad.index);
		const tmpReg = allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.LoadIndex, tmpReg, arrReg, idxReg));
		const rhsReg = compileExpr(s, d.right);
		emitInst(s, raiserABC(compoundBaseOpcode(op), tmpReg, tmpReg, rhsReg));
		emitInst(s, raiserABC(RaiserOpcode.StoreIndex, arrReg, idxReg, tmpReg));
		return tmpReg;
	}

	// Fallback: unsupported compound assign target
	const reg = allocReg(s);
	emitLoadConst(s, reg, raiserNil());
	return reg;
}

// --- Call ---

// Allocate `args.length` slots after `dest`, compile each arg, and emit Move
// instructions to land each result in its expected callee slot. Shared by
// CallHost (extern) and direct user-function-call paths since both follow
// the same calling convention (args sit at dest+1 .. dest+argCount).
function emitCallArgs(s: RaiserCompState, dest: number, args: Node[]): void {
	const argCount = args.length;
	for (let i = 0; i < argCount; i = i + 1) { allocReg(s); }
	for (let i = 0; i < argCount; i = i + 1) {
		const argReg = compileExpr(s, args[i]);
		const targetReg = dest + 1 + i;
		if (argReg !== targetReg) {
			emitInst(s, raiserABC(RaiserOpcode.Move, targetReg, argReg, 0));
		}
	}
}

function compileCallExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as CallExprData;

	// arr.push(val)
	if (isArrayPush(d.callee)) {
		return compileArrayPushCall(s, node);
	}

	// x.toString()
	if (isToStringCall(d.callee) && d.arguments.length === 0) {
		return compileToStringCall(s, node);
	}

	// str.charAt(i)
	if (isStringMethod(s, d.callee, "charAt") && d.arguments.length === 1) {
		return compileStrCharAt(s, node);
	}

	// str.slice(start, end)
	if (isStringMethod(s, d.callee, "slice") && d.arguments.length === 2) {
		return compileStrSlice(s, node);
	}

	if (isConsoleLog(d.callee)) {
		if (d.arguments.length <= 1) {
			let lastReg = 0;
			for (let i = 0; i < d.arguments.length; i = i + 1) {
				lastReg = compileExpr(s, d.arguments[i]);
				emitInst(s, raiserABC(RaiserOpcode.Print, lastReg, 0, 0));
			}
			return lastReg;
		}
		// Multi-arg: coerce each (ConcatStr with "") and space-join into one line (C/JS parity).
		const spaceReg = allocReg(s);
		emitLoadConst(s, spaceReg, raiserString(" "));
		const emptyReg = allocReg(s);
		emitLoadConst(s, emptyReg, raiserString(""));
		const acc = allocReg(s);
		const firstReg = compileExpr(s, d.arguments[0]);
		emitInst(s, raiserABC(RaiserOpcode.ConcatStr, acc, firstReg, emptyReg));
		for (let i = 1; i < d.arguments.length; i = i + 1) {
			emitInst(s, raiserABC(RaiserOpcode.ConcatStr, acc, acc, spaceReg));
			const argReg = compileExpr(s, d.arguments[i]);
			emitInst(s, raiserABC(RaiserOpcode.ConcatStr, acc, acc, argReg));
		}
		emitInst(s, raiserABC(RaiserOpcode.Print, acc, 0, 0));
		return acc;
	}

	// Generic native call: any callee resolved to a Symbol with nativeName
	// (extern decl) becomes a CallHost lookup at the registered name. New
	// stdlib externs need zero codegen edits — they self-register through
	// hostTable.ms which feeds the registry consulted at dispatch time.
	if (d.callee.kind === NodeKind.Identifier && d.callee.resolvedSym !== null) {
		const sym = d.callee.resolvedSym;
		if (sym.nativeName !== "") {
			const dest = allocReg(s);
			emitCallArgs(s, dest, d.arguments);
			const nameIdx = addConst(s, raiserString(sym.nativeName));
			emitInst(s, raiserABC(RaiserOpcode.CallHost, dest, nameIdx, d.arguments.length));
			return dest;
		}
	}

	// Extension method native call: `obj.method(args)` where the checker
	// resolved `.method` to an extern with nativeName. Mirrors the dispatch
	// in transform/lowering/extensionMethodLower.ms — instance form prepends
	// the receiver as first arg (UCS); static form (NodeFlag.ExtStatic) does
	// not, since the object is a class identifier rather than a receiver
	// value. Hardcoded special-cases above (charAt/slice/push) match first
	// as the inline-opcode shortcut for hot methods.
	if (d.callee.kind === NodeKind.MemberExpr && d.callee.resolvedSym !== null) {
		const sym = d.callee.resolvedSym;
		if (sym.nativeName !== "") {
			const isStatic = (node.flags & NodeFlag.ExtStatic) !== 0;
			const md = d.callee.data as MemberExprData;
			const allArgs: Node[] = [];
			if (!isStatic) allArgs.push(md.object);
			for (const a of d.arguments) { allArgs.push(a); }
			const dest = allocReg(s);
			emitCallArgs(s, dest, allArgs);
			const nameIdx = addConst(s, raiserString(sym.nativeName));
			emitInst(s, raiserABC(RaiserOpcode.CallHost, dest, nameIdx, allArgs.length));
			return dest;
		}
	}

	// User function call: callee must be Identifier
	if (d.callee.kind === NodeKind.Identifier) {
		const calleeId = d.callee.data as IdentifierData;
		let funcIdx = resolveFunc(s, calleeId.name);
		if (funcIdx < 0 && d.callee.resolvedSym !== null) {
			funcIdx = callRaiserOnDemand(d.callee.resolvedSym);
		}
		if (funcIdx >= 0) {
			const dest = allocReg(s);
			emitCallArgs(s, dest, d.arguments);
			emitInst(s, raiserABC(RaiserOpcode.Call, dest, funcIdx, d.arguments.length));
			return dest;
		}
	}

	// Closure / indirect call: callee is a variable holding {fn, env} pair
	return compileClosureCall(s, node);
}

function compileClosureCall(s: RaiserCompState, node: Node): number {
	const d = node.data as CallExprData;
	const argCount = d.arguments.length;

	// Compile callee expression → register holding the closure pair object
	const closureReg = compileExpr(s, d.callee);

	// Extract fn field (integer = function index) and env field
	const fnIdxReg = allocReg(s);
	const fnConstIdx = addConst(s, raiserString("fn"));
	emitInst(s, raiserABC(RaiserOpcode.LoadField, fnIdxReg, closureReg, fnConstIdx));

	const envReg = allocReg(s);
	const envConstIdx = addConst(s, raiserString("env"));
	emitInst(s, raiserABC(RaiserOpcode.LoadField, envReg, closureReg, envConstIdx));

	// Precompile all args into temp registers
	const argRegs: number[] = [];
	for (let i = 0; i < argCount; i = i + 1) {
		argRegs.push(compileExpr(s, d.arguments[i]));
	}

	// Allocate dest + (argCount+1) slots (worst case: env + args)
	const totalArgs = argCount + 1;
	const dest = allocReg(s);
	for (let i = 0; i < totalArgs; i = i + 1) { allocReg(s); }

	// Runtime check: if env is -1 (non-capturing sentinel), skip env passing
	const sentinelReg = allocReg(s);
	emitLoadConst(s, sentinelReg, raiserInt(-1));
	// BneI64 envReg, sentinelReg, 1 → if env != -1, skip next instruction (jump past no-env path)
	emitInst(s, raiserABC(RaiserOpcode.BneI64, envReg, sentinelReg, 1));
	const jumpToNoEnv = emitJumpPlaceholder(s);

	// WITH ENV path: real args first, then env LAST (Standard reference parity: closure calling convention)
	for (let i = 0; i < argCount; i = i + 1) {
		emitInst(s, raiserABC(RaiserOpcode.Move, dest + 1 + i, argRegs[i], 0));
	}
	emitInst(s, raiserABC(RaiserOpcode.Move, dest + 1 + argCount, envReg, 0));
	emitInst(s, raiserABC(RaiserOpcode.CallIndirect, dest, fnIdxReg, totalArgs));
	const jumpPastNoEnv = emitJumpPlaceholder(s);

	// NO ENV path: just real args, no env
	patchJumpTo(s, jumpToNoEnv, codeLen(s));
	for (let i = 0; i < argCount; i = i + 1) {
		emitInst(s, raiserABC(RaiserOpcode.Move, dest + 1 + i, argRegs[i], 0));
	}
	emitInst(s, raiserABC(RaiserOpcode.CallIndirect, dest, fnIdxReg, argCount));

	patchJumpTo(s, jumpPastNoEnv, codeLen(s));
	return dest;
}

// --- Conditional (ternary) ---

function compileConditionalExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as ConditionalExprData;
	const dest = allocReg(s);

	const condReg = compileExpr(s, d.ternaryCondition);
	const jumpToAlt = emitBranchIfFalsy(s, condReg);

	// Consequent
	const consReg = compileExpr(s, d.ternaryConsequent);
	emitInst(s, raiserABC(RaiserOpcode.Move, dest, consReg, 0));
	const jumpPastAlt = emitJumpPlaceholder(s);

	// Alternate
	patchJumpTo(s, jumpToAlt, codeLen(s));
	const altReg = compileExpr(s, d.ternaryAlternate);
	emitInst(s, raiserABC(RaiserOpcode.Move, dest, altReg, 0));

	patchJumpTo(s, jumpPastAlt, codeLen(s));
	return dest;
}

// --- Update (i++, ++i, i--, --i) ---

function compileUpdateExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as UpdateExprData;

	if (d.updateArg.kind === NodeKind.Identifier) {
		const id = d.updateArg.data as IdentifierData;
		const varReg = resolveLocal(s, id.name);
		if (varReg >= 0) {
			const oneReg = allocReg(s);
			emitLoadConst(s, oneReg, raiserInt(1));

			if (d.isPrefix) {
				// ++i / --i: modify first, return modified
				if (d.updateOp === "++") {
					emitInst(s, raiserABC(RaiserOpcode.AddI64, varReg, varReg, oneReg));
				} else {
					emitInst(s, raiserABC(RaiserOpcode.SubI64, varReg, varReg, oneReg));
				}
				return varReg;
			} else {
				// i++ / i--: save old value, then modify
				const oldReg = allocReg(s);
				emitInst(s, raiserABC(RaiserOpcode.Move, oldReg, varReg, 0));
				if (d.updateOp === "++") {
					emitInst(s, raiserABC(RaiserOpcode.AddI64, varReg, varReg, oneReg));
				} else {
					emitInst(s, raiserABC(RaiserOpcode.SubI64, varReg, varReg, oneReg));
				}
				return oldReg;
			}
		}
	}

	// Fallback: unsupported update target
	const reg = allocReg(s);
	emitLoadConst(s, reg, raiserNil());
	return reg;
}

// --- Object ---

function compileObjectLiteral(s: RaiserCompState, node: Node): number {
	const d = node.data as ObjectLiteralData;
	const dest = allocReg(s);

	// Create empty object
	emitInst(s, raiserABC(RaiserOpcode.NewObject, dest, 0, 0));

	// Set each field
	for (let i = 0; i < d.keys.length; i = i + 1) {
		const valReg = compileExpr(s, d.properties[i]);
		const nameIdx = addConst(s, raiserString(d.keys[i]));
		emitInst(s, raiserABC(RaiserOpcode.StoreField, dest, nameIdx, valReg));
	}

	return dest;
}

// --- Array ---

function compileArrayLiteral(s: RaiserCompState, node: Node): number {
	const d = node.data as ArrayLiteralData;
	const elemCount = d.elements.length;

	// Reserve dest + N element slots upfront
	const dest = allocReg(s);
	for (let slotIdx = 0; slotIdx < elemCount; slotIdx = slotIdx + 1) {
		allocReg(s);
	}

	// Compile each element, move result to its slot
	for (let i = 0; i < elemCount; i = i + 1) {
		const elemReg = compileExpr(s, d.elements[i]);
		const targetReg = dest + 1 + i;
		if (elemReg !== targetReg) {
			emitInst(s, raiserABC(RaiserOpcode.Move, targetReg, elemReg, 0));
		}
	}

	emitInst(s, raiserABC(RaiserOpcode.NewArray, dest, elemCount, 0));
	return dest;
}

function compileArrayAccess(s: RaiserCompState, node: Node): number {
	const d = node.data as ArrayAccessData;
	const arrReg = compileExpr(s, d.array);
	const idxReg = compileExpr(s, d.index);
	const dest = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.LoadIndex, dest, arrReg, idxReg));
	return dest;
}

function compileMemberExpr(s: RaiserCompState, node: Node): number {
	const d = node.data as MemberExprData;

	// Enum member access: Color.Red → integer constant (codegen-only path; the
	// checked AST carries this as an Identifier, handled in compileExpr).
	if (d.object.kind === NodeKind.Identifier) {
		const objId = d.object.data as IdentifierData;
		if (isEnumName(s, objId.name)) {
			const ec = findEnumConstant(s, `${objId.name}.${d.property}`);
			const reg = allocReg(s);
			emitLoadConst(s, reg, raiserInt(ec >= 0 ? s.enumMap.items[ec].index : 0));
			return reg;
		}
	}

	// .length — string vs array
	if (d.property === "length") {
		const objReg = compileExpr(s, d.object);
		const dest = allocReg(s);
		if (exprIsString(s, d.object)) {
			emitInst(s, raiserABC(RaiserOpcode.StrLen, dest, objReg, 0));
		} else {
			emitInst(s, raiserABC(RaiserOpcode.ArrayLen, dest, objReg, 0));
		}
		return dest;
	}

	// General field access on objects
	const objReg = compileExpr(s, d.object);
	const nameIdx = addConst(s, raiserString(d.property));
	const dest = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.LoadField, dest, objReg, nameIdx));
	return dest;
}

function isArrayPush(node: Node): boolean {
	if (node.kind !== NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	return d.property === "push";
}

function isToStringCall(node: Node): boolean {
	if (node.kind !== NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	return d.property === "toString";
}

function compileToStringCall(s: RaiserCompState, node: Node): number {
	const d = node.data as CallExprData;
	const md = d.callee.data as MemberExprData;
	const objReg = compileExpr(s, md.object);
	const emptyReg = allocReg(s);
	emitLoadConst(s, emptyReg, raiserString(""));
	const dest = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.ConcatStr, dest, objReg, emptyReg));
	return dest;
}

function compileArrayPushCall(s: RaiserCompState, node: Node): number {
	const d = node.data as CallExprData;
	const md = d.callee.data as MemberExprData;
	const arrReg = compileExpr(s, md.object);
	for (let i = 0; i < d.arguments.length; i = i + 1) {
		const valReg = compileExpr(s, d.arguments[i]);
		emitInst(s, raiserABC(RaiserOpcode.ArrayPush, arrReg, valReg, 0));
	}
	return arrReg;
}

// --- String method detection + compilation ---

function isStringMethod(s: RaiserCompState, node: Node, method: string): boolean {
	if (node.kind !== NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	if (d.property !== method) return false;
	return exprIsString(s, d.object);
}

function compileStrCharAt(s: RaiserCompState, node: Node): number {
	const d = node.data as CallExprData;
	const md = d.callee.data as MemberExprData;
	const strReg = compileExpr(s, md.object);
	const idxReg = compileExpr(s, d.arguments[0]);
	const dest = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.StrCharAt, dest, strReg, idxReg));
	return dest;
}

function compileStrSlice(s: RaiserCompState, node: Node): number {
	const d = node.data as CallExprData;
	const md = d.callee.data as MemberExprData;
	const strReg = compileExpr(s, md.object);
	// Start and end must be contiguous: C and C+1
	const startReg = compileExpr(s, d.arguments[0]);
	const endReg = compileExpr(s, d.arguments[1]);
	// Ensure contiguous layout: move to adjacent registers if needed
	const slotStart = allocReg(s);
	const slotEnd = allocReg(s);
	if (startReg !== slotStart) {
		emitInst(s, raiserABC(RaiserOpcode.Move, slotStart, startReg, 0));
	}
	if (endReg !== slotEnd) {
		emitInst(s, raiserABC(RaiserOpcode.Move, slotEnd, endReg, 0));
	}
	const dest = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.StrSlice, dest, strReg, slotStart));
	return dest;
}

// --- Console.log detection ---

function isConsoleLog(node: Node): boolean {
	if (node.kind !== NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	if (d.property !== "log") return false;
	if (d.object.kind !== NodeKind.Identifier) return false;
	const obj = d.object.data as IdentifierData;
	return obj.name === "console";
}
