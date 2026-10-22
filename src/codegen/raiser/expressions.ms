// Raiser codegen — Expression compilation
// AST expression nodes → typed bytecode instructions.

import { isMetaWireSym } from "../../compiler/meta/nodeSym";
import { resolveOverloadWinner } from "../c/names";
import { monoInstanceName } from "../../monomorphize/registry";
import {
	Node, NodeKind, NodeFlag, TypeKind, Type, SymbolKind, Symbol,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	BinaryExprData, UnaryExprData,
	CallExprData, IdentifierData, MemberExprData,
	ConditionalExprData, TypeAssertionData, UpdateExprData,
	ArrayLiteralData, ArrayAccessData, ObjectLiteralData,
	MoveExprData, OutExprData, VariableDeclData, AwaitExprData, NewExprData,
	HiddenDerefData, HiddenStdConvData, BlockStmtData, ExprStmtData, PropertyDeclData, SpreadExprData, ClassDeclData, MethodDeclData,
	createNodeAt
} from "../../ast/node";
import { RaiserOpcode, RaiserInstruction, RaiserConvClass, RaiserRegClass, RaiserCombine, raiserABC, raiserABx, raiserAx, convOperand, fitsImm, immField, branchField, inRefFile, MAX_SLOT } from "../../raiser/bytecode";
import { RaiserValueKind, createClassType, raiserInt, raiserFloat, raiserNil, raiserBool, raiserConstString } from "../../raiser/value";
import { lookupHostFn } from "../../raiser/hostRegistry";
import { resolveRuntimeDir } from "../../utils/path";
import { emitValueCopy, emitValueAssign, needsValueAssign, regClassOf, allocFor, joinClass, heldByLocation, slotClassesOf } from "./valueCopy";
import { placedInstanceOf } from "../../checker/instantiate";
import { nonNullMemberOfNullable } from "../../checker/compat";
import { runtimeClassSym, hasGenericParams, classParentOf, widenNumberLiteralType, typeDisplayName, unwrapRefNullUnion, getProperty, getElementType, unwrapRef, typeofTagOf, isMaybeType, isTagCarriedUnion, nullType, peelTransparentInstance, setRepr, int32Type, createPrimitive, skipModifier, peelToStructOrUnion, numberLiteralSet, isStringLike, literalBase } from "../../checker/types";
import { isSlotUnion } from "../../checker/fit";
import { SymbolFlag, isViewBinding, classDeclNodeOf, hasFlag } from "../../checker/symbol";
import { byteViewRefusal, NO_BYTE_MEMORY, pointerOpRefusal, NO_ADDRESS_ARITHMETIC } from "../../checker/byteViews";
import { carriesBigInt, RAISER_NO_BIGINT_MSG } from "../../checker/bigIntOnRaiser";
import { dispatchEntryFor, dispatchOverridesFor, isGenericFn } from "../../checker/context";
import {
	RaiserCompState, emitInst, allocReg, allocBlock, allocWord, allocFloat, allocBool, convDestClass, allocRef, allocDyn, classOfReg, addConst, emitLoadConst, resolveLocal,
	isLocalString,
	emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, patchJumpsTo, codeLen,
	callRaiserOnDemand, queueRaiserCompileError, resolveRoutine, resolveConstructor, resolveClassInit,
	callRaiserStmtCompiler, emitTrapNil, layoutOperand, CLOSURE_PAIR, CLOSURE_PAIR_KINDS, slotInst, resolveGlobal, raiserClassKey, raiserClassId, classSymOfType, landResult, declaredSymbol,
} from "./context";
import { emitZeroFill, zeroArrayType, emitOmittedFieldZeros, emitTrapValue } from "./valueCopy";

// A CallHost the registry cannot serve would only fail at macro RUN time
// ("Unknown host function"). The host table is loaded before bytecodegen
// (transformForEngine), so resolve the bridge NOW and report a missing one
// at the call site with a span — the procIsCallback-resolved-at-codegen
// shape, one phase earlier than the reference needs it.
function checkHostBridgeCoverage(sym: Symbol, callee: Node): void {
	if (lookupHostFn(sym.nativeName) == null) {
		queueRaiserCompileError(
			`no host bridge for '${sym.nativeName}' — the extern is declared in std but nothing registers it (hostTable.ms)`,
			callee.location.line, callee.location.column);
	}
}

let _stdRoot = "";

function stdRoutineName(sym: Symbol): string {
	if (sym.symbolKind != SymbolKind.Function || sym.modulePath == "") return "";
	if (_stdRoot == "") _stdRoot = resolveRuntimeDir() + "/std/";
	if (!sym.modulePath.startsWith(_stdRoot)) return "";
	let module = sym.modulePath.slice(_stdRoot.length);
	const dot = module.lastIndexOf(".");
	if (dot > module.lastIndexOf("/")) module = module.slice(0, dot);
	if (module.endsWith("/index")) module = module.slice(0, module.length - "/index".length);
	return `std/${module}.${sym.name}`;
}

function runtimeHostName(sym: Symbol): string {
	if (sym.nativeName != "") return sym.nativeName;
	const routine = stdRoutineName(sym);
	if (routine != "" && lookupHostFn(routine) != null) return routine;
	if (sym.declNode != null || !sym.symFlags.has(SymbolFlag.ImportC)) return "";
	return lookupHostFn(sym.name) != null ? sym.name : "";
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

function comparisonOpcodeImm(op: string): RaiserOpcode {
	return match (op) {
		"==" | "===" => RaiserOpcode.BeqI64Imm,
		"!=" | "!==" => RaiserOpcode.BneI64Imm,
		"<" => RaiserOpcode.BltI64Imm,
		"<=" => RaiserOpcode.BleI64Imm,
		">" => RaiserOpcode.BgtI64Imm,
		">=" => RaiserOpcode.BgeI64Imm,
		_ => { throw new Error(`internal: '${op}' has no immediate compare-and-skip opcode`); },
	};
}

function isEqualityOp(op: string): boolean {
	return op == "==" || op == "===" || op == "!=" || op == "!==";
}

// A union keeps the member it holds beside its payload, so two of them compare by the value they hold.
function holdsUnion(node: Node): boolean {
	return node.nodeType != null && isSlotUnion(peelTransparentInstance(node.nodeType));
}

function immLiteral(node: Node): boolean {
	if (node.kind != NodeKind.NumberLiteral || isFloatExpr(node) || carriesBigInt(node.nodeType)) return false;
	const d = node.data as NumberLiteralData;
	return d.outOfRangeText == "" && fitsImm(d.intVal);
}

function immLiteralValue(node: Node): int64 {
	return (node.data as NumberLiteralData).intVal;
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
		"&" | "|" | "^" | "<<" | ">>" | ">>>" => true,
		_ => false,
	};
}

function peelDistinct(t: Type): Type {
	const widened = widenNumberLiteralType(t);
	if (widened != t) return widened;
	return t.kind == TypeKind.Distinct && t.typeReturn != null ? peelDistinct(t.typeReturn) : t;
}

function isFloatType(t: Type | null): boolean {
	if (t == null) return false;
	return match (peelDistinct(t).kind) {
		TypeKind.Number | TypeKind.Float32 | TypeKind.Float64 => true,
		_ => false,
	};
}

// The checked type decides. Before the checker has run — the parse-only harness in
// rgen.ms — the parser's own `isFloat` flag on a literal is the remaining declaration.
function isFloatExpr(n: Node): boolean {
	if (n.nodeType != null) return isFloatType(n.nodeType);
	return match (n.kind) {
		NodeKind.NumberLiteral => (n.data as NumberLiteralData).isFloat,
		NodeKind.BinaryExpr => {
			const b = n.data as BinaryExprData;
			return isFloatExpr(b.left) || isFloatExpr(b.right);
		},
		NodeKind.UnaryExpr => isFloatExpr((n.data as UnaryExprData).operand),
		_ => false,
	};
}

function intBandBits(t: Type | null): int32 {
	if (t == null) return 0;
	return match (peelDistinct(t).kind) {
		TypeKind.Int8 | TypeKind.Uint8 => 8,
		TypeKind.Int16 | TypeKind.Uint16 => 16,
		TypeKind.Int32 | TypeKind.Uint32 => 32,
		_ => 0,
	};
}

function isUnsignedBand(t: Type | null): boolean {
	if (t == null) return false;
	return match (peelDistinct(t).kind) {
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => true,
		_ => false,
	};
}

function shiftCountBits(bits: int32): int32 {
	return match (bits) {
		8 => 3,
		16 => 4,
		_ => 5,
	};
}

function convClassOf(t: Type | null): int32 {
	if (t == null) return -1;
	return match (peelDistinct(t).kind) {
		TypeKind.Number | TypeKind.Float64 => RaiserConvClass.F64 as int32,
		TypeKind.Float32 => RaiserConvClass.F32 as int32,
		TypeKind.Int64 => RaiserConvClass.I64 as int32,
		TypeKind.Int32 => RaiserConvClass.I32 as int32,
		TypeKind.Int16 => RaiserConvClass.I16 as int32,
		TypeKind.Int8 => RaiserConvClass.I8 as int32,
		TypeKind.Uint64 => RaiserConvClass.U64 as int32,
		TypeKind.Uint32 => RaiserConvClass.U32 as int32,
		TypeKind.Uint16 => RaiserConvClass.U16 as int32,
		TypeKind.Uint8 => RaiserConvClass.U8 as int32,
		TypeKind.Char => RaiserConvClass.Char as int32,
		TypeKind.Enum => RaiserConvClass.I64 as int32,
		_ => -1,
	};
}

function emitAtWidth(s: RaiserCompState, reg: int32, t: Type | null): void {
	if (t != null && peelDistinct(t).kind == TypeKind.Float32) {
		emitInst(s, raiserABC(RaiserOpcode.Conv, reg, reg, RaiserConvClass.F32 as int32));
		return;
	}
	const bits = intBandBits(t);
	if (bits == 0) return;
	if (isUnsignedBand(t)) {
		emitInst(s, raiserABC(RaiserOpcode.NarrowU, reg, bits, 0));
	} else {
		emitInst(s, raiserABC(RaiserOpcode.NarrowS, reg, bits, 0));
	}
}

function emitConvTo(s: RaiserCompState, srcReg: int32, cls: int32, fromCls: int32): int32 {
	const dest = allocReg(s, convDestClass(cls));
	emitInst(s, raiserABC(RaiserOpcode.Conv, dest, srcReg, convOperand(cls as RaiserConvClass, fromCls)));
	return dest;
}

function compileIndex(s: RaiserCompState, index: Node): int32 {
	const reg = compileExpr(s, index);
	if (!isFloatExpr(index)) return reg;
	return emitConvTo(s, reg, RaiserConvClass.I64 as int32, RaiserConvClass.F64 as int32);
}

function emitNumericConv(s: RaiserCompState, reg: int32, from: Type | null, to: Type | null): int32 {
	const fromCls = convClassOf(from);
	const toCls = convClassOf(to);
	if (fromCls < 0 || toCls < 0 || fromCls == toCls) return reg;
	return emitConvTo(s, reg, toCls, fromCls);
}

function isUint64Type(t: Type | null): boolean {
	return t != null && peelDistinct(t).kind == TypeKind.Uint64;
}

function compileStringPart(s: RaiserCompState, node: Node): int32 {
	const reg = compileExpr(s, node);
	if (node.nodeType != null && peelDistinct(node.nodeType).kind == TypeKind.Char) {
		return emitConvTo(s, reg, RaiserConvClass.Str as int32, RaiserConvClass.Char as int32);
	}
	if (!isUint64Type(node.nodeType)) return reg;
	return emitConvTo(s, reg, RaiserConvClass.Str as int32, RaiserConvClass.U64 as int32);
}

function bitwiseOpcode(op: string): RaiserOpcode {
	return match (op) {
		"&" => RaiserOpcode.BitAnd,
		"|" => RaiserOpcode.BitOr,
		"^" => RaiserOpcode.BitXor,
		"<<" => RaiserOpcode.ShiftLeft,
		">>" => RaiserOpcode.ShiftRight,
		">>>" => RaiserOpcode.ShiftRightU,
		_ => RaiserOpcode.BitAnd,
	};
}

function isCompoundAssignOp(op: string): boolean {
	return match (op) {
		"+=" | "-=" | "*=" | "/=" | "%=" | "**=" => true,
		"&=" | "|=" | "^=" | "<<=" | ">>=" | ">>>=" => true,
		_ => false,
	};
}

function emitBitwise(s: RaiserCompState, op: string, dest: int32, lReg: int32, rReg: int32, t: Type | null): void {
	const opc = bitwiseOpcode(op);
	if (opc != RaiserOpcode.ShiftLeft && opc != RaiserOpcode.ShiftRight && opc != RaiserOpcode.ShiftRightU) {
		emitInst(s, raiserABC(opc, dest, lReg, rReg));
		return;
	}
	const bits = intBandBits(t);
	const unsigned = isUnsignedBand(t);
	const count = allocWord(s);
	emitInst(s, raiserABC(RaiserOpcode.Move, count, rReg, 0));
	if (bits > 0) emitInst(s, raiserABC(RaiserOpcode.NarrowU, count, shiftCountBits(bits), 0));
	let left = lReg;
	const shift = opc == RaiserOpcode.ShiftRight && unsigned ? RaiserOpcode.ShiftRightU : opc;
	if (shift == RaiserOpcode.ShiftRightU && bits > 0) {
		left = allocWord(s);
		emitInst(s, raiserABC(RaiserOpcode.Move, left, lReg, 0));
		emitInst(s, raiserABC(RaiserOpcode.NarrowU, left, bits, 0));
	}
	emitInst(s, raiserABC(shift, dest, left, count));
	if (bits > 0 && (opc == RaiserOpcode.ShiftLeft || (opc == RaiserOpcode.ShiftRightU && !unsigned))) {
		emitInst(s, raiserABC(unsigned ? RaiserOpcode.NarrowU : RaiserOpcode.SignExtend, dest, bits, 0));
	}
}

function compileBitwiseOperand(s: RaiserCompState, operand: Node): int32 {
	if (operand.kind != NodeKind.HiddenStdConv) return compileExpr(s, operand);
	const hd = operand.data as HiddenStdConvData;
	const fromCls = convClassOf(hd.convExpr.nodeType);
	if (convClassOf(hd.convType) != (RaiserConvClass.I32 as int32)
		|| (fromCls != (RaiserConvClass.F64 as int32) && fromCls != (RaiserConvClass.F32 as int32))) {
		return compileExpr(s, operand);
	}
	return emitConvTo(s, compileExpr(s, hd.convExpr), RaiserConvClass.I32Wrap as int32, fromCls);
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

function emitCompoundArith(s: RaiserCompState, op: string, dest: int32, lhs: int32, rhs: int32, target: Node): void {
	const base = op.slice(0, op.length - 1);
	if (isBitwiseOp(base) && convClassOf(target.nodeType) == (RaiserConvClass.F64 as int32)) {
		const asInt = emitConvTo(s, lhs, RaiserConvClass.I32Wrap as int32, RaiserConvClass.F64 as int32);
		const stored = base == ">>>" ? createPrimitive(TypeKind.Uint32) : int32Type();
		const bits = allocWord(s);
		emitBitwise(s, base, bits, asInt, rhs, stored);
		emitInst(s, raiserABC(RaiserOpcode.Move, dest, emitConvTo(s, bits, RaiserConvClass.F64 as int32, convClassOf(stored)), 0));
		return;
	}
	if (isBitwiseOp(base)) {
		emitBitwise(s, base, dest, lhs, rhs, target.nodeType);
		return;
	}
	if (base == "**") {
		const power = emitHostPair(s, "pow", lhs, rhs);
		const cls = convClassOf(target.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.Move, dest, cls >= 0 && cls != (RaiserConvClass.F64 as int32) ? emitConvTo(s, power, cls, RaiserConvClass.F64 as int32) : power, 0));
		return;
	}
	if (!isFloatExpr(target)) {
		emitInst(s, raiserABC(unsignedOpcode(compoundBaseOpcode(op), target.nodeType), dest, lhs, rhs));
		emitAtWidth(s, dest, target.nodeType);
		return;
	}
	if (base != "%") {
		emitInst(s, raiserABC(arithmeticOpcodeF64(base), dest, floatOperand(s, lhs), floatOperand(s, rhs)));
		emitAtWidth(s, dest, target.nodeType);
		return;
	}
	emitInst(s, raiserABC(RaiserOpcode.Move, dest, emitHostPair(s, "fmod", lhs, rhs), 0));
	emitAtWidth(s, dest, target.nodeType);
}

const FLOAT_PAIR_CALL: RaiserRegClass[] = [RaiserRegClass.Float, RaiserRegClass.Float, RaiserRegClass.Float];

// The host arithmetic functions take and return floats; an integer operand is converted first.
function floatOperand(s: RaiserCompState, reg: int32): int32 {
	if (classOfReg(s, reg) != RaiserRegClass.Word) return reg;
	return emitConvTo(s, reg, RaiserConvClass.F64 as int32, RaiserConvClass.I64 as int32);
}

function emitHostPair(s: RaiserCompState, name: string, lhs: int32, rhs: int32): int32 {
	const out = allocBlock(s, FLOAT_PAIR_CALL);
	const a1 = out + 1;
	const a2 = out + 2;
	emitInst(s, raiserABC(RaiserOpcode.Move, a1, floatOperand(s, lhs), 0));
	emitInst(s, raiserABC(RaiserOpcode.Move, a2, floatOperand(s, rhs), 0));
	emitInst(s, raiserABC(RaiserOpcode.CallHost, out, addConst(s, raiserConstString(name)), 2));
	return out;
}

function unsignedOpcode(opc: RaiserOpcode, t: Type | null): RaiserOpcode {
	if (!isUnsignedBand(t)) return opc;
	return match (opc) {
		RaiserOpcode.AddI64 => RaiserOpcode.AddU64,
		RaiserOpcode.SubI64 => RaiserOpcode.SubU64,
		RaiserOpcode.MulI64 => RaiserOpcode.MulU64,
		RaiserOpcode.DivI64 => isUint64Type(t) ? RaiserOpcode.DivU64 : opc,
		RaiserOpcode.ModI64 => isUint64Type(t) ? RaiserOpcode.ModU64 : opc,
		_ => opc,
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
	if (node.nodeType != null) {
		if (literalBase(node.nodeType).kind == TypeKind.String) return true;
	}
	const k = node.kind;
	if (k == NodeKind.StringLiteral) return true;
	if (k == NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		return isLocalString(s, node.resolvedSym);
	}
	if (k == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator == "+") {
			return exprIsString(s, d.left) || exprIsString(s, d.right);
		}
		return false;
	}
	if (k == NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		return exprIsString(s, d.ternaryConsequent) || exprIsString(s, d.ternaryAlternate);
	}
	return false;
}

// --- Expression compilation ---
// Returns the register holding the result.

function compileExprInto(s: RaiserCompState, node: Node, target: number): void {
	const startPc = codeLen(s);
	const firstTemp = s.nextReg;
	landResult(s, target, startPc, firstTemp, compileExpr(s, node));
}

// A Dyn register holds a box, so an expression whose checked type has a plain class (a variable
// narrowed from a union) is read out of it into a register of that class.
export function compileExpr(s: RaiserCompState, node: Node): int32 {
	const reg = compileExprRaw(s, node);
	if (classOfReg(s, reg) != RaiserRegClass.Dyn || holdsLocation(node)) return reg;
	const cls = regClassOf(s, node.nodeType);
	if (cls == RaiserRegClass.Dyn) return reg;
	const plain = allocReg(s, cls);
	emitInst(s, raiserABC(RaiserOpcode.Move, plain, reg, 0));
	return plain;
}

function holdsLocation(node: Node): boolean {
	if (node.kind == NodeKind.HiddenAddr) return true;
	const sym = node.resolvedSym;
	if (node.kind != NodeKind.Identifier || sym == null || sym.symbolType == null) return false;
	const held = sym.symbolType.kind;
	return held == TypeKind.Var || held == TypeKind.Borrow || held == TypeKind.Ref || held == TypeKind.Ptr;
}

function compileExprRaw(s: RaiserCompState, node: Node): int32 {
	if (carriesBigInt(node.nodeType)) return refuseBigInt(s, node);
	return match (node.kind) {
		NodeKind.NumberLiteral => {
			const d = node.data as NumberLiteralData;
			const reg = isFloatExpr(node) ? allocFloat(s) : allocWord(s);
			if (isFloatExpr(node)) {
				const narrow = node.nodeType != null && peelDistinct(node.nodeType).kind == TypeKind.Float32;
				emitLoadConst(s, reg, raiserFloat(narrow ? (d.value as float32) as float64 : d.value));
			} else {
				emitLoadConst(s, reg, raiserInt(d.intVal));
			}
			return reg;
		},
		NodeKind.StringLiteral => {
			const d = node.data as StringLiteralData;
			const reg = allocRef(s);
			emitLoadConst(s, reg, raiserConstString(d.value));
			return reg;
		},
		NodeKind.BooleanLiteral => {
			const d = node.data as BooleanLiteralData;
			const reg = allocBool(s);
			emitLoadConst(s, reg, raiserBool(d.boolValue));
			return reg;
		},
		NodeKind.NullLiteral => {
			const reg = allocRef(s);
			emitLoadConst(s, reg, raiserNil());
			return reg;
		},
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			const global = resolveGlobal(s, node.resolvedSym);
			if (global >= 0) {
				const destination = allocFor(s, node.resolvedSym != null && node.resolvedSym!.symbolType != null ? node.resolvedSym!.symbolType : node.nodeType);
				emitInst(s, raiserABC(RaiserOpcode.LoadGlobal, destination, global, 0));
				return destination;
			}
			const reg = resolveLocal(s, node.resolvedSym);
			if (reg >= 0) return reg;
			if (node.resolvedSym != null && node.resolvedSym.builtinKind == "NaN") {
				const nanReg = allocFloat(s);
				emitLoadConst(s, nanReg, raiserFloat(NaN));
				return nanReg;
			}
			if (node.resolvedSym != null && node.resolvedSym.builtinKind == "Infinity") {
				const infinityReg = allocFloat(s);
				emitLoadConst(s, infinityReg, raiserFloat(Infinity));
				return infinityReg;
			}
			if (node.resolvedSym != null && node.resolvedSym.symbolKind == SymbolKind.EnumMember
				&& node.resolvedSym.symbolType != null) {
				return compileEnumOrdinal(s, node, node.resolvedSym);
			}
			const funcIdx = resolveRoutine(s, node.resolvedSym);
			if (funcIdx >= 0) {
				const r = allocWord(s);
				emitLoadConst(s, r, raiserInt(funcIdx));
				return r;
			}
			// Module-level const — the reference inlines skConst through the
			// symbol's defining AST: compile the initializer at the use site.
			// Consts are immutable by construction, so the value at the
			// declaration is the value at every use; mutable module vars
			// keep falling through to the error below.
			if (node.resolvedSym != null && node.resolvedSym.symbolKind == SymbolKind.Variable
				&& node.resolvedSym.declNode != null
				&& node.resolvedSym.declNode.kind == NodeKind.VariableDecl
				&& !node.resolvedSym.symFlags.has(SymbolFlag.Mutable)) {
				const vd = node.resolvedSym.declNode.data as VariableDeclData;
				if (vd.initializer != null) {
					return compileExpr(s, vd.initializer);
				}
			}
			if (node.resolvedSym != null && node.resolvedSym.symbolKind == SymbolKind.Variable
				&& node.resolvedSym.symFlags.has(SymbolFlag.ImportC)) {
				const externMsg = `cannot read extern '${d.name}' in the Raiser VM: an extern let or const has no host value`;
				queueRaiserCompileError(externMsg, node.location.line, node.location.column);
				return emitTrapValue(s, externMsg, node.nodeType);
			}
			// Nothing the bytecode compiler can execute bound this name (module-
			// level vars and other non-routine symbols land here). Report it
			// instead of silently splicing nil into the macro's output.
			let why = "no local, function, enum constant, or builtin binding reached the bytecode compiler";
			if (node.resolvedSym == null) why = "symbol did not resolve";
			else if (node.resolvedSym.symbolKind != SymbolKind.Variable) why = `symbol kind is ${node.resolvedSym.symbolKind}`;
			else if (node.resolvedSym.declNode == null) why = "symbol has no declaration node";
			else if (node.resolvedSym.declNode.kind != NodeKind.VariableDecl) why = `declaration node is ${node.resolvedSym.declNode.kind}`;
			else if (node.resolvedSym.symFlags.has(SymbolFlag.Mutable)) why = "symbol is mutable";
			else if ((node.resolvedSym.declNode.data as VariableDeclData).initializer == null) why = "declaration has no initializer";
			const msg = `cannot evaluate '${d.name}' at comptime: ${why}`;
			queueRaiserCompileError(msg, node.location.line, node.location.column);
			return emitTrapValue(s, msg, node.nodeType);
		},
		NodeKind.BinaryExpr => { return compileBinaryExpr(s, node); },
		NodeKind.UnaryExpr => { return compileUnaryExpr(s, node); },
		NodeKind.CallExpr => { return compileCallExpr(s, node); },
		NodeKind.ConditionalExpr => { return compileConditionalExpr(s, node); },
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			const refused = refuseByteView(s, node, d.asExpr.nodeType, node.nodeType);
			if (refused >= 0) return refused;
			const reg = compileExpr(s, d.asExpr);
			if (node.flags.has(NodeFlag.ObjCheck)) return emitObjConv(s, node, reg);
			if (node.flags.has(NodeFlag.ConvCheck)) emitLitConv(s, node, reg);
			return emitNumericConv(s, reg, d.asExpr.nodeType, node.nodeType);
		},
		NodeKind.UpdateExpr => { return compileUpdateExpr(s, node, false); },
		NodeKind.ArrayLiteral => { return compileArrayLiteral(s, node); },
		NodeKind.ArrayAccess => { return compileArrayAccess(s, node); },
		NodeKind.MemberExpr => { return compileMemberExpr(s, node); },
		NodeKind.ObjectLiteral => { return compileObjectLiteral(s, node); },
		NodeKind.NewExpr => { return compileNewExpr(s, node); },
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			return compileExpr(s, d.moveArg);
		},
		NodeKind.OutExpr => { return compileExpr(s, (node.data as OutExprData).outArg); },
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			const futReg = compileExpr(s, d.awaitArg);
			const dest = allocFor(s, node.nodeType);
			emitInst(s, raiserABC(RaiserOpcode.Await, dest, futReg, 0));
			return dest;
		},
		// Hidden* nodes are checker-inserted markers (deref point for Ref<Struct>,
		// implicit type conversion). Raiser VM is dynamically typed and has no
		// pointer-vs-value distinction — passthrough compile the inner expr.
		// Mirrors C backend (expressions.ms:852,860,868) and JS backend
		// (jsgen.ms:81-82). Without these arms the chain `o.inner.msg` on a
		// Ref<Struct> field silently fell through to LoadConst nil, breaking
		// every @comptime access on cross-module Ref<Struct> types.
		NodeKind.HiddenDeref => {
			const hd = node.data as HiddenDerefData;
			const pointer = compileExpr(s, hd.expr);
			if (!heldByLocation(s, node.nodeType)) return pointer;
			const dest = allocFor(s, node.nodeType);
			emitInst(s, raiserABC(RaiserOpcode.LoadDeref, dest, pointer, 0));
			return dest;
		},
		NodeKind.HiddenAddr => {
			const hd = node.data as HiddenDerefData;
			if (!heldByLocation(s, hd.expr.nodeType)) return compileExpr(s, hd.expr);
			if (!isPlace(s, hd.expr)) return compileCellAddress(s, hd.expr);
			return compileAddress(s, hd.expr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const hd = node.data as HiddenStdConvData;
			const refused = refuseByteView(s, node, hd.convExpr.nodeType, hd.convType);
			if (refused >= 0) return refused;
			const reg = compileExpr(s, hd.convExpr);
			if (isSpanType(hd.convType) && exprIsString(s, hd.convExpr)) return compileStringBytes(s, reg);
			return emitNumericConv(s, reg, hd.convExpr.nodeType, hd.convType);
		},
		// Statement-list-in-expression position: run n-1 statements, the last
		// ExprStmt is the value — the reference VM's stmt-list-expr shape.
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			const n = d.statements.length;
			if (n == 0) {
				const reg = allocRef(s);
				emitLoadConst(s, reg, raiserNil());
				return reg;
			}
			let i = 0;
			while (i < n - 1) {
				callRaiserStmtCompiler(s, d.statements[i]);
				i = i + 1;
			}
			const last = d.statements[n - 1];
			if (last.kind == NodeKind.ExprStmt) {
				const ld = last.data as ExprStmtData;
				return compileExpr(s, ld.expr);
			}
			callRaiserStmtCompiler(s, last);
			const reg = allocRef(s);
			emitLoadConst(s, reg, raiserNil());
			return reg;
		},
		_ => {
			// Unsupported node kind: report instead of silently splicing nil.
			const msg = `cannot compile node kind ${node.kind} at comptime: unsupported by the Raiser bytecode compiler`;
			queueRaiserCompileError(msg, node.location.line, node.location.column);
			return emitTrapNil(s, msg);
		},
	};
}

// --- Binary ---

function isRefParamTarget(left: Node): boolean {
	const sym = left.resolvedSym;
	return left.kind == NodeKind.Identifier && sym != null && sym.symbolKind == SymbolKind.Parameter
		&& sym.symbolType != null && sym.symbolType.kind == TypeKind.Var;
}

function compileValueAssign(s: RaiserCompState, left: Node, right: Node): int32 {
	if (isRefParamTarget(left)) {
		const pointeeType = left.resolvedSym!.symbolType.typeReturn;
		const paramReg = resolveLocal(s, left.resolvedSym);
		if (paramReg < 0 || heldByLocation(s, pointeeType)) return -1;
		const srcReg = compileExpr(s, right);
		return emitValueAssign(s, paramReg, srcReg, pointeeType);
	}
	if (!needsValueAssign(s, left.nodeType)) return -1;
	if (left.kind == NodeKind.HiddenDeref) {
		const srcReg = compileExpr(s, right);
		const pointee = compileExpr(s, (left.data as HiddenDerefData).expr);
		if (!heldByLocation(s, left.nodeType)) return emitValueAssign(s, pointee, srcReg, left.nodeType);
		const held = allocFor(s, left.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.LoadDeref, held, pointee, 0));
		const result = emitValueAssign(s, held, srcReg, left.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.StoreDeref, pointee, 0, result));
		return result;
	}
	if (left.kind == NodeKind.Identifier) {
		if (isViewBinding(left.resolvedSym)) return -1;
		const global = resolveGlobal(s, left.resolvedSym);
		if (global >= 0) {
			const srcReg = compileExpr(s, right);
			const held = allocFor(s, left.resolvedSym != null && left.resolvedSym!.symbolType != null ? left.resolvedSym!.symbolType : left.nodeType);
			emitInst(s, raiserABC(RaiserOpcode.LoadGlobal, held, global, 0));
			const result = emitValueAssign(s, held, srcReg, left.nodeType);
			emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, result, global, 0));
			return result;
		}
		const targetReg = resolveLocal(s, left.resolvedSym);
		if (targetReg < 0) return -1;
		const srcReg = compileExpr(s, right);
		const result = emitValueAssign(s, targetReg, srcReg, left.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.Move, targetReg, result, 0));
		return targetReg;
	}
	if (left.kind == NodeKind.ArrayAccess) {
		const srcReg = compileExpr(s, right);
		const ad = left.data as ArrayAccessData;
		const arrReg = compileExpr(s, ad.array);
		const idxReg = compileIndex(s, ad.index);
		const held = allocFor(s, left.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.LoadIndex, held, arrReg, idxReg));
		const result = emitValueAssign(s, held, srcReg, left.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.StoreIndex, arrReg, idxReg, result));
		return result;
	}
	if (left.kind == NodeKind.MemberExpr && !(left.data as MemberExprData).isOptional) {
		const srcReg = compileExpr(s, right);
		const md = left.data as MemberExprData;
		const objReg = compileExpr(s, md.object);
		const nameIdx = addConst(s, raiserConstString(md.property));
		const held = allocFor(s, left.nodeType);
		emitInst(s, fieldInst(s, md.object.nodeType, md.property, RaiserOpcode.LoadField, RaiserOpcode.LoadSlot, held, objReg, nameIdx));
		const result = emitValueAssign(s, held, srcReg, left.nodeType);
		emitInst(s, fieldInst(s, md.object.nodeType, md.property, RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, objReg, nameIdx, result));
		return result;
	}
	return -1;
}

function isPointerTyped(node: Node): boolean {
	let t = skipModifier(node.nodeType);
	const nonNull = t != null ? nonNullMemberOfNullable(t) : null;
	if (nonNull != null) t = nonNull;
	return t != null && t.kind == TypeKind.Ptr;
}

function derefTarget(s: RaiserCompState, target: Node): Node | null {
	if (target.kind == NodeKind.HiddenDeref) {
		if (!heldByLocation(s, target.nodeType)) return null;
		return (target.data as HiddenDerefData).expr;
	}
	if (target.kind == NodeKind.ArrayAccess) {
		const d = target.data as ArrayAccessData;
		const held = skipModifier(d.array.nodeType);
		if (held != null && held.kind == TypeKind.Ptr && heldByLocation(s, target.nodeType)) return d.array;
	}
	return null;
}

function compileCellAddress(s: RaiserCompState, value: Node): int32 {
	const cell = allocBlock(s, [RaiserRegClass.Ref, regClassOf(s, value.nodeType)]);
	const slot = cell + 1;
	const reg = compileExpr(s, value);
	if (reg != slot) emitInst(s, raiserABC(RaiserOpcode.Move, slot, reg, 0));
	emitInst(s, raiserABC(RaiserOpcode.NewArray, cell, 1, 0));
	const zero = allocWord(s);
	emitLoadConst(s, zero, raiserInt(0));
	const dest = allocDyn(s);
	emitInst(s, raiserABC(RaiserOpcode.AddrIndex, dest, cell, zero));
	return dest;
}

function isPlace(s: RaiserCompState, node: Node): boolean {
	if (node.kind == NodeKind.Identifier) {
		return resolveGlobal(s, node.resolvedSym) >= 0 || resolveLocal(s, node.resolvedSym) >= 0;
	}
	return node.kind == NodeKind.ArrayAccess || node.kind == NodeKind.MemberExpr || node.kind == NodeKind.HiddenDeref;
}

function compileAddress(s: RaiserCompState, place: Node): int32 {
	const dest = allocDyn(s);
	if (place.kind == NodeKind.Identifier) {
		const global = resolveGlobal(s, place.resolvedSym);
		if (global >= 0) {
			emitInst(s, raiserABx(RaiserOpcode.AddrGlobal, dest, global));
			return dest;
		}
		const local = resolveLocal(s, place.resolvedSym);
		if (local >= 0) {
			emitInst(s, raiserABC(RaiserOpcode.AddrReg, dest, local, 0));
			return dest;
		}
	} else if (place.kind == NodeKind.ArrayAccess) {
		const d = place.data as ArrayAccessData;
		const held = skipModifier(d.array.nodeType);
		if (held != null && held.kind == TypeKind.Ptr) return compileExpr(s, d.array);
		const arrReg = compileExpr(s, d.array);
		const idxReg = compileIndex(s, d.index);
		emitInst(s, raiserABC(RaiserOpcode.AddrIndex, dest, arrReg, idxReg));
		return dest;
	} else if (place.kind == NodeKind.MemberExpr) {
		const d = place.data as MemberExprData;
		const objReg = compileExpr(s, d.object);
		emitInst(s, raiserABC(RaiserOpcode.AddrField, dest, objReg, addConst(s, raiserConstString(d.property))));
		return dest;
	} else if (place.kind == NodeKind.HiddenDeref) {
		return compileExpr(s, (place.data as HiddenDerefData).expr);
	}
	const msg = `internal: the Raiser VM has no address for a ${place.kind.toString()}`;
	queueRaiserCompileError(msg, place.location.line, place.location.column);
	return emitTrapNil(s, msg);
}

function refuseByteView(s: RaiserCompState, node: Node, source: Type | null, target: Type | null): int32 {
	const refusal = byteViewRefusal(source, target, true);
	if (refusal == "") return -1;
	const msg = refusal + " on the Raiser VM" + NO_BYTE_MEMORY;
	queueRaiserCompileError(msg, node.location.line, node.location.column);
	return emitTrapNil(s, msg);
}

function refuseBigInt(s: RaiserCompState, node: Node): int32 {
	queueRaiserCompileError(RAISER_NO_BIGINT_MSG, node.location.line, node.location.column);
	return emitTrapNil(s, RAISER_NO_BIGINT_MSG);
}

function refusePointerOp(s: RaiserCompState, node: Node): int32 {
	const refusal = pointerOpRefusal(node);
	if (refusal == "") return -1;
	const msg = refusal + " on the Raiser VM" + NO_ADDRESS_ARITHMETIC;
	queueRaiserCompileError(msg, node.location.line, node.location.column);
	return emitTrapNil(s, msg);
}

export function classTargetKey(t: Type | null): string {
	let bare = t != null && t.kind == TypeKind.Union ? unwrapRefNullUnion(t) : t;
	if (bare != null && bare.kind == TypeKind.Ref && bare.typeReturn != null) bare = bare.typeReturn;
	if (bare != null && bare.kind == TypeKind.GenericInstance) return monoInstanceName(bare);
	const sym = classSymOfType(bare);
	return sym != null && sym.symbolKind == SymbolKind.Class ? raiserClassKey(sym) : "";
}

function classDisplayName(key: string): string {
	const hash = key.lastIndexOf("#");
	const colon = key.lastIndexOf(":", hash);
	return hash < 0 ? key : key.slice(colon + 1, hash);
}

function classTargetDisplay(t: Type | null, key: string): string {
	let bare = t != null && t.kind == TypeKind.Union ? unwrapRefNullUnion(t) : t;
	if (bare != null && bare.kind == TypeKind.Ref && bare.typeReturn != null) bare = bare.typeReturn;
	return bare != null && bare.kind == TypeKind.GenericInstance ? typeDisplayName(bare) : classDisplayName(key);
}

function emitObjConv(s: RaiserCompState, node: Node, reg: int32): int32 {
	const key = classTargetKey(node.nodeType);
	if (key == "") {
		const msg = "internal: a checked object conversion has no class target";
		queueRaiserCompileError(msg, node.location.line, node.location.column);
		return emitTrapNil(s, msg);
	}
	emitInst(s, raiserABC(RaiserOpcode.ObjConv, reg, classTargetOperand(s, node.nodeType, key), addConst(s, raiserConstString(classTargetDisplay(node.nodeType, key)))));
	return reg;
}

function emitLitConv(s: RaiserCompState, node: Node, reg: int32): void {
	const t = node.nodeType;
	if (t == null) return;
	const payload = isMaybeType(t) && t.typeReturn != null ? t.typeReturn : t;
	const literals: Type[] | null = payload.kind != TypeKind.String && isStringLike(payload)
		? (payload.kind == TypeKind.StringLiteral ? [payload] : payload.typeChildren)
		: numberLiteralSet(payload);
	if (literals == null) return;
	let list = "";
	for (const lit of literals) list += `${lit.typeName.length}:${lit.typeName}`;
	const name = payload.sym != null && payload.sym.name != "" ? payload.sym.name : typeDisplayName(payload);
	emitInst(s, raiserABC(RaiserOpcode.LitConv, reg, addConst(s, raiserConstString(list)), addConst(s, raiserConstString(name))));
}

function compileInstanceOf(s: RaiserCompState, node: Node, d: BinaryExprData): int32 {
	const named = d.right.resolvedSym;
	const target = named != null && named.symbolKind == SymbolKind.Class ? named.symbolType : d.right.nodeType;
	const key = named != null && named.symbolKind == SymbolKind.Class ? raiserClassKey(named) : classTargetKey(d.right.nodeType);
	if (key == "") {
		const msg = "internal: the right side of instanceof did not resolve to a class";
		queueRaiserCompileError(msg, node.location.line, node.location.column);
		return emitTrapNil(s, msg);
	}
	const held = compileExpr(s, d.left);
	const dest = allocBool(s);
	emitInst(s, raiserABC(RaiserOpcode.InstanceOf, dest, held, classTargetOperand(s, target, key)));
	return dest;
}

// Operands are compiled; the returned instruction skips the next one when the
// comparison holds. A value wraps it as `true; skip; false`, a condition as
// `skip; Jump`. Null and pointer equality are value ops, handled before it.
function compileCompareTest(s: RaiserCompState, node: Node): RaiserInstruction | null {
	const d = node.data as BinaryExprData;
	const op = d.operator;
	if (!isComparisonOp(op)) return null;
	const lReg = compileExpr(s, d.left);
	const valueOpcode = op == "==" || op == "===" ? RaiserOpcode.EqVal : RaiserOpcode.NeVal;
	if (isEqualityOp(op) && (holdsUnion(d.left) || holdsUnion(d.right))) {
		const heldReg = compileExpr(s, d.right);
		return raiserABC(valueOpcode, lReg, heldReg, 1);
	}
	const integerCompare = !inRefFile(classOfReg(s, lReg)) && !exprIsString(s, d.left) && !exprIsString(s, d.right) && !isFloatExpr(d.left) && !isFloatExpr(d.right)
		&& !((isUint64Type(d.left.nodeType) || isUint64Type(d.right.nodeType)) && !isEqualityOp(op));
	if (integerCompare && immLiteral(d.right)) {
		return raiserABC(comparisonOpcodeImm(op), lReg, immField(immLiteralValue(d.right)), 1);
	}
	const rReg = compileExpr(s, d.right);
	if (exprIsString(s, d.left) || exprIsString(s, d.right)) {
		if (op == "==" || op == "===") return raiserABC(RaiserOpcode.EqStr, lReg, rReg, 1);
		if (op == "!=" || op == "!==") return raiserABC(RaiserOpcode.NeStr, lReg, rReg, 1);
		// `>` and `>=` swap their operands onto `<` and `<=`, so two opcodes cover four operators
		const swapped = op == ">" || op == ">=";
		const strict = op == "<" || op == ">";
		return raiserABC(strict ? RaiserOpcode.LtStr : RaiserOpcode.LeStr, swapped ? rReg : lReg, swapped ? lReg : rReg, 1);
	}
	if (isEqualityOp(op) && (inRefFile(classOfReg(s, lReg)) || inRefFile(classOfReg(s, rReg)))) return raiserABC(valueOpcode, lReg, rReg, 1);
	if (isFloatExpr(d.left) || isFloatExpr(d.right)) return raiserABC(comparisonOpcodeF64(op), floatOperand(s, lReg), floatOperand(s, rReg), 1);
	if ((isUint64Type(d.left.nodeType) || isUint64Type(d.right.nodeType)) && op != "==" && op != "===" && op != "!=" && op != "!==") {
		const swapped = op == ">" || op == ">=";
		const strict = op == "<" || op == ">";
		return raiserABC(strict ? RaiserOpcode.BltU64 : RaiserOpcode.BleU64, swapped ? rReg : lReg, swapped ? lReg : rReg, 1);
	}
	return raiserABC(comparisonOpcode(op), lReg, rReg, 1);
}

// --- Conditions ---
// `condJumps` compiles a condition for control flow. It falls through when the
// condition's truth differs from `whenTrue` and returns the jumps taken when it
// matches; the caller patches them. A comparison is one compare-and-skip plus
// the jump, `!` flips the sense, `&&` and `||` chain jumps and materialise no bool.

// After a skip opcode that fires on true: the jump taken when the test is false, or, for
// `whenTrue`, a jump the skip hops over so that false routes past the taken one.
function jumpAfterSkip(s: RaiserCompState, whenTrue: boolean): int32[] {
	if (!whenTrue) return [emitJumpPlaceholder(s)];
	const over = emitJumpPlaceholder(s);
	const taken = emitJumpPlaceholder(s);
	patchJumpTo(s, over, codeLen(s));
	return [taken];
}

// An integer compare-and-skip as one branch taken when the comparison equals `whenTrue`; any other opcode comes back unchanged.
function branchOpcode(test: RaiserOpcode, whenTrue: boolean): RaiserOpcode {
	return match (test) {
		RaiserOpcode.BeqI64 => whenTrue ? RaiserOpcode.BrEqI64 : RaiserOpcode.BrNeI64,
		RaiserOpcode.BneI64 => whenTrue ? RaiserOpcode.BrNeI64 : RaiserOpcode.BrEqI64,
		RaiserOpcode.BltI64 => whenTrue ? RaiserOpcode.BrLtI64 : RaiserOpcode.BrGeI64,
		RaiserOpcode.BleI64 => whenTrue ? RaiserOpcode.BrLeI64 : RaiserOpcode.BrGtI64,
		RaiserOpcode.BgtI64 => whenTrue ? RaiserOpcode.BrGtI64 : RaiserOpcode.BrLeI64,
		RaiserOpcode.BgeI64 => whenTrue ? RaiserOpcode.BrGeI64 : RaiserOpcode.BrLtI64,
		RaiserOpcode.BeqI64Imm => whenTrue ? RaiserOpcode.BrEqI64Imm : RaiserOpcode.BrNeI64Imm,
		RaiserOpcode.BneI64Imm => whenTrue ? RaiserOpcode.BrNeI64Imm : RaiserOpcode.BrEqI64Imm,
		RaiserOpcode.BltI64Imm => whenTrue ? RaiserOpcode.BrLtI64Imm : RaiserOpcode.BrGeI64Imm,
		RaiserOpcode.BleI64Imm => whenTrue ? RaiserOpcode.BrLeI64Imm : RaiserOpcode.BrGtI64Imm,
		RaiserOpcode.BgtI64Imm => whenTrue ? RaiserOpcode.BrGtI64Imm : RaiserOpcode.BrLeI64Imm,
		RaiserOpcode.BgeI64Imm => whenTrue ? RaiserOpcode.BrGeI64Imm : RaiserOpcode.BrLtI64Imm,
		_ => test,
	};
}

function jumpIfValue(s: RaiserCompState, reg: int32, whenTrue: boolean): int32[] {
	emitInst(s, raiserABC(RaiserOpcode.BTruthy, reg, 0, 1));
	return jumpAfterSkip(s, whenTrue);
}

export function condJumps(s: RaiserCompState, node: Node, whenTrue: boolean): int32[] {
	if (node.kind == NodeKind.UnaryExpr && (node.data as UnaryExprData).unaryOp == "!") {
		return condJumps(s, (node.data as UnaryExprData).operand, !whenTrue);
	}
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isLogicalOp(d.operator)) {
			// the operand that decides the whole condition by itself jumps for `decisive`
			const decisive = d.operator == "||";
			if (whenTrue == decisive) {
				const taken = condJumps(s, d.left, whenTrue);
				for (const j of condJumps(s, d.right, whenTrue)) taken.push(j);
				return taken;
			}
			const past = condJumps(s, d.left, !whenTrue);
			const taken = condJumps(s, d.right, whenTrue);
			patchJumpsTo(s, past, codeLen(s));
			return taken;
		}
		if (isComparisonOp(d.operator)) {
			const refused = refusePointerOp(s, node);
			if (refused >= 0) return jumpIfValue(s, refused, whenTrue);
			const isEqOp = d.operator == "===" || d.operator == "==" || d.operator == "!==" || d.operator == "!=";
			const negated = d.operator == "!==" || d.operator == "!=";
			if (isEqOp && (d.left.kind == NodeKind.NullLiteral || d.right.kind == NodeKind.NullLiteral)) {
				const otherSide: Node = d.left.kind == NodeKind.NullLiteral ? d.right : d.left;
				const valReg = compileExpr(s, otherSide);
				const isNil = allocBool(s);
				emitInst(s, raiserABC(RaiserOpcode.IsKind, isNil, valReg, RaiserValueKind.Nil as number));
				return jumpIfValue(s, isNil, negated ? !whenTrue : whenTrue);
			}
			if (isEqOp && (isPointerTyped(d.left) || isPointerTyped(d.right))) {
				const lReg = compileExpr(s, d.left);
				const rReg = compileExpr(s, d.right);
				const same = allocBool(s);
				emitInst(s, raiserABC(RaiserOpcode.SameLoc, same, lReg, rReg));
				return jumpIfValue(s, same, negated ? !whenTrue : whenTrue);
			}
			const test = compileCompareTest(s, node);
			if (test == null) throw new Error("internal: a comparison operator without a compare-and-skip opcode");
			const branch = branchOpcode(test.op, whenTrue);
			if (branch != test.op) {
				emitInst(s, raiserABC(branch, test.a, test.b, branchField(0)));
				return [codeLen(s) - 1];
			}
			emitInst(s, test);
			return jumpAfterSkip(s, whenTrue);
		}
	}
	return jumpIfValue(s, compileExpr(s, node), whenTrue);
}

function compileBinaryExpr(s: RaiserCompState, node: Node): int32 {
	const refusedOp = refusePointerOp(s, node);
	if (refusedOp >= 0) return refusedOp;
	const d = node.data as BinaryExprData;
	const op = d.operator;
	if (op == "instanceof") return compileInstanceOf(s, node, d);

	// Assignment: x = expr  or  arr[i] = expr
	if (op == "=") {
		const refusedTarget = refusePointerOp(s, d.left);
		if (refusedTarget >= 0) return refusedTarget;
		const assigned = compileValueAssign(s, d.left, d.right);
		if (assigned >= 0) return assigned;
		const through = derefTarget(s, d.left);
		if (through != null) {
			const srcReg = emitValueCopy(s, compileExpr(s, d.right), d.left.nodeType);
			emitInst(s, raiserABC(RaiserOpcode.StoreDeref, compileExpr(s, through), 0, srcReg));
			return srcReg;
		}
		if (isRefParamTarget(d.left)) {
			const msg = "internal: a ref parameter reached the Raiser assignment without its deref";
			queueRaiserCompileError(msg, node.location.line, node.location.column);
			return emitTrapNil(s, msg);
		}
		const startPc = codeLen(s);
		const firstTemp = s.nextReg;
		const srcReg = emitValueCopy(s, compileExpr(s, d.right), d.left.nodeType);
		if (d.left.kind == NodeKind.Identifier) {
			const global = resolveGlobal(s, d.left.resolvedSym);
			if (global >= 0) {
				emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, srcReg, global, 0));
				return srcReg;
			}
			const targetReg = resolveLocal(s, d.left.resolvedSym);
			if (targetReg >= 0) {
				landResult(s, targetReg, startPc, firstTemp, srcReg);
				return targetReg;
			}
		}
		if (d.left.kind == NodeKind.ArrayAccess) {
			const ad = d.left.data as ArrayAccessData;
			const arrReg = compileExpr(s, ad.array);
			const idxReg = compileIndex(s, ad.index);
			emitInst(s, raiserABC(RaiserOpcode.StoreIndex, arrReg, idxReg, srcReg));
			return srcReg;
		}
		if (d.left.kind == NodeKind.MemberExpr) {
			const md = d.left.data as MemberExprData;
			const objReg = compileExpr(s, md.object);
			const nameIdx = addConst(s, raiserConstString(md.property));
			emitInst(s, fieldInst(s, md.object.nodeType, md.property, RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, objReg, nameIdx, srcReg));
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
	if (op == "+" && (exprIsString(s, d.left) || exprIsString(s, d.right))) {
		const lReg = compileStringPart(s, d.left);
		const rReg = compileStringPart(s, d.right);
		const dest = allocRef(s);
		emitInst(s, raiserABC(RaiserOpcode.ConcatStr, dest, lReg, rReg));
		return dest;
	}

	// Null comparison: `expr === null` / `expr !== null` (and `==`/`!=`).
	// BeqI64/BneI64 only compare intVal — Array(handle=0) shares intVal=0 with
	// nil and would compare equal under the generic path. Mirror Nim's opcIsNil
	// and HashLink's OJNotNull: emit a kind-aware check via the dedicated
	// IsKind opcode whenever one side is a NullLiteral.
	const isEqOp = op == "===" || op == "==" || op == "!==" || op == "!=";
	const hasNullLit = d.left.kind == NodeKind.NullLiteral || d.right.kind == NodeKind.NullLiteral;
	if (isEqOp && hasNullLit) {
		const otherSide: Node = d.left.kind == NodeKind.NullLiteral ? d.right : d.left;
		const valReg = compileExpr(s, otherSide);
		const dest = allocBool(s);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, dest, valReg, RaiserValueKind.Nil as number));
		if (op == "===" || op == "==") return dest;
		const negated = allocBool(s);
		emitLogicalNot(s, negated, dest);
		return negated;
	}

	if (isEqOp && (isPointerTyped(d.left) || isPointerTyped(d.right))) {
		const lReg = compileExpr(s, d.left);
		const rReg = compileExpr(s, d.right);
		const dest = allocBool(s);
		emitInst(s, raiserABC(RaiserOpcode.SameLoc, dest, lReg, rReg));
		if (op == "===" || op == "==") return dest;
		const negated = allocBool(s);
		emitLogicalNot(s, negated, dest);
		return negated;
	}

	const test = compileCompareTest(s, node);
	if (test != null) {
		const dest = allocBool(s);
		emitLoadConst(s, dest, raiserBool(true));
		emitInst(s, test);
		emitLoadConst(s, dest, raiserBool(false));
		return dest;
	}

	if ((op == "+" || op == "-") && immLiteral(d.right) && !isFloatExpr(node) && !isUnsignedBand(node.nodeType)) {
		const lhs = compileExpr(s, d.left);
		const result = allocWord(s);
		emitInst(s, raiserABC(op == "+" ? RaiserOpcode.AddI64Imm : RaiserOpcode.SubI64Imm, result, lhs, immField(immLiteralValue(d.right))));
		emitAtWidth(s, result, node.nodeType);
		return result;
	}

	const bitwise = isBitwiseOp(op);
	const lReg = bitwise ? compileBitwiseOperand(s, d.left) : compileExpr(s, d.left);
	const rReg = bitwise ? compileBitwiseOperand(s, d.right) : compileExpr(s, d.right);
	const useFloat = isArithmeticOp(op)
		? isFloatExpr(node)
		: (isFloatExpr(d.left) || isFloatExpr(d.right));
	const hostCall = !bitwise && (op == "**" || (op == "%" && useFloat));
	const dest = hostCall ? allocBlock(s, FLOAT_PAIR_CALL) : useFloat && isArithmeticOp(op) ? allocFloat(s) : allocWord(s);

	// Bitwise operators
	if (bitwise) {
		emitBitwise(s, op, dest, lReg, rReg, node.nodeType);
		return dest;
	}

	if (hostCall) {
		const a1 = dest + 1;
		const a2 = dest + 2;
		emitInst(s, raiserABC(RaiserOpcode.Move, a1, floatOperand(s, lReg), 0));
		emitInst(s, raiserABC(RaiserOpcode.Move, a2, floatOperand(s, rReg), 0));
		const nameIdx = addConst(s, raiserConstString(op == "**" ? "pow" : "fmod"));
		emitInst(s, raiserABC(RaiserOpcode.CallHost, dest, nameIdx, 2));
		const resultCls = convClassOf(node.nodeType);
		if (resultCls >= 0 && resultCls != (RaiserConvClass.F64 as int32)) return emitConvTo(s, dest, resultCls, RaiserConvClass.F64 as int32);
		return dest;
	}

	// Arithmetic
	if (isArithmeticOp(op)) {
		if (useFloat) {
			emitInst(s, raiserABC(arithmeticOpcodeF64(op), dest, floatOperand(s, lReg), floatOperand(s, rReg)));
		} else {
			emitInst(s, raiserABC(unsignedOpcode(arithmeticOpcode(op), node.nodeType), dest, lReg, rReg));
		}
		emitAtWidth(s, dest, node.nodeType);
		return dest;
	}

	const msg = `cannot evaluate operator '${op}' at comptime`;
	queueRaiserCompileError(msg, node.location.line, node.location.column);
	return emitTrapNil(s, msg);
}

// --- Unary ---

function emitLogicalNot(s: RaiserCompState, dest: int32, srcReg: int32): void {
	emitLoadConst(s, dest, raiserBool(false));
	emitInst(s, raiserABC(RaiserOpcode.BTruthy, srcReg, 0, 1));
	emitLoadConst(s, dest, raiserBool(true));
}

function typeofVariants(t: Type | null): Type[] {
	if (t == null) return [];
	if (isMaybeType(t) && t.typeReturn != null) {
		const variants = typeofVariants(t.typeReturn);
		variants.push(nullType());
		return variants;
	}
	if (isTagCarriedUnion(t)) return t.typeChildren.slice(0);
	return [t];
}

function typeofValueKinds(variant: Type, tag: string): int32[] {
	if (variant.kind == TypeKind.Null) return [RaiserValueKind.Nil as int32];
	return match (tag) {
		"number" => [RaiserValueKind.Int as int32, RaiserValueKind.Float as int32],
		"string" => [RaiserValueKind.String as int32],
		"boolean" => [RaiserValueKind.Bool as int32],
		"function" => [RaiserValueKind.Int as int32, RaiserValueKind.Object as int32],
		"object" => [RaiserValueKind.Object as int32, RaiserValueKind.Array as int32, RaiserValueKind.Future as int32],
		_ => [],
	};
}

function compileTypeof(s: RaiserCompState, operand: Node): int32 {
	const valReg = compileExpr(s, operand);
	const opType = operand.nodeType != null ? peelTransparentInstance(operand.nodeType) : null;
	const variants = typeofVariants(opType);
	const kinds: int32[] = [];
	const tags: string[] = [];
	for (const variant of variants) {
		const tag = typeofTagOf(variant);
		const variantKinds = typeofValueKinds(variant, tag);
		if (variantKinds.length == 0 && variants.length > 1) {
			const msg = `cannot evaluate typeof over a union with a '${tag}' variant at comptime: no Raiser value kind carries it`;
			queueRaiserCompileError(msg, operand.location.line, operand.location.column);
			return emitTrapNil(s, msg);
		}
		for (const kind of variantKinds) {
			const at = kinds.indexOf(kind);
			if (at < 0) {
				kinds.push(kind);
				tags.push(tag);
			} else if (tags[at] != tag) {
				const msg = `cannot evaluate typeof at comptime: '${tags[at]}' and '${tag}' variants share Raiser value kind ${kind}`;
				queueRaiserCompileError(msg, operand.location.line, operand.location.column);
				return emitTrapNil(s, msg);
			}
		}
	}
	const dest = allocRef(s);
	const fallback = tags.length > 0 ? tags[tags.length - 1] : typeofTagOf(opType);
	emitLoadConst(s, dest, raiserConstString(fallback));
	const zeroReg = allocWord(s);
	const isKind = allocBool(s);
	emitLoadConst(s, zeroReg, raiserInt(0));
	for (let i = 0; i < kinds.length; i += 1) {
		if (tags[i] == fallback) continue;
		emitInst(s, raiserABC(RaiserOpcode.IsKind, isKind, valReg, kinds[i]));
		emitInst(s, raiserABC(RaiserOpcode.BeqI64, isKind, zeroReg, 1));
		emitLoadConst(s, dest, raiserConstString(tags[i]));
	}
	return dest;
}

function compileUnaryExpr(s: RaiserCompState, node: Node): int32 {
	const d = node.data as UnaryExprData;
	if (d.unaryOp == "typeof") return compileTypeof(s, d.operand);
	const srcReg = d.unaryOp == "~" ? compileBitwiseOperand(s, d.operand) : compileExpr(s, d.operand);
	const dest = allocFor(s, node.nodeType);

	if (d.unaryOp == "-") {
		if (isFloatExpr(node)) {
			emitInst(s, raiserABC(RaiserOpcode.NegF64, dest, srcReg, 0));
		} else {
			emitInst(s, raiserABC(RaiserOpcode.NegI64, dest, srcReg, 0));
			emitAtWidth(s, dest, node.nodeType);
		}
	} else if (d.unaryOp == "~") {
		emitInst(s, raiserABC(RaiserOpcode.BitNot, dest, srcReg, 0));
		const bits = intBandBits(node.nodeType);
		if (bits > 0 && isUnsignedBand(node.nodeType)) emitInst(s, raiserABC(RaiserOpcode.NarrowU, dest, bits, 0));
	} else if (d.unaryOp == "!") {
		emitLogicalNot(s, dest, srcReg);
	} else {
		emitInst(s, raiserABC(RaiserOpcode.Move, dest, srcReg, 0));
	}
	return dest;
}

// --- Logical (short-circuit) ---

function compileLogicalExpr(s: RaiserCompState, node: Node): int32 {
	const d = node.data as BinaryExprData;
	const dest = allocReg(s, joinClass(regClassOf(s, d.left.nodeType), regClassOf(s, d.right.nodeType)));

	// Compile left operand
	compileExprInto(s, d.left, dest);

	if (d.operator == "&&") {
		// a && b: if a is falsy, skip b (result = a)
		const jumpPastB = emitBranchIfFalsy(s, dest);
		compileExprInto(s, d.right, dest);
		patchJumpTo(s, jumpPastB, codeLen(s));
	} else {
		// a || b: if a is falsy, evaluate b. If truthy, skip b.
		const jumpToB = emitBranchIfFalsy(s, dest);
		const jumpPastB = emitJumpPlaceholder(s);
		patchJumpTo(s, jumpToB, codeLen(s));
		compileExprInto(s, d.right, dest);
		patchJumpTo(s, jumpPastB, codeLen(s));
	}

	return dest;
}

// --- Compound assignment ---

function compileCompoundOperand(s: RaiserCompState, op: string, right: Node): int32 {
	return isBitwiseOp(op.slice(0, op.length - 1)) ? compileBitwiseOperand(s, right) : compileExpr(s, right);
}

function compileCompoundAssign(s: RaiserCompState, node: Node): int32 {
	const d = node.data as BinaryExprData;
	const op = d.operator;

	const refusedTarget = refusePointerOp(s, d.left);
	if (refusedTarget >= 0) return refusedTarget;
	const through = derefTarget(s, d.left);
	if (through != null) {
		const ptrReg = compileExpr(s, through);
		const tmpReg = allocFor(s, d.left.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.LoadDeref, tmpReg, ptrReg, 0));
		const strConcat = op == "+=" && (exprIsString(s, d.left) || exprIsString(s, d.right));
		const rhsReg = strConcat ? compileStringPart(s, d.right) : compileExpr(s, d.right);
		if (strConcat) {
			emitInst(s, raiserABC(RaiserOpcode.ConcatStr, tmpReg, tmpReg, rhsReg));
		} else {
			emitCompoundArith(s, op, tmpReg, tmpReg, rhsReg, d.left);
		}
		emitInst(s, raiserABC(RaiserOpcode.StoreDeref, ptrReg, 0, tmpReg));
		return tmpReg;
	}

	if (d.left.kind == NodeKind.Identifier) {
		const global = resolveGlobal(s, d.left.resolvedSym);
		const targetReg = global >= 0 ? compileExpr(s, d.left) : resolveLocal(s, d.left.resolvedSym);
		if (targetReg >= 0) {
			const strConcat = op == "+=" && (exprIsString(s, d.left) || exprIsString(s, d.right));
			const rhsReg = strConcat ? compileStringPart(s, d.right) : compileCompoundOperand(s, op, d.right);
			// String concat: += on string variable
			if (strConcat) {
				emitInst(s, raiserABC(RaiserOpcode.ConcatStr, targetReg, targetReg, rhsReg));
			} else {
				emitCompoundArith(s, op, targetReg, targetReg, rhsReg, d.left);
			}
			if (global >= 0) emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, targetReg, global, 0));
			return targetReg;
		}
	}

	// Compound assign on member: obj.field += val → LoadField + op + StoreField
	if (d.left.kind == NodeKind.MemberExpr) {
		const md = d.left.data as MemberExprData;
		const objReg = compileExpr(s, md.object);
		const nameIdx = addConst(s, raiserConstString(md.property));
		const tmpReg = allocFor(s, d.left.nodeType);
		emitInst(s, fieldInst(s, md.object.nodeType, md.property, RaiserOpcode.LoadField, RaiserOpcode.LoadSlot, tmpReg, objReg, nameIdx));
		const strConcat = op == "+=" && (exprIsString(s, d.left) || exprIsString(s, d.right));
		const rhsReg = strConcat ? compileStringPart(s, d.right) : compileCompoundOperand(s, op, d.right);
		if (strConcat) {
			emitInst(s, raiserABC(RaiserOpcode.ConcatStr, tmpReg, tmpReg, rhsReg));
		} else {
			emitCompoundArith(s, op, tmpReg, tmpReg, rhsReg, d.left);
		}
		emitInst(s, fieldInst(s, md.object.nodeType, md.property, RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, objReg, nameIdx, tmpReg));
		return tmpReg;
	}

	// Compound assign on array: arr[i] += val → LoadIndex + op + StoreIndex
	if (d.left.kind == NodeKind.ArrayAccess) {
		const ad = d.left.data as ArrayAccessData;
		const arrReg = compileExpr(s, ad.array);
		const idxReg = compileIndex(s, ad.index);
		const tmpReg = allocFor(s, d.left.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.LoadIndex, tmpReg, arrReg, idxReg));
		const rhsReg = compileCompoundOperand(s, op, d.right);
		emitCompoundArith(s, op, tmpReg, tmpReg, rhsReg, d.left);
		emitInst(s, raiserABC(RaiserOpcode.StoreIndex, arrReg, idxReg, tmpReg));
		return tmpReg;
	}

	// Fallback: unsupported compound assign target
	const caMsg = "cannot compile compound assignment target: unsupported by the Raiser bytecode compiler";
	queueRaiserCompileError(caMsg, node.location.line, node.location.column);
	return emitTrapNil(s, caMsg);
}

// --- Call ---

// Allocate `args.length` slots after `dest`, compile each arg, and emit Move
// instructions to land each result in its expected callee slot. Shared by
// CallHost (extern) and direct user-function-call paths since both follow
// the same calling convention (args sit at dest+1 .. dest+argCount).
function hostValues(args: Node[]): Node[] {
	const values: Node[] = [];
	for (const a of args) values.push(a.kind == NodeKind.HiddenAddr ? (a.data as HiddenDerefData).expr : a);
	return values;
}

function callBlock(s: RaiserCompState, resultType: Type | null, args: Node[], params: Type[] | null): int32 {
	const classes: RaiserRegClass[] = [regClassOf(s, resultType)];
	for (let i = 0; i < args.length; i = i + 1) {
		const declared = params != null && i < params.length ? params[i] : null;
		classes.push(regClassOf(s, declared != null ? declared : args[i].nodeType));
	}
	return allocBlock(s, classes);
}

function calleeParamTypes(sym: Symbol | null): Type[] | null {
	if (sym == null) return null;
	const declared = placedInstanceOf(sym).symbolType;
	return declared != null && declared.kind == TypeKind.Function ? declared.typeChildren : null;
}

function emitCallArgs(s: RaiserCompState, dest: number, args: Node[]): void {
	for (let i = 0; i < args.length; i = i + 1) {
		compileExprInto(s, args[i], dest + 1 + i);
	}
}

function emitIntConst(s: RaiserCompState, value: int64): int32 {
	const reg = allocWord(s);
	emitLoadConst(s, reg, raiserInt(value));
	return reg;
}

function emitIntBinary(s: RaiserCompState, op: RaiserOpcode, left: int32, right: int32): int32 {
	const reg = allocWord(s);
	emitInst(s, raiserABC(op, reg, left, right));
	return reg;
}

function emitNarrowU32(s: RaiserCompState, value: int32): int32 {
	const reg = allocWord(s);
	emitInst(s, raiserABC(RaiserOpcode.Move, reg, value, 0));
	emitInst(s, raiserABC(RaiserOpcode.NarrowU, reg, 32, 0));
	return reg;
}

function emitSetCard32(s: RaiserCompState, value: int32): int32 {
	const one = emitIntConst(s, 1);
	const two = emitIntConst(s, 2);
	const four = emitIntConst(s, 4);
	const twentyFour = emitIntConst(s, 24);
	const mask1 = emitIntConst(s, 0x55555555);
	const mask2 = emitIntConst(s, 0x33333333);
	const mask4 = emitIntConst(s, 0x0F0F0F0F);
	const multiplier = emitIntConst(s, 0x01010101);
	const shifted1 = emitIntBinary(s, RaiserOpcode.ShiftRightU, value, one);
	const paired = emitIntBinary(s, RaiserOpcode.BitAnd, shifted1, mask1);
	let word = emitNarrowU32(s, emitIntBinary(s, RaiserOpcode.SubI64, value, paired));
	const lowPairs = emitIntBinary(s, RaiserOpcode.BitAnd, word, mask2);
	const shifted2 = emitIntBinary(s, RaiserOpcode.ShiftRightU, word, two);
	const highPairs = emitIntBinary(s, RaiserOpcode.BitAnd, shifted2, mask2);
	word = emitNarrowU32(s, emitIntBinary(s, RaiserOpcode.AddI64, lowPairs, highPairs));
	const shifted4 = emitIntBinary(s, RaiserOpcode.ShiftRightU, word, four);
	word = emitIntBinary(s, RaiserOpcode.BitAnd, emitIntBinary(s, RaiserOpcode.AddI64, word, shifted4), mask4);
	word = emitNarrowU32(s, emitIntBinary(s, RaiserOpcode.MulI64, word, multiplier));
	return emitIntBinary(s, RaiserOpcode.ShiftRightU, word, twentyFour);
}

function compileSetSizeCall(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const value = compileExpr(s, d.arguments[0]);
	const repr = setRepr(d.arguments[0].nodeType);
	if (repr != null && repr.kind == TypeKind.SizedArray) {
		let total = emitIntConst(s, 0);
		for (let i = 0; i < repr.typeValue; i += 1) {
			const word = allocWord(s);
			emitInst(s, raiserABC(RaiserOpcode.LoadIndex, word, value, emitIntConst(s, i)));
			total = emitIntBinary(s, RaiserOpcode.AddI64, total, emitSetCard32(s, word));
		}
		return total;
	}
	const low = emitSetCard32(s, value);
	if (repr == null || repr.kind != TypeKind.Uint64) return low;
	const high = emitIntBinary(s, RaiserOpcode.ShiftRightU, value, emitIntConst(s, 32));
	return emitIntBinary(s, RaiserOpcode.AddI64, low, emitSetCard32(s, high));
}

function emitCarry(s: RaiserCompState, sum: int32, addend: int32): int32 {
	const carry = emitIntConst(s, 1);
	emitInst(s, raiserABC(RaiserOpcode.BltU64, sum, addend, 1));
	emitLoadConst(s, carry, raiserInt(0));
	return carry;
}

function compileHiXorLoCall(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const a = compileExpr(s, d.arguments[0]);
	const b = compileExpr(s, d.arguments[1]);
	const half = emitIntConst(s, 32);
	const lowMask = emitIntConst(s, 0xFFFFFFFF);
	const aHigh = emitIntBinary(s, RaiserOpcode.ShiftRightU, a, half);
	const aLow = emitIntBinary(s, RaiserOpcode.BitAnd, a, lowMask);
	const bHigh = emitIntBinary(s, RaiserOpcode.ShiftRightU, b, half);
	const bLow = emitIntBinary(s, RaiserOpcode.BitAnd, b, lowMask);
	const highHigh = emitIntBinary(s, RaiserOpcode.MulU64, aHigh, bHigh);
	const highLow = emitIntBinary(s, RaiserOpcode.MulU64, aHigh, bLow);
	const lowHigh = emitIntBinary(s, RaiserOpcode.MulU64, aLow, bHigh);
	const lowLow = emitIntBinary(s, RaiserOpcode.MulU64, aLow, bLow);
	const partial = emitIntBinary(s, RaiserOpcode.AddU64, lowLow,
		emitIntBinary(s, RaiserOpcode.ShiftLeft, highLow, half));
	const firstCarry = emitCarry(s, partial, lowLow);
	const low = emitIntBinary(s, RaiserOpcode.AddU64, partial,
		emitIntBinary(s, RaiserOpcode.ShiftLeft, lowHigh, half));
	const secondCarry = emitCarry(s, low, partial);
	let high = emitIntBinary(s, RaiserOpcode.AddU64, highHigh,
		emitIntBinary(s, RaiserOpcode.ShiftRightU, highLow, half));
	high = emitIntBinary(s, RaiserOpcode.AddU64, high,
		emitIntBinary(s, RaiserOpcode.ShiftRightU, lowHigh, half));
	high = emitIntBinary(s, RaiserOpcode.AddU64, high, firstCarry);
	high = emitIntBinary(s, RaiserOpcode.AddU64, high, secondCarry);
	return emitIntBinary(s, RaiserOpcode.BitXor, high, low);
}

function namespaceMemberIdent(node: Node): Node | null {
	if (node.kind != NodeKind.MemberExpr || node.resolvedSym == null) return null;
	const d = node.data as MemberExprData;
	const ns = d.object.resolvedSym;
	const nsIdent = ns != null && ns.symbolKind == SymbolKind.Module;
	if (!nsIdent && (d.object.nodeType == null || d.object.nodeType.kind != TypeKind.Module)) return null;
	const ident = createNodeAt(NodeKind.Identifier, { name: `${nsIdent ? ns.name : "$ns"}.${d.property}` }, node.location);
	ident.resolvedSym = node.resolvedSym;
	ident.nodeType = node.nodeType;
	ident.flags = node.flags;
	return ident;
}

function compileNamespaceObject(s: RaiserCompState, member: Node): void {
	const object = (member.data as MemberExprData).object;
	if (object.kind != NodeKind.Identifier) compileExpr(s, object);
}

function compileCallExpr(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const nsCallee = namespaceMemberIdent(d.callee);
	if (nsCallee != null) {
		compileNamespaceObject(s, d.callee);
		const written = d.callee;
		d.callee = nsCallee;
		const result = compileCallExpr(s, node);
		d.callee = written;
		return result;
	}

	// arr.push(val)
	if (isArrayPush(d.callee)) {
		return compileArrayPushCall(s, node);
	}

	// arr.setLength(n) — arrays only; strings fall through (their setLength
	// is a C-backend in-place mutation with no comptime meaning).
	if (isArraySetLengthCall(s, d.callee) && d.arguments.length == 1) {
		return compileArraySetLenCall(s, node);
	}

	// x.toString()
	if (isToStringCall(d.callee) && d.arguments.length == 0) {
		return compileToStringCall(s, node);
	}

	const builtinKind = callBuiltinKind(node);
	// exit(code) / process.exit(code) is a Tier-0 concern: halt the VM with the code.
	if (builtinKind == "Exit" && d.arguments.length <= 1) {
		return compileExitCall(s, node);
	}
	if ((builtinKind == "UnionText" || builtinKind == "UnionDebug") && d.arguments.length >= 1) {
		return compileTextOf(s, d.arguments[0]);
	}
	if (builtinKind == "MapFatal" && d.arguments.length == 1) {
		return compileMapFatalCall(s, node);
	}
	if (builtinKind == "SetSize" && d.arguments.length == 1) {
		return compileSetSizeCall(s, node);
	}
	if (builtinKind == "HiXorLo" && d.arguments.length == 2) {
		return compileHiXorLoCall(s, node);
	}
	if (builtinKind == "Float64Bits" && d.arguments.length == 1) {
		const value = compileExpr(s, d.arguments[0]);
		return emitConvTo(s, value, RaiserConvClass.F64Bits as int32, RaiserConvClass.F64 as int32);
	}
	if (builtinKind == "PtrBits" && d.arguments.length == 1) {
		return emitConvTo(s, compileExpr(s, d.arguments[0]), RaiserConvClass.HandleBits as int32, -1);
	}

	// spawn(fn) / sleepAsync(ms) / waitFor(h) / Promise.resolve(v) and the
	// Promise.all / race / any combinators — the async surface the VM owns as
	// opcodes. Keyed on builtinKind (set from the @builtin decorator in
	// std/core/promise), never on the name.
	const asyncKind = builtinKind;
	if (asyncKind == "PromiseSpawn" && d.arguments.length == 1) {
		const closureReg = compileExpr(s, d.arguments[0]);
		const dest = allocRef(s);
		emitInst(s, raiserABC(RaiserOpcode.Spawn, dest, closureReg, 0));
		return dest;
	}
	if (asyncKind == "SleepAsync" && d.arguments.length == 1) {
		const delayReg = compileExpr(s, d.arguments[0]);
		const dest = allocRef(s);
		emitInst(s, raiserABC(RaiserOpcode.Sleep, dest, delayReg, 0));
		return dest;
	}
	if (builtinKind == "ModuleImport" && d.arguments.length == 1 && d.arguments[0].kind == NodeKind.StringLiteral) {
		const dest = allocFor(s, node.nodeType);
		const name = addConst(s, raiserConstString((d.arguments[0].data as StringLiteralData).value));
		emitInst(s, raiserABx(RaiserOpcode.ModuleImport, dest, name));
		return dest;
	}
	if (asyncKind == "PromisePending") {
		const dest = allocRef(s);
		emitInst(s, raiserABC(RaiserOpcode.FutureNew, dest, 0, 0));
		return dest;
	}
	if (asyncKind == "PromiseReject" && d.arguments.length == 1) {
		const errorReg = compileExpr(s, d.arguments[0]);
		const dest = allocRef(s);
		emitInst(s, raiserABC(RaiserOpcode.FutureNew, dest, 0, 0));
		emitInst(s, raiserABC(RaiserOpcode.FutureFail, dest, errorReg, 0));
		return dest;
	}
	if ((asyncKind == "PromiseSettle" || asyncKind == "PromiseFail") && d.arguments.length >= 1) {
		const futReg = compileExpr(s, d.arguments[0]);
		let valueReg = 0;
		if (d.arguments.length > 1 && (d.arguments[1].nodeType == null || d.arguments[1].nodeType!.kind != TypeKind.Void)) {
			valueReg = compileExpr(s, d.arguments[1]);
		} else {
			valueReg = allocRef(s);
			emitLoadConst(s, valueReg, raiserNil());
		}
		emitInst(s, raiserABC(asyncKind == "PromiseSettle" ? RaiserOpcode.FutureSettle : RaiserOpcode.FutureFail, futReg, valueReg, 0));
		return futReg;
	}
	const combine = combineOf(asyncKind);
	const combineArity = combine == (RaiserCombine.Any as int32) ? 2 : 1;
	if (combine >= 0 && d.arguments.length == combineArity) {
		const dest = callBlock(s, node.nodeType, d.arguments, null);
		emitCallArgs(s, dest, d.arguments);
		emitInst(s, raiserABC(RaiserOpcode.FutureCombine, dest, combine, d.arguments.length));
		return dest;
	}
	if (asyncKind == "PromiseResolve" && d.arguments.length == 1) {
		// Await reads a finished future as its value, so a future that starts
		// finished is indistinguishable from the value itself.
		return compileExpr(s, d.arguments[0]);
	}

	// str.charAt(i)
	if (isStringMethod(s, d.callee, "charAt") && d.arguments.length == 1) {
		return compileStrCharAt(s, node);
	}

	// str.slice(start, end)
	if (isStringMethod(s, d.callee, "slice") && d.arguments.length == 2) {
		return compileStrSlice(s, node);
	}

	if (isConsoleLog(d.callee)) {
		if (d.arguments.length <= 1) {
			let lastReg = 0;
			for (let i = 0; i < d.arguments.length; i = i + 1) {
				lastReg = compileStringPart(s, d.arguments[i]);
				emitInst(s, raiserABC(RaiserOpcode.Print, lastReg, 0, 0));
			}
			return lastReg;
		}
		const acc = compileEchoLine(s, d.arguments);
		emitInst(s, raiserABC(RaiserOpcode.Print, acc, 0, 0));
		return acc;
	}

	if (isConsoleStderr(d.callee)) {
		const dest = allocBlock(s, [RaiserRegClass.Ref, RaiserRegClass.Ref]);
		const lineReg = dest + 1;
		const line = compileEchoLine(s, d.arguments);
		if (line != lineReg) emitInst(s, raiserABC(RaiserOpcode.Move, lineReg, line, 0));
		const nameIdx = addConst(s, raiserConstString("msEprintln"));
		emitInst(s, raiserABC(RaiserOpcode.CallHost, dest, nameIdx, 1));
		return dest;
	}

	// Generic native call: any callee resolved to a Symbol with nativeName
	// (extern decl) becomes a CallHost lookup at the registered name. New
	// stdlib externs need zero codegen edits — they self-register through
	// hostTable.ms which feeds the registry consulted at dispatch time.
	// An extern nobody registered would only die at runtime ("Unknown host
	// function") — catch it here, at the call site, with a span.
	if (d.callee.kind == NodeKind.Identifier && d.callee.resolvedSym != null) {
		const sym = d.callee.resolvedSym;
		const hostName = runtimeHostName(sym);
		if (hostName != "") {
			if (sym.nativeName != "") checkHostBridgeCoverage(sym, d.callee);
			const hostArgs = hostValues(d.arguments);
			const dest = callBlock(s, node.nodeType, hostArgs, null);
			emitCallArgs(s, dest, hostArgs);
			const nameIdx = addConst(s, raiserConstString(hostName));
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
	if (d.callee.kind == NodeKind.MemberExpr && d.callee.resolvedSym != null) {
		const sym = d.callee.resolvedSym;
		if (sym.nativeName != "") {
			checkHostBridgeCoverage(sym, d.callee);
			const isStatic = node.flags.has(NodeFlag.ExtStatic);
			const md = d.callee.data as MemberExprData;
			const allArgs: Node[] = [];
			if (!isStatic) allArgs.push(md.object);
			for (const a of d.arguments) { allArgs.push(a); }
			const hostArgs = hostValues(allArgs);
			const dest = callBlock(s, node.nodeType, hostArgs, null);
			emitCallArgs(s, dest, hostArgs);
			const nameIdx = addConst(s, raiserConstString(sym.nativeName));
			emitInst(s, raiserABC(RaiserOpcode.CallHost, dest, nameIdx, allArgs.length));
			return dest;
		}
	}

	// User function call: callee must be Identifier
	if (d.callee.kind == NodeKind.Identifier) {
		const calleeId = d.callee.data as IdentifierData;
		if (calleeId.name == "super" && d.callee.resolvedSym != null
				&& (d.callee.resolvedSym.symbolKind == SymbolKind.Class || d.callee.resolvedSym.symbolKind == SymbolKind.Function)) {
			return compileSuperCall(s, node, d.callee.resolvedSym);
		}
		if (resolveGlobal(s, d.callee.resolvedSym) >= 0 || resolveLocal(s, d.callee.resolvedSym) >= 0) return compileClosureCall(s, node);
		let calleeSym = d.callee.resolvedSym;
		if (calleeSym != null && calleeSym.overloads != null && calleeSym.overloads.length > 0) {
			calleeSym = resolveOverloadWinner(calleeSym, d.resolvedOverloadIdx).winnerSym;
		}
		const funcIdx = routineIndex(s, calleeSym);
		if (funcIdx >= 0) {
			const dest = callBlock(s, node.nodeType, d.arguments, calleeParamTypes(calleeSym));
			emitCallArgs(s, dest, d.arguments);
			const pastBase = d.arguments.length > 0 ? emitOverrideCalls(s, node, dest, dispatchOverrides(calleeSym)) : [];
			emitInst(s, raiserABC(RaiserOpcode.Call, dest, funcIdx, d.arguments.length));
			patchJumpsTo(s, pastBase, codeLen(s));
			return dest;
		}
	}

	// Closure / indirect call: callee is a variable holding {fn, env} pair
	return compileClosureCall(s, node);
}

function compileSuperCall(s: RaiserCompState, node: Node, superSym: Symbol): int32 {
	const d = node.data as CallExprData;
	let initName = superSym.name;
	let funcIdx = -1;
	let parent: Symbol | null = null;
	if (superSym.symbolKind == SymbolKind.Function) {
		funcIdx = resolveRoutine(s, superSym);
		const fnType = superSym.symbolType;
		const self = fnType != null && fnType.typeChildren.length > 0 ? unwrapRef(fnType.typeChildren[0]) : null;
		parent = self != null ? self.sym : null;
	} else {
		const body = superSym.symbolType != null ? unwrapRef(superSym.symbolType) : null;
		parent = body != null && body.sym != null ? body.sym : superSym;
		initName = parent.name + "_init";
		funcIdx = resolveClassInit(s, parent);
	}
	if (funcIdx < 0 && parent != null && callRaiserOnDemand(parent) >= 0) funcIdx = resolveClassInit(s, parent);
	const thisReg = s.receiverReg;
	if (funcIdx < 0 || thisReg < 0) {
		const msg = `cannot compile 'super(...)': no '${initName}' in the Raiser function table`;
		queueRaiserCompileError(msg, node.location.line, node.location.column);
		return emitTrapNil(s, msg);
	}
	const superClasses: RaiserRegClass[] = [RaiserRegClass.Ref, RaiserRegClass.Ref];
	for (const a of d.arguments) superClasses.push(regClassOf(s, a.nodeType));
	const dest = allocBlock(s, superClasses);
	emitInst(s, raiserABC(RaiserOpcode.Move, dest + 1, thisReg, 0));
	for (let i = 0; i < d.arguments.length; i += 1) compileExprInto(s, d.arguments[i], dest + 2 + i);
	emitInst(s, raiserABC(RaiserOpcode.Call, dest, funcIdx, d.arguments.length + 1));
	return dest;
}

function routineIndex(s: RaiserCompState, sym: Symbol | null): int32 {
	const funcIdx = resolveRoutine(s, sym);
	return funcIdx < 0 && sym != null ? callRaiserOnDemand(sym) : funcIdx;
}

function dispatchOverrides(sym: Symbol | null): Symbol[] {
	const entry = sym != null ? dispatchEntryFor(sym) : null;
	if (entry == null || entry.overloaded) return [];
	return dispatchOverridesFor(entry.classSym, entry.methodName).map((e) => e.sym);
}

// The receiver's class picks the override, deepest class first, as the C
// backend's dispatcher does; the base call the caller emits next is the fallthrough.
function emitOverrideCalls(s: RaiserCompState, node: Node, dest: int32, overrides: Symbol[]): int32[] {
	const argCount = (node.data as CallExprData).arguments.length;
	const ends: int32[] = [];
	for (const ov of overrides) {
		const ft = ov.symbolType;
		const receiver = ft != null && ft.typeChildren.length > 0 ? ft.typeChildren[0] : null;
		const key = classTargetKey(receiver);
		const funcIdx = routineIndex(s, ov);
		if (key == "" || funcIdx < 0) {
			queueRaiserCompileError(`internal: the override '${ov.name}' has no ${key == "" ? "receiver class" : "Raiser routine"}`, node.location.line, node.location.column);
			continue;
		}
		const isOv = allocBool(s);
		emitInst(s, raiserABC(RaiserOpcode.InstanceOf, isOv, dest + 1, classTargetOperand(s, receiver, key)));
		const next = emitBranchIfFalsy(s, isOv);
		emitInst(s, raiserABC(RaiserOpcode.Call, dest, funcIdx, argCount));
		ends.push(emitJumpPlaceholder(s));
		patchJumpTo(s, next, codeLen(s));
	}
	return ends;
}

function compileClosureCall(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const closureReg = compileExpr(s, d.callee);

	let argCount = 0;
	for (const a of d.arguments) {
		if (a.nodeType == null || a.nodeType.kind != TypeKind.Void) argCount = argCount + 1;
	}
	const calleeType = skipModifier(d.callee.nodeType);
	const declaredParams = calleeType != null && calleeType.kind == TypeKind.Function ? calleeType.typeChildren : null;
	const closureClasses: RaiserRegClass[] = [regClassOf(s, node.nodeType)];
	for (let i = 0; i < d.arguments.length; i = i + 1) {
		if (d.arguments[i].nodeType != null && d.arguments[i].nodeType!.kind == TypeKind.Void) continue;
		const declared = declaredParams != null && i < declaredParams.length ? declaredParams[i] : null;
		closureClasses.push(regClassOf(s, declared != null ? declared : d.arguments[i].nodeType));
	}
	closureClasses.push(RaiserRegClass.Ref);
	const dest = allocBlock(s, closureClasses);
	let slot = 0;
	for (let i = 0; i < d.arguments.length; i = i + 1) {
		if (d.arguments[i].nodeType != null && d.arguments[i].nodeType!.kind == TypeKind.Void) {
			if (d.arguments[i].kind != NodeKind.Identifier) compileExpr(s, d.arguments[i]);
			continue;
		}
		compileExprInto(s, d.arguments[i], dest + 1 + slot);
		slot = slot + 1;
	}
	emitInst(s, raiserABC(RaiserOpcode.CallClosure, dest, closureReg, argCount + 1));
	return dest;
}

// --- Conditional (ternary) ---

function compileConditionalExpr(s: RaiserCompState, node: Node): int32 {
	const d = node.data as ConditionalExprData;
	const dest = allocReg(s, joinClass(regClassOf(s, d.ternaryConsequent.nodeType), regClassOf(s, d.ternaryAlternate.nodeType)));

	const toAlt = condJumps(s, d.ternaryCondition, false);

	// Consequent
	compileExprInto(s, d.ternaryConsequent, dest);
	const jumpPastAlt = emitJumpPlaceholder(s);

	// Alternate
	patchJumpsTo(s, toAlt, codeLen(s));
	compileExprInto(s, d.ternaryAlternate, dest);

	patchJumpTo(s, jumpPastAlt, codeLen(s));
	return dest;
}

// --- Update (i++, ++i, i--, --i) ---

function emitStep(s: RaiserCompState, dest: int32, fromReg: int32, updateOp: string, target: Node): void {
	if (!isFloatExpr(target) && !isUnsignedBand(target.nodeType)) {
		emitInst(s, raiserABC(updateOp == "++" ? RaiserOpcode.AddI64Imm : RaiserOpcode.SubI64Imm, dest, fromReg, immField(1)));
		emitAtWidth(s, dest, target.nodeType);
	} else {
		const oneReg = isFloatExpr(target) ? allocFloat(s) : allocWord(s);
		emitLoadConst(s, oneReg, isFloatExpr(target) ? raiserFloat(1.0) : raiserInt(1));
		emitCompoundArith(s, updateOp == "++" ? "+=" : "-=", dest, fromReg, oneReg, target);
	}
	if (target.nodeType != null && peelDistinct(target.nodeType).kind == TypeKind.Char) emitInst(s, raiserABC(RaiserOpcode.NarrowS, dest, 8, 1));
}

function emitStepped(s: RaiserCompState, fromReg: int32, updateOp: string, target: Node): int32 {
	const outReg = isFloatExpr(target) ? allocFloat(s) : allocWord(s);
	emitStep(s, outReg, fromReg, updateOp, target);
	return outReg;
}

// A result nobody reads makes `i++` the same step as `++i`: no old value is kept.
export function compileExprForEffect(s: RaiserCompState, node: Node): void {
	if (node.kind == NodeKind.UpdateExpr) compileUpdateExpr(s, node, true);
	else compileExpr(s, node);
}

function compileUpdateExpr(s: RaiserCompState, node: Node, resultUnused: boolean): int32 {
	const refusedOp = refusePointerOp(s, node);
	if (refusedOp >= 0) return refusedOp;
	const d = node.data as UpdateExprData;

	const refusedTarget = refusePointerOp(s, d.updateArg);
	if (refusedTarget >= 0) return refusedTarget;
	const through = derefTarget(s, d.updateArg);
	if (through != null) {
		const ptrReg = compileExpr(s, through);
		const oldReg = allocFor(s, d.updateArg.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.LoadDeref, oldReg, ptrReg, 0));
		const newReg = emitStepped(s, oldReg, d.updateOp, d.updateArg);
		emitInst(s, raiserABC(RaiserOpcode.StoreDeref, ptrReg, 0, newReg));
		return d.isPrefix ? newReg : oldReg;
	}

	if (d.updateArg.kind == NodeKind.Identifier) {
		const global = resolveGlobal(s, d.updateArg.resolvedSym);
		const varReg = global >= 0 ? compileExpr(s, d.updateArg) : resolveLocal(s, d.updateArg.resolvedSym);
		if (varReg >= 0) {
			if (d.isPrefix || resultUnused) {
				// ++i / --i: modify first, return modified
				emitStep(s, varReg, varReg, d.updateOp, d.updateArg);
				if (global >= 0) emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, varReg, global, 0));
				return varReg;
			} else {
				// i++ / i--: save old value, then modify
				const oldReg = allocReg(s, classOfReg(s, varReg));
				emitInst(s, raiserABC(RaiserOpcode.Move, oldReg, varReg, 0));
				emitStep(s, varReg, varReg, d.updateOp, d.updateArg);
				if (global >= 0) emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, varReg, global, 0));
				return oldReg;
			}
		}
	}

	if (d.updateArg.kind == NodeKind.MemberExpr) {
		const md = d.updateArg.data as MemberExprData;
		const objReg = compileExpr(s, md.object);
		const nameIdx = addConst(s, raiserConstString(md.property));
		const oldReg = allocFor(s, d.updateArg.nodeType);
		emitInst(s, fieldInst(s, md.object.nodeType, md.property, RaiserOpcode.LoadField, RaiserOpcode.LoadSlot, oldReg, objReg, nameIdx));
		const newReg = emitStepped(s, oldReg, d.updateOp, d.updateArg);
		emitInst(s, fieldInst(s, md.object.nodeType, md.property, RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, objReg, nameIdx, newReg));
		return d.isPrefix ? newReg : oldReg;
	}

	if (d.updateArg.kind == NodeKind.ArrayAccess) {
		const ad = d.updateArg.data as ArrayAccessData;
		const arrReg = compileExpr(s, ad.array);
		const idxReg = compileIndex(s, ad.index);
		const oldReg = allocFor(s, d.updateArg.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.LoadIndex, oldReg, arrReg, idxReg));
		const newReg = emitStepped(s, oldReg, d.updateOp, d.updateArg);
		emitInst(s, raiserABC(RaiserOpcode.StoreIndex, arrReg, idxReg, newReg));
		return d.isPrefix ? newReg : oldReg;
	}

	// Fallback: unsupported update target
	const upMsg = "cannot compile update target: unsupported by the Raiser bytecode compiler";
	queueRaiserCompileError(upMsg, node.location.line, node.location.column);
	return emitTrapNil(s, upMsg);
}

// --- Object ---

function compileObjectLiteral(s: RaiserCompState, node: Node): int32 {
	const d = node.data as ObjectLiteralData;
	const dest = allocRef(s);

	emitObjectShell(s, dest, node.nodeType);

	// Set each field
	for (let i = 0; i < d.keys.length; i = i + 1) {
		const fieldType = node.nodeType != null
			? getProperty(node.nodeType, d.keys[i]) : d.properties[i].nodeType;
		const valReg = emitValueCopy(s, compileExpr(s, d.properties[i]), fieldType);
		const nameIdx = addConst(s, raiserConstString(d.keys[i]));
		emitInst(s, fieldInst(s, node.nodeType, d.keys[i], RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, dest, nameIdx, valReg));
	}
	if (d.keys.length == d.properties.length) emitOmittedFieldZeros(s, dest, node.nodeType, d.keys);

	return dest;
}

// --- New ---

function compileNewArray(s: RaiserCompState, node: Node, arrayType: Type): int32 {
	const d = node.data as NewExprData;
	const array = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.NewArray, array, 0, 0));
	if (d.newArguments.length == 1) {
		const count = allocWord(s);
		emitInst(s, raiserABC(RaiserOpcode.Conv, count, compileExpr(s, d.newArguments[0]), RaiserConvClass.I64));
		emitInst(s, raiserABC(RaiserOpcode.ArraySetLen, array, count, 1));
		emitZeroFill(s, array, count, arrayType.typeReturn);
	}
	return array;
}

function compileNewExpr(s: RaiserCompState, node: Node): int32 {
	const d = node.data as NewExprData;

	const arrayType = zeroArrayType(node.nodeType);
	if (arrayType != null && d.newArguments.length <= 1) return compileNewArray(s, node, arrayType);

	const nsCallee = namespaceMemberIdent(d.newCallee);
	const newCallee = nsCallee != null ? nsCallee : d.newCallee;
	if (newCallee.kind == NodeKind.Identifier) {
		const classId = newCallee.data as IdentifierData;
		const sym = newCallee.resolvedSym;
		let funcIdx = sym != null ? resolveConstructor(s, sym) : -1;
		if (funcIdx < 0 && sym != null) funcIdx = callRaiserOnDemand(sym);
		if (funcIdx >= 0) {
			const knownCtorless = sym != null && !sym.symFlags.has(SymbolFlag.HasConstructor);
			let callArgs: Node[] = d.newArguments;
			if (knownCtorless && d.newArguments.length > 0) {
				queueRaiserCompileError(
					`new ${classId.name}: positional arguments on a class without a constructor reached codegen unlowered — they would be dropped`,
					node.location.line, node.location.column);
				callArgs = [];
			}
			const dest = callBlock(s, node.nodeType, callArgs, null);
			emitCallArgs(s, dest, callArgs);
			emitInst(s, raiserABC(RaiserOpcode.Call, dest, funcIdx, callArgs.length));
			return dest;
		}
	}

	const newMsg = "cannot compile 'new' here: no matching constructor in the Raiser function table";
	queueRaiserCompileError(newMsg, node.location.line, node.location.column);
	return emitTrapNil(s, newMsg);
}

// --- Array ---

function compileArrayLiteral(s: RaiserCompState, node: Node): int32 {
	const d = node.data as ArrayLiteralData;
	for (const e of d.elements) {
		if (e.kind == NodeKind.SpreadExpr) return compileSpreadArrayLiteral(s, node);
	}
	const elemCount = d.elements.length;

	// Reserve dest + N element slots upfront
	const elementClasses: RaiserRegClass[] = [RaiserRegClass.Ref];
	for (let slotIdx = 0; slotIdx < elemCount; slotIdx = slotIdx + 1) {
		const held = node.nodeType != null ? getElementType(unwrapRef(node.nodeType)) : d.elements[slotIdx].nodeType;
		elementClasses.push(regClassOf(s, held));
	}
	const dest = allocBlock(s, elementClasses);

	// Compile each element, move result to its slot
	for (let i = 0; i < elemCount; i = i + 1) {
		const elementType = node.nodeType != null
			? getElementType(unwrapRef(node.nodeType)) : d.elements[i].nodeType;
		const elemReg = emitValueCopy(s, compileExpr(s, d.elements[i]), elementType);
		const targetReg = dest + 1 + i;
		if (elemReg != targetReg) {
			emitInst(s, raiserABC(RaiserOpcode.Move, targetReg, elemReg, 0));
		}
	}

	emitInst(s, raiserABC(RaiserOpcode.NewArray, dest, elemCount, 0));
	const sized = node.nodeType != null ? unwrapRef(node.nodeType) : null;
	if (sized != null && sized.kind == TypeKind.SizedArray && sized.typeValue > elemCount) {
		const tail = allocWord(s);
		emitLoadConst(s, tail, raiserInt((sized.typeValue - elemCount) as int64));
		emitZeroFill(s, dest, tail, sized.typeReturn);
	}
	return dest;
}

function compileSpreadArrayLiteral(s: RaiserCompState, node: Node): int32 {
	const d = node.data as ArrayLiteralData;
	const elementType = node.nodeType != null ? getElementType(unwrapRef(node.nodeType)) : null;
	const dest = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.NewArray, dest, 0, 0));
	for (const e of d.elements) {
		if (e.kind == NodeKind.SpreadExpr) {
			appendSpreadSource(s, dest, (e.data as SpreadExprData).spreadArg, elementType);
			continue;
		}
		const item = emitValueCopy(s, compileExpr(s, e), elementType);
		emitInst(s, raiserABC(RaiserOpcode.ArrayPush, dest, item, 0));
	}
	return dest;
}

function isIndexedSpreadSource(t: Type | null): boolean {
	if (t == null) return false;
	const bare = unwrapRef(peelTransparentInstance(unwrapRef(t)));
	return bare.kind == TypeKind.Array || bare.kind == TypeKind.SizedArray || bare.kind == TypeKind.Span || bare.kind == TypeKind.Tuple;
}

function appendSpreadSource(s: RaiserCompState, dest: int32, source: Node, elementType: Type | null): void {
	if (!isIndexedSpreadSource(source.nodeType)) {
		const msg = `a spread of '${typeDisplayName(source.nodeType)}' is unsupported by the Raiser bytecode compiler`;
		queueRaiserCompileError(msg, source.location.line, source.location.column);
		emitTrapNil(s, msg);
		return;
	}
	const sourceReg = compileExpr(s, source);
	const idx = allocWord(s);
	emitLoadConst(s, idx, raiserInt(0));
	const len = allocWord(s);
	emitInst(s, raiserABC(RaiserOpcode.ArrayLen, len, sourceReg, 0));
	const item = allocFor(s, elementType);
	const loopStart = codeLen(s);
	emitInst(s, raiserABC(RaiserOpcode.BltI64, idx, len, 1));
	const exit = emitJumpPlaceholder(s);
	emitInst(s, raiserABC(RaiserOpcode.LoadIndex, item, sourceReg, idx));
	emitInst(s, raiserABC(RaiserOpcode.ArrayPush, dest, emitValueCopy(s, item, elementType), 0));
	emitInst(s, raiserABC(RaiserOpcode.AddI64Imm, idx, idx, immField(1)));
	emitInst(s, raiserAx(RaiserOpcode.Jump, loopStart - codeLen(s) - 1));
	patchJumpTo(s, exit, codeLen(s));
}

function isSpanType(t: Type | null): boolean {
	if (t == null) return false;
	if ((t.kind == TypeKind.Var || t.kind == TypeKind.Sink || t.kind == TypeKind.Lent) && t.typeReturn != null) return t.typeReturn.kind == TypeKind.Span;
	return t.kind == TypeKind.Span;
}

function compileStringBytes(s: RaiserCompState, strReg: int32): int32 {
	const dest = allocBlock(s, [RaiserRegClass.Ref, RaiserRegClass.Ref]);
	const arg = dest + 1;
	emitInst(s, raiserABC(RaiserOpcode.Move, arg, strReg, 0));
	const nameIdx = addConst(s, raiserConstString("msAsBytes"));
	emitInst(s, raiserABC(RaiserOpcode.CallHost, dest, nameIdx, 1));
	return dest;
}

function compileArraySlice(s: RaiserCompState, d: ArrayAccessData, bd: BinaryExprData): int32 {
	let srcReg = compileExpr(s, d.array);
	if (exprIsString(s, d.array)) srcReg = compileStringBytes(s, srcReg);
	const startReg = compileExpr(s, bd.left);
	const endReg = compileExpr(s, bd.right);
	const slotStart = allocBlock(s, [RaiserRegClass.Word, RaiserRegClass.Word]);
	const slotEnd = slotStart + 1;
	emitInst(s, raiserABC(RaiserOpcode.Move, slotStart, startReg, 0));
	if (bd.operator == "...") {
		const one = allocWord(s);
		emitLoadConst(s, one, raiserInt(1));
		emitInst(s, raiserABC(RaiserOpcode.AddI64, slotEnd, endReg, one));
	} else {
		emitInst(s, raiserABC(RaiserOpcode.Move, slotEnd, endReg, 0));
	}
	const dest = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.ArraySlice, dest, srcReg, slotStart));
	return dest;
}

function compileArrayAccess(s: RaiserCompState, node: Node): int32 {
	const refusedOp = refusePointerOp(s, node);
	if (refusedOp >= 0) return refusedOp;
	const d = node.data as ArrayAccessData;
	const held = skipModifier(d.array.nodeType);
	if (held != null && held.kind == TypeKind.Ptr) {
		const pointer = compileExpr(s, d.array);
		if (!heldByLocation(s, node.nodeType)) return pointer;
		const dest = allocFor(s, node.nodeType);
		emitInst(s, raiserABC(RaiserOpcode.LoadDeref, dest, pointer, 0));
		return dest;
	}
	if (d.index.kind == NodeKind.BinaryExpr) {
		const bd = d.index.data as BinaryExprData;
		if (bd.operator == ".." || bd.operator == "...") return compileArraySlice(s, d, bd);
	}
	const arrReg = compileExpr(s, d.array);
	const idxReg = compileIndex(s, d.index);
	const dest = allocFor(s, node.nodeType);
	emitInst(s, raiserABC(RaiserOpcode.LoadIndex, dest, arrReg, idxReg));
	return dest;
}

function compileEnumOrdinal(s: RaiserCompState, node: Node, member: Symbol): int32 {
	const enumTy = member.symbolType.kind == TypeKind.EnumLiteral ? member.symbolType.typeReturn : member.symbolType;
	const r = allocWord(s);
	if (enumTy != null && enumTy.kind == TypeKind.Enum) {
		for (let ei = 0; ei < enumTy.typeNames.length; ei += 1) {
			if (enumTy.typeNames[ei] != member.name) continue;
			const ord = enumTy.typeChildren != null && ei < enumTy.typeChildren.length ? enumTy.typeChildren[ei].typeValue : ei;
			emitLoadConst(s, r, raiserInt(ord));
			return r;
		}
	}
	queueRaiserCompileError(`internal: enum member '${member.name}' has no ordinal in its enum type`, node.location.line, node.location.column);
	return r;
}

function compileMemberExpr(s: RaiserCompState, node: Node): int32 {
	const d = node.data as MemberExprData;
	const nsMember = namespaceMemberIdent(node);
	if (nsMember != null) {
		compileNamespaceObject(s, node);
		return compileExpr(s, nsMember);
	}

	const sym = node.resolvedSym;
	if (sym != null && sym.symFlags.has(SymbolFlag.Static) && !sym.symFlags.has(SymbolFlag.Mutable)
		&& sym.declNode != null && sym.declNode.kind == NodeKind.PropertyDecl) {
		const pd = sym.declNode.data as PropertyDeclData;
		if (pd.propInitializer != null) return compileExpr(s, pd.propInitializer);
	}

	if (sym != null && sym.symbolKind == SymbolKind.EnumMember && sym.symbolType != null) {
		return compileEnumOrdinal(s, node, sym);
	}

	if (d.property == "byteLength" && exprIsString(s, d.object)) {
		const source = compileExpr(s, d.object);
		const destination = allocWord(s);
		emitInst(s, raiserABC(RaiserOpcode.StrByteLen, destination, source, 0));
		return destination;
	}

	// .length — string vs array
	if (d.property == "length" && !isRecordOperand(d.object)) {
		const objReg = compileExpr(s, d.object);
		const dest = allocWord(s);
		if (exprIsString(s, d.object)) {
			emitInst(s, raiserABC(RaiserOpcode.StrLen, dest, objReg, 0));
		} else {
			emitInst(s, raiserABC(RaiserOpcode.ArrayLen, dest, objReg, 0));
		}
		return dest;
	}

	// General field access on objects
	const objReg = compileExpr(s, d.object);
	const nameIdx = addConst(s, raiserConstString(d.property));
	const dest = allocFor(s, node.nodeType);
	emitInst(s, fieldInst(s, d.object.nodeType, d.property, RaiserOpcode.LoadField, RaiserOpcode.LoadSlot, dest, objReg, nameIdx));
	return dest;
}

// Every object of a struct, interface or class type holds its fields in the order
// of `typeNames`, which puts a parent's fields first; a structural match is a prefix
// of it. A function value is a closure pair. NewObject lays that order out, so the
// type fixes each field's slot.
export function layoutOf(t: Type | null): string[] {
	if (isMetaWireSym(classSymOfType(skipModifier(t)))) return [];
	const bare = skipModifier(t);
	if (bare != null && bare.kind == TypeKind.Function) return CLOSURE_PAIR;
	const shape = peelToStructOrUnion(t);
	return shape != null && shape.kind == TypeKind.Struct && !isMaybeType(shape) ? shape.typeNames : [];
}

// The register class each slot of layoutOf(t) holds.
export function slotKindsOf(s: RaiserCompState, t: Type | null): RaiserRegClass[] {
	if (isMetaWireSym(classSymOfType(skipModifier(t)))) return [];
	const bare = skipModifier(t);
	if (bare != null && bare.kind == TypeKind.Function) return CLOSURE_PAIR_KINDS;
	const shape = peelToStructOrUnion(t);
	return shape != null && shape.kind == TypeKind.Struct && !isMaybeType(shape) ? slotClassesOf(s, shape) : [];
}

// A slot opcode moves the slot's word as it is, so a field goes by slot only when the value's
// register is of the class its slot holds; any other register converts by name.
export function fieldInst(s: RaiserCompState, t: Type | null, name: string, byName: RaiserOpcode, bySlot: RaiserOpcode, a: number, b: number, c: number): RaiserInstruction {
	const slot = layoutOf(t).indexOf(name);
	if (slot < 0 || slot > MAX_SLOT) return raiserABC(byName, a, b, c);
	const value = bySlot == RaiserOpcode.LoadSlot ? a : c;
	return classOfReg(s, value as int32) == slotKindsOf(s, t)[slot] ? slotInst(bySlot, a, b, c, slot) : raiserABC(byName, a, b, c);
}

function isRecordOperand(node: Node): boolean {
	const t = peelToStructOrUnion(node.nodeType);
	return t != null && t.kind == TypeKind.Struct;
}

function isDeclaredMethodCall(callee: Node): boolean {
	return callee.resolvedSym != null && callee.resolvedSym.symbolKind == SymbolKind.Method;
}

function isArrayPush(node: Node): boolean {
	if (node.kind != NodeKind.MemberExpr || isDeclaredMethodCall(node)) return false;
	const d = node.data as MemberExprData;
	return d.property == "push";
}

function isArraySetLengthCall(s: RaiserCompState, node: Node): boolean {
	if (node.kind != NodeKind.MemberExpr || isDeclaredMethodCall(node)) return false;
	const d = node.data as MemberExprData;
	if (d.property != "setLength") return false;
	return !exprIsString(s, d.object);
}

function isToStringCall(node: Node): boolean {
	if (node.kind != NodeKind.MemberExpr || isDeclaredMethodCall(node)) return false;
	const d = node.data as MemberExprData;
	return d.property == "toString";
}

function compileToStringCall(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const md = d.callee.data as MemberExprData;
	return compileTextOf(s, md.object);
}

function compileTextOf(s: RaiserCompState, obj: Node): int32 {
	const objReg = compileStringPart(s, obj);
	const emptyReg = allocRef(s);
	emitLoadConst(s, emptyReg, raiserConstString(""));
	const dest = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.ConcatStr, dest, objReg, emptyReg));
	return dest;
}

function compileArrayPushCall(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const md = d.callee.data as MemberExprData;
	const arrReg = compileExpr(s, md.object);
	for (let i = 0; i < d.arguments.length; i = i + 1) {
		const valReg = emitValueCopy(s, compileExpr(s, d.arguments[i]), d.arguments[i].nodeType);
		emitInst(s, raiserABC(RaiserOpcode.ArrayPush, arrReg, valReg, 0));
	}
	return arrReg;
}

function compileArraySetLenCall(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const md = d.callee.data as MemberExprData;
	const arrReg = compileExpr(s, md.object);
	const count = allocWord(s);
	emitInst(s, raiserABC(RaiserOpcode.Conv, count, compileExpr(s, d.arguments[0]), RaiserConvClass.I64));
	emitInst(s, raiserABC(RaiserOpcode.ArraySetLen, arrReg, count, 0));
	return arrReg;
}

function compileExitCall(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const codeReg = allocWord(s);
	if (d.arguments.length == 0) {
		emitLoadConst(s, codeReg, raiserInt(0));
	} else {
		emitInst(s, raiserABC(RaiserOpcode.Conv, codeReg, compileExpr(s, d.arguments[0]), RaiserConvClass.I32));
	}
	// b=1 marks the halt abrupt: it skips the strand drain, the way
	// process.exit bypasses msDrainUntilIdle on C.
	emitInst(s, raiserABC(RaiserOpcode.Halt, codeReg, 1, 0));
	return codeReg;
}

function compileMapFatalCall(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const head = allocRef(s);
	emitLoadConst(s, head, raiserConstString("fatal error: "));
	const text = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.ConcatStr, text, head, compileExpr(s, d.arguments[0])));
	const newline = allocRef(s);
	emitLoadConst(s, newline, raiserConstString("\n"));
	emitInst(s, raiserABC(RaiserOpcode.ConcatStr, text, text, newline));
	const written = allocBlock(s, [RaiserRegClass.Ref, RaiserRegClass.Ref]);
	const arg = written + 1;
	emitInst(s, raiserABC(RaiserOpcode.Move, arg, text, 0));
	emitInst(s, raiserABC(RaiserOpcode.CallHost, written, addConst(s, raiserConstString("msWriteStderr")), 1));
	const code = allocWord(s);
	emitLoadConst(s, code, raiserInt(2));
	emitInst(s, raiserABC(RaiserOpcode.Halt, code, 1, 0));
	return code;
}

// spawn/waitFor/Promise.resolve carry @builtin on the extern; the kind lands
// on the CallExpr for free functions and on the callee for the static method.
function combineOf(builtinKind: string): int32 {
	if (builtinKind == "PromiseAll") return RaiserCombine.All as int32;
	if (builtinKind == "PromiseRace") return RaiserCombine.Race as int32;
	if (builtinKind == "PromiseAny") return RaiserCombine.Any as int32;
	return -1;
}

function callBuiltinKind(node: Node): string {
	if (node.resolvedSym != null && node.resolvedSym.builtinKind != "") return node.resolvedSym.builtinKind;
	const d = node.data as CallExprData;
	if (d.callee.resolvedSym != null) return d.callee.resolvedSym.builtinKind;
	return "";
}

// --- String method detection + compilation ---

function isStringMethod(s: RaiserCompState, node: Node, method: string): boolean {
	if (node.kind != NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	if (d.property != method) return false;
	return exprIsString(s, d.object);
}

function compileStrCharAt(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const md = d.callee.data as MemberExprData;
	const strReg = compileExpr(s, md.object);
	const idxReg = compileExpr(s, d.arguments[0]);
	const dest = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.StrCharAt, dest, strReg, idxReg));
	return dest;
}

function compileStrSlice(s: RaiserCompState, node: Node): int32 {
	const d = node.data as CallExprData;
	const md = d.callee.data as MemberExprData;
	const strReg = compileExpr(s, md.object);
	// Start and end must be contiguous: C and C+1
	const startReg = compileExpr(s, d.arguments[0]);
	const endReg = compileExpr(s, d.arguments[1]);
	// Ensure contiguous layout: move to adjacent registers if needed
	const slotStart = allocBlock(s, [RaiserRegClass.Word, RaiserRegClass.Word]);
	const slotEnd = slotStart + 1;
	if (startReg != slotStart) {
		emitInst(s, raiserABC(RaiserOpcode.Move, slotStart, startReg, 0));
	}
	if (endReg != slotEnd) {
		emitInst(s, raiserABC(RaiserOpcode.Move, slotEnd, endReg, 0));
	}
	const dest = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.StrSlice, dest, strReg, slotStart));
	return dest;
}

// Coerce each argument (ConcatStr with "") and space-join them into one line (C/JS parity).
function compileEchoLine(s: RaiserCompState, args: Node[]): int32 {
	const spaceReg = allocRef(s);
	emitLoadConst(s, spaceReg, raiserConstString(" "));
	const emptyReg = allocRef(s);
	emitLoadConst(s, emptyReg, raiserConstString(""));
	const acc = allocRef(s);
	if (args.length == 0) {
		emitInst(s, raiserABC(RaiserOpcode.Move, acc, emptyReg, 0));
		return acc;
	}
	const firstReg = compileStringPart(s, args[0]);
	emitInst(s, raiserABC(RaiserOpcode.ConcatStr, acc, firstReg, emptyReg));
	for (let i = 1; i < args.length; i = i + 1) {
		emitInst(s, raiserABC(RaiserOpcode.ConcatStr, acc, acc, spaceReg));
		const argReg = compileStringPart(s, args[i]);
		emitInst(s, raiserABC(RaiserOpcode.ConcatStr, acc, acc, argReg));
	}
	return acc;
}

function isConsoleStderr(node: Node): boolean {
	if (node.kind != NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	if (d.property != "warn" && d.property != "error") return false;
	if (d.object.kind != NodeKind.Identifier) return false;
	return (d.object.data as IdentifierData).name == "console";
}

// --- Console.log detection ---

function isConsoleLog(node: Node): boolean {
	if (node.kind != NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	if (d.property != "log") return false;
	if (d.object.kind != NodeKind.Identifier) return false;
	const obj = d.object.data as IdentifierData;
	return obj.name == "console";
}

// --- Class instances ---

export function emitsRoutine(decl: Node, flags: string): boolean {
	const sym = decl.resolvedSym;
	if (sym != null && (hasFlag(sym, SymbolFlag.OverloadSig) || hasFlag(sym, SymbolFlag.Borrow))) return false;
	return !isGenericFn(flags) && (decl.nodeType == null || !hasGenericParams(decl.nodeType));
}

export function classTypeOperand(s: RaiserCompState, className: string, classSym: Symbol | null): int32 {
	if (classSym == null) return 0;
	const chain: string[] = [raiserClassKey(classSym)];
	let up = classParentOf(classSym.symbolType);
	while (up != null && classTargetKey(up) != "") {
		if (chain.length == 64) throw new Error(`internal: the class chain of '${className}' is deeper than 64`);
		chain.push(classTargetKey(up));
		up = classParentOf(up);
	}
	const display: int64[] = [];
	for (let i = chain.length - 1; i >= 0; i -= 1) display.push(raiserClassId(chain[i]));
	s.classTypes.push(createClassType(className, chain.length - 1, display, layoutOf(classSym.symbolType), slotKindsOf(s, classSym.symbolType)));
	return s.classTypes.length;
}

// The operand InstanceOf and ObjConv carry: the id of the class `t` names and its depth, packed.
function classTargetOperand(s: RaiserCompState, t: Type | null, key: string): int32 {
	let up = classParentOf(t != null && t.kind == TypeKind.Union ? unwrapRefNullUnion(t) : t);
	let depth = 0;
	while (up != null && classTargetKey(up) != "") {
		depth += 1;
		if (depth == 64) throw new Error(`internal: the class chain of '${key}' is deeper than 64`);
		up = classParentOf(up);
	}
	return addConst(s, raiserInt(raiserClassId(key) * 64 + depth));
}

function literalClass(t: Type | null): Symbol | null {
	const bare = t != null && t.kind == TypeKind.Ref ? t.typeReturn : t;
	if (runtimeClassSym(bare) == null) return null;
	const sym = classSymOfType(bare);
	return sym != null ? placedInstanceOf(sym) : null;
}

function emitObjectShell(s: RaiserCompState, dest: int32, t: Type | null): void {
	const classSym = literalClass(t);
	const decl = classSym != null ? classDeclNodeOf(classSym) : null;
	const className = decl != null && decl.kind == NodeKind.ClassDecl ? (decl.data as ClassDeclData).className : "";
	const shape = classSym != null ? classTypeOperand(s, className != "" ? className : classSym.name, classSym) : layoutOperand(s, layoutOf(t), slotKindsOf(s, t));
	emitInst(s, raiserABC(RaiserOpcode.NewObject, dest, shape, 0));
}
