import { Node, NodeKind, CallExprData, NumberLiteralData, MemberExprData, ArrayAccessData, HiddenDerefData, SymbolFlag, AttachedOp, Type, TypeKind, TypeFlag } from "../../ast/node";
import { hasFlag } from "../../checker/symbol";
import { declaresUserHook } from "../../checker/instantiate";
import { isMaybeType, isStructType, isIterator, isIteratorResult, needsValueCopy, isPlainDataType, valueCopyRepr, distinctBody, skipModifier } from "../../checker/types";
import { RaiserOpcode, RaiserRegClass, inRefFile, raiserABC } from "../../raiser/bytecode";
import { raiserConstString, raiserNil, RaiserValueKind } from "../../raiser/value";
import { RaiserCompState, emitInst, allocBlock, allocDyn, allocRef, allocWord, emitLoadConst, emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, codeLen, allocBool, allocReg, classOfReg, resolveLocal, resolveGlobal, addConst, getRaiserModulePath } from "./context";
import { getOpByKey } from "../c/types";
import { raiserFlatCellUnion } from "../../analyzer/classify";
import { userHookOf } from "../../transform/lowering/destructorLifting";
import { compileExpr, compileIndex } from "./expressions";
import { fieldInst, aggregateAssignPlan, isUnionCell, emitValueCopy, emitZeroValue, nullIsZeroValue, emitCellSwap, isInPlaceCell, isNilBranch, emitZeroNilElements } from "./valueCopy";
import {
	ROW_INCREF, ROW_DECREF, ROW_DECREF_CYCLIC, ROW_CLEAR, ROW_SINK, ROW_SHARE, ROW_KEPT, ROW_COPY_VALUE, ROW_STR_APPEND, ROW_STR_APPEND_CHAR, ROW_STR_APPEND_CODEPOINT, ROW_TRACE, ROW_SET_LEN,
	ownershipName, ownershipRow,
} from "./drcRows";

function placeOf(arg: Node): Node {
	return arg.kind == NodeKind.HiddenAddr ? placeOf((arg.data as HiddenDerefData).expr) : arg;
}

function refRegister(s: RaiserCompState, name: string, arg: Node): int32 {
	const place = placeOf(arg);
	const reg = compileExpr(s, place);
	if (inRefFile(classOfReg(s, reg))) return reg;
	const held = skipModifier(place.nodeType);
	if (held == null || held.kind != TypeKind.Union) throw new Error(`internal: ${name} reached a ${classOfReg(s, reg).toString()} register at ${getRaiserModulePath()}:${arg.location.line}:${arg.location.column}, and Raiser lowers it only on a register of the ref file or a union slot holding a scalar`);
	const boxed = allocDyn(s);
	emitInst(s, raiserABC(RaiserOpcode.Move, boxed, reg, 0));
	return boxed;
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
	else if (place.kind == NodeKind.HiddenDeref) {
		emitInst(s, raiserABC(RaiserOpcode.StoreDeref, compileExpr(s, (place.data as HiddenDerefData).expr), 0, value));
		return;
	}
	throw new Error(`internal: ${name} stores into a ${place.kind.toString()}, which Raiser has no store for`);
}

function localOfPlace(s: RaiserCompState, place: Node): int32 {
	return place.kind == NodeKind.Identifier && resolveGlobal(s, place.resolvedSym) < 0 ? resolveLocal(s, place.resolvedSym) : -1;
}

function emitClear(s: RaiserCompState, name: string, arg: Node, leavesEmptyArray: boolean = true): void {
	const place = placeOf(arg);
	const local = localOfPlace(s, place);
	if (local >= 0) {
		emitInst(s, raiserABC(RaiserOpcode.WasMoved, local, 0, 0));
		return;
	}
	if (leavesEmptyArray && isPlainDataType(place.nodeType, declaresUserHook)) {
		if (needsValueCopy(place.nodeType)) emitKeptCopy(s, name, place);
		return;
	}
	if (needsValueCopy(place.nodeType) && !(leavesEmptyArray && (isArrayType(place.nodeType) || nullIsZeroValue(place.nodeType)))) {
		const cleared = allocReg(s, RaiserRegClass.Ref);
		emitLoadConst(s, cleared, raiserNil());
		emitPlaceStore(s, name, place, cleared);
		return;
	}
	emitPlaceStore(s, name, place, emitZeroValue(s, place.nodeType));
}

function emitKeptCopy(s: RaiserCompState, name: string, place: Node): void {
	const source = refRegister(s, name, place);
	const copied = emitValueCopy(s, source, place.nodeType);
	if (copied == source) emitInst(s, raiserABC(RaiserOpcode.RcInc, source, 0, 0));
	else emitPlaceStore(s, name, place, copied);
}

function emitRebind(s: RaiserCompState, name: string, dest: Node, incoming: int32, oldSource: int32): void {
	const old = allocReg(s, classOfReg(s, oldSource));
	emitInst(s, raiserABC(RaiserOpcode.Move, old, oldSource, 0));
	emitPlaceStore(s, name, placeOf(dest), incoming);
	emitInst(s, raiserABC(RaiserOpcode.RcDec, old, 0, 0));
}

function emitAssignInPlace(s: RaiserCompState, name: string, dest: Node, incoming: int32, oldSource: int32, plan: int32): void {
	if (placeOf(dest).kind == NodeKind.HiddenDeref) {
		emitInst(s, raiserABC(RaiserOpcode.AssignInPlace, oldSource, incoming, plan));
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
	emitInst(s, raiserABC(RaiserOpcode.AssignInPlace, oldSource, incoming, plan));
	patchJumpTo(s, toEnd, codeLen(s));
}

function emitStoreInto(s: RaiserCompState, name: string, dest: Node, incoming: int32): void {
	const oldSource = refRegister(s, name, dest);
	const plan = aggregateAssignPlan(s, placeOf(dest).nodeType);
	if (plan >= 0) {
		emitAssignInPlace(s, name, dest, incoming, oldSource, plan);
		return;
	}
	if (!isInPlaceCell(s, placeOf(dest).nodeType)) {
		emitRebind(s, name, dest, incoming, oldSource);
		return;
	}
	if (placeOf(dest).kind == NodeKind.HiddenDeref && !isMaybeHeld(placeOf(dest).nodeType)) {
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
	const place = placeOf(dest);
	if (place.kind == NodeKind.Identifier && resolveLocal(s, place.resolvedSym) == held
		&& classOfReg(s, held) == RaiserRegClass.Ref && classOfReg(s, tail) == RaiserRegClass.Ref) {
		emitInst(s, raiserABC(RaiserOpcode.ConcatStrR, held, held, tail));
		return;
	}
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
	emitInst(s, raiserABC(RaiserOpcode.RcDec, block, 0, 0));
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

function isMaybeHeld(type: Type | null): boolean {
	return isMaybeType(skipModifier(type));
}

function isCellType(type: Type | null): boolean {
	const t = valueCopyRepr(type);
	return isMaybeHeld(type) || isStructType(t) || isIterator(t) || isIteratorResult(t) || (t != null && isUnionCell(t));
}

function isCopiedAsValue(type: Type | null): boolean {
	const repr = valueCopyRepr(type);
	const t = repr != null && repr.kind == TypeKind.GenericInstance && repr.typeReturn != null && repr.typeReturn.kind == TypeKind.Union ? repr.typeReturn : repr;
	return isMaybeHeld(type) || (t != null && t.kind == TypeKind.Union && (t.typeFlags.has(TypeFlag.ValueUnion) || raiserFlatCellUnion(t)));
}

function isArrayType(type: Type | null): boolean {
	const t = valueCopyRepr(type);
	return t != null && t.kind == TypeKind.Array;
}

function isSizedArrayType(type: Type | null): boolean {
	const t = valueCopyRepr(type);
	return t != null && (t.kind == TypeKind.SizedArray || t.kind == TypeKind.Tuple);
}

const LIFTED_OPS: AttachedOp[] = [AttachedOp.AttachedDestructor, AttachedOp.AttachedWasMoved, AttachedOp.AttachedAsgn, AttachedOp.AttachedSink];

function runsDistinctHook(call: CallExprData, type: Type | null): boolean {
	const own = skipModifier(type);
	if (own == null || distinctBody(own) == null) return false;
	for (const op of LIFTED_OPS) {
		if (getOpByKey(own, op) == call.callee.resolvedSym) return true;
	}
	return false;
}

function isCellHook(call: CallExprData, flag: SymbolFlag): boolean {
	const sym = call.callee.resolvedSym;
	if (sym == null || !hasFlag(sym, SymbolFlag.GeneratedOp) || !hasFlag(sym, flag) || call.arguments.length != 1) return false;
	const type = placeOf(call.arguments[0]).nodeType;
	if (runsDistinctHook(call, type)) return false;
	return isCellType(type) || isSizedArrayType(type) || ((flag == SymbolFlag.WasMovedOp || flag == SymbolFlag.DestroyOp) && isArrayType(type));
}

function isLiftedCellOp(call: CallExprData, op: AttachedOp): boolean {
	const sym = call.callee.resolvedSym;
	if (sym == null || !hasFlag(sym, SymbolFlag.GeneratedOp) || call.arguments.length != 2) return false;
	const type = placeOf(call.arguments[0]).nodeType;
	return type != null && isCellType(type) && !runsDistinctHook(call, type) && getOpByKey(type, op) == sym;
}

function isSizedArrayCopy(call: CallExprData): boolean {
	const sym = call.callee.resolvedSym;
	if (sym == null || !hasFlag(sym, SymbolFlag.GeneratedOp) || call.arguments.length != 2) return false;
	const type = placeOf(call.arguments[0]).nodeType;
	return type != null && isSizedArrayType(type) && getOpByKey(type, AttachedOp.AttachedAsgn) == sym;
}

function isArraySink(call: CallExprData): boolean {
	const sym = call.callee.resolvedSym;
	if (sym == null || !hasFlag(sym, SymbolFlag.GeneratedOp) || call.arguments.length != 2) return false;
	const type = placeOf(call.arguments[0]).nodeType;
	return type != null && (isSizedArrayType(type) || isArrayType(type)) && !runsDistinctHook(call, type) && getOpByKey(type, AttachedOp.AttachedSink) == sym;
}

function isCopyIntoAggregate(call: CallExprData): boolean {
	const sym = call.callee.resolvedSym;
	if (sym == null || !hasFlag(sym, SymbolFlag.GeneratedOp) || call.arguments.length != 2) return false;
	const type = placeOf(call.arguments[0]).nodeType;
	if (type == null) return false;
	const body = valueCopyRepr(type);
	if (getOpByKey(type, AttachedOp.AttachedAsgn) != sym && (body == null || getOpByKey(body, AttachedOp.AttachedAsgn) != sym)) return false;
	return isCellType(type) || isArrayType(type);
}

function isLiftedCellSink(call: CallExprData): boolean {
	if (isArraySink(call)) return true;
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
		const movedByHook = s.hookMovedAt == codeLen(s) && s.hookMovedReg == localOfPlace(s, placeOf(d.arguments[0]));
		const held = refRegister(s, d.callee.resolvedSym!.name, d.arguments[0]);
		const isNil = allocBool(s);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, isNil, held, RaiserValueKind.Nil as number));
		const callHook = emitBranchIfFalsy(s, isNil);
		const toEnd = emitJumpPlaceholder(s);
		patchJumpTo(s, callHook, codeLen(s));
		compileExpr(s, call);
		if (movedByHook) emitInst(s, raiserABC(RaiserOpcode.WasMoved, held, 1, 0));
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
		emitClear(s, hookName, d.arguments[0], false);
		return true;
	}
	if (isLiftedCellOp(d, AttachedOp.AttachedAsgn) && isCopiedAsValue(placeOf(d.arguments[0]).nodeType) && userHookOf(placeOf(d.arguments[0]).nodeType!, AttachedOp.AttachedAsgn) == null) {
		emitCopyValue(s, d.callee.resolvedSym!.name, d.arguments[0], d.arguments[1]);
		return true;
	}
	if (isLiftedCellOp(d, AttachedOp.AttachedAsgn) || isLiftedCellOp(d, AttachedOp.AttachedSink) || isSizedArrayCopy(d) || isCopyIntoAggregate(d)) emitMaterialize(s, d.callee.resolvedSym!.name, d.arguments[0]);
	if (isLiftedCellOp(d, AttachedOp.AttachedSink)) {
		compileExpr(s, call);
		const source = localOfPlace(s, placeOf(d.arguments[1]));
		if (source >= 0) {
			if (userHookOf(placeOf(d.arguments[1]).nodeType!, AttachedOp.AttachedWasMoved) == null) emitInst(s, raiserABC(RaiserOpcode.WasMoved, source, 1, 0));
			else {
				s.hookMovedAt = codeLen(s);
				s.hookMovedReg = source;
			}
		}
		return true;
	}
	const row = ownershipRow(d.callee.resolvedSym);
	if (row == 0) return false;
	const name = ownershipName(d.callee.resolvedSym);
	if (row == ROW_COPY_VALUE && d.arguments.length == 1) {
		const source = refRegister(s, name, d.arguments[0]);
		const copied = emitValueCopy(s, source, placeOf(d.arguments[0]).nodeType);
		if (copied == source) emitInst(s, raiserABC(RaiserOpcode.RcInc, source, 0, 0));
		else if (localOfPlace(s, placeOf(d.arguments[0])) >= 0) emitInst(s, raiserABC(RaiserOpcode.Move, source, copied, 0));
		else emitPlaceStore(s, name, placeOf(d.arguments[0]), copied);
		return true;
	}
	if (row == ROW_COPY_VALUE && d.arguments.length != 2) throw new Error(`internal: Raiser has no lowering for ${name} with ${d.arguments.length} argument(s) in statement position`);
	if (row == ROW_INCREF) emitInst(s, raiserABC(RaiserOpcode.RcInc, refRegister(s, name, d.arguments[0]), 0, 0));
	else if (row == ROW_DECREF) {
		emitInst(s, raiserABC(RaiserOpcode.RcDec, refRegister(s, name, d.arguments[0]), 0, 0));
		if (localOfPlace(s, placeOf(d.arguments[0])) < 0) emitClear(s, name, d.arguments[0], false);
	}
	else if (row == ROW_DECREF_CYCLIC) emitInst(s, raiserABC(RaiserOpcode.RcDec, refRegister(s, name, d.arguments[0]), 1, 0));
	else if (row == ROW_CLEAR) emitClear(s, name, d.arguments[0]);
	else if (row == ROW_SINK) emitSink(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_KEPT) emitInst(s, raiserABC(RaiserOpcode.RcKeptCheck, refRegister(s, name, d.arguments[0]), compileExpr(s, d.arguments[1]), 0));
	else if (row == ROW_COPY_VALUE) emitCopyValue(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_SHARE) emitShare(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_STR_APPEND) emitAppend(s, name, d.arguments[0], compileExpr(s, d.arguments[1]));
	else if (row == ROW_STR_APPEND_CHAR) emitAppendChar(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_STR_APPEND_CODEPOINT) emitAppendCodePoint(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_SET_LEN) {
		const len = allocWord(s);
		emitInst(s, raiserABC(RaiserOpcode.ArrayLen, len, refRegister(s, name, d.arguments[1]), 0));
		const target = refRegister(s, name, d.arguments[0]);
		emitInst(s, raiserABC(RaiserOpcode.ArraySetLen, target, len, 0));
		emitZeroNilElements(s, target, placeOf(d.arguments[0]).nodeType);
	}
	else if (row != ROW_TRACE) throw new Error(`internal: ownership row ${row} of ${name} has no emitter`);
	return true;
}
