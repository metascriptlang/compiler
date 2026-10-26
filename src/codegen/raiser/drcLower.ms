import { Node, NodeKind, CallExprData, MemberExprData, ArrayAccessData, HiddenDerefData } from "../../ast/node";
import { RaiserOpcode, inRefFile, raiserABC } from "../../raiser/bytecode";
import { raiserNil, raiserConstString } from "../../raiser/value";
import { RaiserCompState, emitInst, allocRef, allocReg, classOfReg, resolveLocal, resolveGlobal, addConst, emitLoadConst, getRaiserModulePath } from "./context";
import { compileExpr, compileIndex } from "./expressions";
import { fieldInst } from "./valueCopy";
import {
	ROW_INCREF, ROW_DECREF, ROW_DECREF_CYCLIC, ROW_CLEAR, ROW_SINK, ROW_NO_LOWERING, ROW_SHARE,
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
		if (!inRefFile(classOfReg(s, local))) throw new Error(`internal: ${name} reached a register outside the ref file, and Raiser lowers it only there`);
		emitInst(s, raiserABC(RaiserOpcode.WasMoved, local, 0, 0));
		return;
	}
	const nil = allocRef(s);
	emitLoadConst(s, nil, raiserNil());
	emitPlaceStore(s, name, place, nil);
}

function emitSink(s: RaiserCompState, name: string, dest: Node, src: Node): void {
	const incoming = refRegister(s, name, src);
	const oldSource = refRegister(s, name, dest);
	const old = allocReg(s, classOfReg(s, oldSource));
	emitInst(s, raiserABC(RaiserOpcode.Move, old, oldSource, 0));
	emitPlaceStore(s, name, placeOf(dest), incoming);
	emitInst(s, raiserABC(RaiserOpcode.RcDec, old, 0, 0));
}

function emitShare(s: RaiserCompState, name: string, dest: Node, src: Node): void {
	const incoming = refRegister(s, name, src);
	emitInst(s, raiserABC(RaiserOpcode.RcInc, incoming, 0, 0));
	const oldSource = refRegister(s, name, dest);
	const old = allocReg(s, classOfReg(s, oldSource));
	emitInst(s, raiserABC(RaiserOpcode.Move, old, oldSource, 0));
	emitPlaceStore(s, name, placeOf(dest), incoming);
	emitInst(s, raiserABC(RaiserOpcode.RcDec, old, 0, 0));
}

export function compileOwnershipStmt(s: RaiserCompState, call: Node): boolean {
	if (call.kind != NodeKind.CallExpr) return false;
	const d = call.data as CallExprData;
	const row = ownershipRow(d.callee.resolvedSym);
	if (row == 0) return false;
	const name = ownershipName(d.callee.resolvedSym);
	if (row == ROW_NO_LOWERING) throw new Error(`internal: Raiser has no lowering for ${name}`);
	if (row == ROW_INCREF) emitInst(s, raiserABC(RaiserOpcode.RcInc, refRegister(s, name, d.arguments[0]), 0, 0));
	else if (row == ROW_DECREF) emitInst(s, raiserABC(RaiserOpcode.RcDec, refRegister(s, name, d.arguments[0]), 0, 0));
	else if (row == ROW_DECREF_CYCLIC) emitInst(s, raiserABC(RaiserOpcode.RcDec, refRegister(s, name, d.arguments[0]), 1, 0));
	else if (row == ROW_CLEAR) emitClear(s, name, d.arguments[0]);
	else if (row == ROW_SINK) emitSink(s, name, d.arguments[0], d.arguments[1]);
	else if (row == ROW_SHARE) emitShare(s, name, d.arguments[0], d.arguments[1]);
	else throw new Error(`internal: ownership row ${row} of ${name} has no emitter`);
	return true;
}
