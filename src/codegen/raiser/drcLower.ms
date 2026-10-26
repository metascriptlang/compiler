import { Node, NodeKind, CallExprData, NumberLiteralData, MemberExprData, ArrayAccessData, HiddenDerefData, SymbolFlag, AttachedOp, Type, TypeKind, TypeFlag } from "../../ast/node";
import { hasFlag } from "../../checker/symbol";
import { isStructType, needsValueCopy, valueCopyRepr } from "../../checker/types";
import { RaiserOpcode, RaiserRegClass, inRefFile, raiserABC } from "../../raiser/bytecode";
import { raiserConstString, raiserNil, RaiserValueKind } from "../../raiser/value";
import { RaiserCompState, emitInst, allocBlock, allocRef, emitLoadConst, emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, codeLen, allocBool, allocReg, classOfReg, resolveLocal, resolveGlobal, addConst, getRaiserModulePath } from "./context";
import { getOpByKey } from "../c/types";
import { userHookOf } from "../../transform/lowering/destructorLifting";
import { compileExpr, compileIndex } from "./expressions";
import { fieldInst, emitValueCopy, emitZeroValue, emitCellSwap, isInPlaceCell, isNilBranch } from "./valueCopy";
import {
	ROW_INCREF, ROW_DECREF, ROW_DECREF_CYCLIC, ROW_CLEAR, ROW_SINK, ROW_SHARE, ROW_KEPT, ROW_COPY_VALUE, ROW_STR_APPEND, ROW_STR_APPEND_CHAR, ROW_STR_APPEND_CODEPOINT,
	ownershipName, ownershipRow,
} from "./drcRows";

function placeOf(arg: Node): Node {
	return arg.kind == NodeKind.HiddenAddr ? placeOf((arg.data as HiddenDerefData).expr) : arg;
}

function refRegister(s: RaiserCompState, name: string, arg: Node): int32 {
	const reg = compileExpr(s, placeOf(arg));
	if (!inRefFile(classOfReg(s, reg))) throw new Error(`internal: ${name} reached a ${classOfReg(s, reg).toString()} register at ${getRaiserModulePath()}:${arg.location.line}:${arg.location.column}, and Raiser lowers it only on a register of the ref file`);
	return reg;
}

function emitPlaceStore(s: RaiserCompState, name: string, place: Node, value: int32): void {
	if (place.kind == NodeKind.Identifier) {
		const global = resolveGlobal(s, place.resolvedSym);
		if (global >= 0) {
			emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, value, global, 0));
			return;
		}
		const local = resolveLocal(s, place.resolvedSym);
		if (local >= 0) {
			emitInst(s, raiserABC(RaiserOpcode.Move, local, value, 0));
			return;
		}
	} else if (place.kind == NodeKind.MemberExpr) {
		const d = place.data as MemberExprData;
		const objReg = compileExpr(s, d.object);
		const nameIdx = addConst(s, raiserConstString(d.property));
		emitInst(s, fieldInst(s, d.object.nodeType, d.property, RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, objReg, nameIdx, value));
		return;
	} else if (place.kind == NodeKind.ArrayAccess) {
		const d = place.data as ArrayAccessData;
		const arrReg = compileExpr(s, d.array);
		emitInst(s, raiserABC(RaiserOpcode.StoreIndex, arrReg, compileIndex(s, d.index), value));
		return;
	}
	throw new Error(`internal: ${name} stores into a ${place.kind.toString()}, which Raiser has no store for`);
}

function emitClear(s: RaiserCompState, name: string, arg: Node): void {
	const place = placeOf(arg);
	const local = place.kind == NodeKind.Identifier && resolveGlobal(s, place.resolvedSym) < 0 ? resolveLocal(s, place.resolvedSym) : -1;
	if (local >= 0) {
		emitInst(s, raiserABC(RaiserOpcode.WasMoved, local, 0, 0));
		return;
	}
	if (needsValueCopy(place.nodeType)) {
		const cleared = allocReg(s, RaiserRegClass.Ref);
		emitLoadConst(s, cleared, raiserNil());
		emitPlaceStore(s, name, place, cleared);
		return;
	}
	emitPlaceStore(s, name, place, emitZeroValue(s, place.nodeType));
}

function emitRebind(s: RaiserCompState, name: string, dest: Node, incoming: int32, oldSource: int32): void {
	const old = allocReg(s, classOfReg(s, oldSource));
	emitInst(s, raiserABC(RaiserOpcode.Move, old, oldSource, 0));
	emitPlaceStore(s, name, placeOf(dest), incoming);
	emitInst(s, raiserABC(RaiserOpcode.RcDec, old, 0, 0));
}

function emitStoreInto(s: RaiserCompState, name: string, dest: Node, incoming: int32): void {
	const oldSource = refRegister(s, name, dest);
	if (!isInPlaceCell(s, placeOf(dest).nodeType)) {
		emitRebind(s, name, dest, incoming, oldSource);
		return;
	}
	if (placeOf(dest).kind == NodeKind.HiddenDeref) {
		emitCellSwap(s, oldSource, incoming, placeOf(dest).nodeType);
		emitInst(s, raiserABC(RaiserOpcode.RcDec, incoming, 0, 0));
		return;
	}
	const incomingHeld = isNilBranch(s, incoming);
	const rebindIncomingNil = emitJumpPlaceholder(s);
	patchJumpTo(s, incomingHeld, codeLen(s));
	const destinationHeld = isNilBranch(s, oldSource);
	patchJumpTo(s, rebindIncomingNil, codeLen(s));
	emitRebind(s, name, dest, incoming, oldSource);
	const toEnd = emitJumpPlaceholder(s);
	patchJumpTo(s, destinationHeld, codeLen(s));
	emitCellSwap(s, oldSource, incoming, placeOf(dest).nodeType);
	emitInst(s, raiserABC(RaiserOpcode.RcDec, incoming, 0, 0));
	patchJumpTo(s, toEnd, codeLen(s));
}

function emitSink(s: RaiserCompState, name: string, dest: Node, src: Node): void {
	emitStoreInto(s, name, dest, refRegister(s, name, src));
}

function emitAppend(s: RaiserCompState, name: string, dest: Node, tail: int32): void {
	const held = refRegister(s, name, dest);
	const joined = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.ConcatStr, joined, held, tail));
	emitRebind(s, name, dest, joined, held);
}

function emitAppendChar(s: RaiserCompState, name: string, dest: Node, code: Node): void {
	if (code.kind != NodeKind.NumberLiteral) throw new Error(`internal: Raiser has no lowering for ${name} of a code that is not a literal`);
	const tail = allocRef(s);
	emitLoadConst(s, tail, raiserConstString(String.fromCharCode((code.data as NumberLiteralData).value as int32)));
	emitAppend(s, name, dest, tail);
}

function emitAppendCodePoint(s: RaiserCompState, name: string, dest: Node, codePoint: Node): void {
	const point = compileExpr(s, codePoint);
	const block = allocBlock(s, [RaiserRegClass.Ref, classOfReg(s, point)]);
	emitInst(s, raiserABC(RaiserOpcode.Move, block + 1, point, 0));
	emitInst(s, raiserABC(RaiserOpcode.CallHost, block, addConst(s, raiserConstString("msStringFromCodePoint")), 1));
	emitAppend(s, name, dest, block);
}

function emitShare(s: RaiserCompState, name: string, dest: Node, src: Node): void {
	const incoming = refRegister(s, name, src);
	emitInst(s, raiserABC(RaiserOpcode.RcInc, incoming, 0, 0));
	emitRebind(s, name, dest, incoming, refRegister(s, name, dest));
}

function emitCopyValue(s: RaiserCompState, name: string, dest: Node, src: Node): void {
	const source = refRegister(s, name, src);
	const copied = emitValueCopy(s, source, placeOf(src).nodeType);
	if (copied == source) emitInst(s, raiserABC(RaiserOpcode.RcInc, source, 0, 0));
	emitStoreInto(s, name, dest, copied);
}

function isCellType(type: Type | null): boolean {
	const t = valueCopyRepr(type);
	return isStructType(t) || (t != null && t.kind == TypeKind.Union && t.typeFlags.has(TypeFlag.ValueUnion));
}

function isCellHook(call: CallExprData, flag: SymbolFlag): boolean {
	const sym = call.callee.resolvedSym;
	return sym != null && hasFlag(sym, SymbolFlag.GeneratedOp) && hasFlag(sym, flag) && call.arguments.length == 1
		&& isCellType(placeOf(call.arguments[0]).nodeType);
}

function isLiftedCellOp(call: CallExprData, op: AttachedOp): boolean {
	const sym = call.callee.resolvedSym;
	if (sym == null || !hasFlag(sym, SymbolFlag.GeneratedOp) || call.arguments.length != 2) return false;
	const type = placeOf(call.arguments[0]).nodeType;
	return type != null && isCellType(type) && getOpByKey(type, op) == sym;
}

function isLiftedCellSink(call: CallExprData): boolean {
	return isLiftedCellOp(call, AttachedOp.AttachedSink) && userHookOf(placeOf(call.arguments[0]).nodeType!, AttachedOp.AttachedSink) == null;
}

function emitMaterialize(s: RaiserCompState, name: string, dest: Node): void {
	const place = placeOf(dest);
	const present = isNilBranch(s, refRegister(s, name, dest));
	emitPlaceStore(s, name, place, emitZeroValue(s, place.nodeType));
	patchJumpTo(s, present, codeLen(s));
}

function isHooklessCellWasMoved(call: CallExprData): boolean {
	const type = call.arguments.length == 1 ? placeOf(call.arguments[0]).nodeType : null;
	return isCellHook(call, SymbolFlag.WasMovedOp) && type != null && userHookOf(type, AttachedOp.AttachedWasMoved) == null;
}

export function compileOwnershipStmt(s: RaiserCompState, call: Node): boolean {
	if (call.kind != NodeKind.CallExpr) return false;
	const d = call.data as CallExprData;
	if (isHooklessCellWasMoved(d)) {
		emitClear(s, d.callee.resolvedSym!.name, d.arguments[0]);
		return true;
	}
	if (isCellHook(d, SymbolFlag.WasMovedOp)) {
		const held = refRegister(s, d.callee.resolvedSym!.name, d.arguments[0]);
		const isNil = allocBool(s);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, isNil, held, RaiserValueKind.Nil as number));
		const callHook = emitBranchIfFalsy(s, isNil);
		const toEnd = emitJumpPlaceholder(s);
		patchJumpTo(s, callHook, codeLen(s));
		compileExpr(s, call);
		patchJumpTo(s, toEnd, codeLen(s));
		return true;
	}
	if (isLiftedCellSink(d)) {
		emitSink(s, d.callee.resolvedSym!.name, d.arguments[0], d.arguments[1]);
		return true;
	}
	if (isCellHook(d, SymbolFlag.DestroyOp)) {
		const hookName = d.callee.resolvedSym!.name;
		emitInst(s, raiserABC(RaiserOpcode.RcDec, refRegister(s, hookName, d.arguments[0]), 0, 0));
		emitClear(s, hookName, d.arguments[0]);
		return true;
	}
	if (isLiftedCellOp(d, AttachedOp.AttachedAsgn) || isLiftedCellOp(d, AttachedOp.AttachedSink)) emitMaterialize(s, d.callee.resolvedSym!.name, d.arguments[0]);
	const row = ownershipRow(d.callee.resolvedSym);
	if (row == 0) return false;
	const name = ownershipName(d.callee.resolvedSym);
	if (row == ROW_INCREF) emitInst(s, raiserABC(RaiserOpcode.RcInc, refRegister(s, name, d.arguments[0]), 0, 0));
	else if (row == ROW_DECREF) emitInst(s, raiserABC(RaiserOpcode.RcDec, refRegister(s, name, d.arguments[0]), 0, 0));
	else if (row == ROW_DECREF_CYCLIC) emitInst(s, raiserABC(RaiserOpcode.RcDec, refRegister(s, name, d.arguments[0]), 1, 0));
	else if (row == ROW_CLEAR) emitClear(s, name, d.arguments[0]);
	else if (row == ROW_SINK) emitSink(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_KEPT) emitInst(s, raiserABC(RaiserOpcode.RcKeptCheck, refRegister(s, name, d.arguments[0]), compileExpr(s, d.arguments[1]), 0));
	else if (row == ROW_COPY_VALUE) emitCopyValue(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_SHARE) emitShare(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_STR_APPEND) emitAppend(s, name, d.arguments[0], compileExpr(s, d.arguments[1]));
	else if (row == ROW_STR_APPEND_CHAR) emitAppendChar(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_STR_APPEND_CODEPOINT) emitAppendCodePoint(s, name, d.arguments[0], d.arguments[1]);
	else throw new Error(`internal: ownership row ${row} of ${name} has no emitter`);
	return true;
}
