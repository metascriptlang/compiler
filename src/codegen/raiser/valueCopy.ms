import { Type, TypeKind, TypeFlag } from "../../ast/node";
import { RaiserCopyPlan, RaiserCopyKind } from "../../raiser/valueCopy";
import { distinctBody } from "../../checker/types";
import { RaiserOpcode, raiserABC, raiserAx } from "../../raiser/bytecode";
import { RaiserValue, RaiserValueKind, raiserInt, raiserString, raiserFloat, raiserBool, raiserNil } from "../../raiser/value";
import { peelToRepr, unwrapRef } from "../../checker/types";
import { RaiserCompState, emitInst, allocReg, addConst, emitLoadConst, emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, codeLen, queueRaiserCompileError, emitTrapNil } from "./context";

function copyPlan(s: RaiserCompState, valueType: Type | null): int32 {
	const base = distinctBody(valueType);
	if (base != null) return copyPlan(s, base);
	if (valueType != null && valueType.kind == TypeKind.Alias) {
		return copyPlan(s, valueType.typeReturn);
	}
	if (valueType == null) return -1;
	for (let i = 0; i < s.copyTypes.length; i += 1) {
		if (s.copyTypes[i] == valueType) return i;
	}
	const plan: RaiserCopyPlan = { kind: RaiserCopyKind.Preserve, names: [], children: [] };
	const index = s.copyPlans.length;
	s.copyTypes.push(valueType);
	s.copyPlans.push(plan);
	if (valueType.kind == TypeKind.Array) {
		plan.kind = RaiserCopyKind.Array;
		plan.children.push(copyPlan(s, valueType.typeReturn));
	} else if (valueType.kind == TypeKind.Struct) {
		plan.kind = RaiserCopyKind.Object;
		for (let i = 0; i < valueType.typeNames.length; i += 1) {
			plan.names.push(valueType.typeNames[i]);
			plan.children.push(copyPlan(s, valueType.typeChildren[i]));
		}
	}
	return index;
}

export function emitValueCopy(
	s: RaiserCompState,
	source: int32,
	valueType: Type | null,
): int32 {
	const index = copyPlan(s, valueType);
	if (index < 0 || s.copyPlans[index].kind == RaiserCopyKind.Preserve) return source;
	const destination = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.CopyValue, destination, source, index));
	return destination;
}

export function needsValueAssign(s: RaiserCompState, valueType: Type | null): boolean {
	const index = copyPlan(s, valueType);
	return index >= 0 && s.copyPlans[index].kind != RaiserCopyKind.Preserve;
}

function valueShape(t: Type | null): Type | null {
	if (t != null && (t.kind == TypeKind.Alias || t.kind == TypeKind.Distinct)) return valueShape(t.typeReturn);
	if (t != null && t.kind == TypeKind.Struct && t.typeFlags.has(TypeFlag.IsMaybe)) return valueShape(t.typeReturn);
	return t;
}

// Assignment of a value into a location that already holds one writes into that
// location's object, so every pointer to the location keeps seeing it (NIM-REF CG-40).
export function emitValueAssign(s: RaiserCompState, destination: int32, source: int32, valueType: Type | null): int32 {
	const t = valueShape(valueType);
	if (t == null || !needsValueAssign(s, t)) return source;
	const index = copyPlan(s, t);
	const result = allocReg(s);
	const toEnd: int32[] = [];
	const sourceNil = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.IsKind, sourceNil, source, RaiserValueKind.Nil as number));
	const sourceHeld = emitBranchIfFalsy(s, sourceNil);
	emitInst(s, raiserABC(RaiserOpcode.Move, result, source, 0));
	toEnd.push(emitJumpPlaceholder(s));
	patchJumpTo(s, sourceHeld, codeLen(s));
	const destinationNil = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.IsKind, destinationNil, destination, RaiserValueKind.Nil as number));
	const destinationHeld = emitBranchIfFalsy(s, destinationNil);
	emitInst(s, raiserABC(RaiserOpcode.CopyValue, result, source, index));
	toEnd.push(emitJumpPlaceholder(s));
	patchJumpTo(s, destinationHeld, codeLen(s));
	if (t.kind == TypeKind.Struct) {
		for (let i = 0; i < t.typeNames.length; i += 1) {
			const name = addConst(s, raiserString(t.typeNames[i]));
			const fieldType = i < t.typeChildren.length ? t.typeChildren[i] : null;
			const held = allocReg(s);
			emitInst(s, raiserABC(RaiserOpcode.LoadField, held, destination, name));
			const next = allocReg(s);
			emitInst(s, raiserABC(RaiserOpcode.LoadField, next, source, name));
			emitInst(s, raiserABC(RaiserOpcode.StoreField, destination, name, emitValueAssign(s, held, next, fieldType)));
		}
	} else {
		const nextLen = allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.ArrayLen, nextLen, source, 0));
		emitInst(s, raiserABC(RaiserOpcode.ArraySetLen, destination, nextLen, 0));
		const at = allocReg(s);
		emitLoadConst(s, at, raiserInt(0));
		const one = allocReg(s);
		emitLoadConst(s, one, raiserInt(1));
		const loopStart = codeLen(s);
		emitInst(s, raiserABC(RaiserOpcode.BltI64, at, nextLen, 1));
		const toDone = emitJumpPlaceholder(s);
		const held = allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.LoadIndex, held, destination, at));
		const next = allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.LoadIndex, next, source, at));
		emitInst(s, raiserABC(RaiserOpcode.StoreIndex, destination, at, emitValueAssign(s, held, next, t.typeReturn)));
		emitInst(s, raiserABC(RaiserOpcode.AddI64, at, at, one));
		emitInst(s, raiserAx(RaiserOpcode.Jump, loopStart - codeLen(s) - 1));
		patchJumpTo(s, toDone, codeLen(s));
	}
	emitInst(s, raiserABC(RaiserOpcode.Move, result, destination, 0));
	for (const jump of toEnd) patchJumpTo(s, jump, codeLen(s));
	return result;
}

function zeroShape(t: Type | null): Type | null {
	if (t == null) return null;
	if (t.kind == TypeKind.Alias || t.kind == TypeKind.GenericInstance) return zeroShape(t.typeReturn);
	const repr = peelToRepr(t);
	if (repr == null || repr == t) return t;
	return zeroShape(repr);
}

function zeroScalar(t: Type | null): RaiserValue {
	if (t == null) return raiserNil();
	return match (t.kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 | TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 | TypeKind.Enum | TypeKind.Char => raiserInt(0),
		TypeKind.Number | TypeKind.Float32 | TypeKind.Float64 => raiserFloat(0),
		TypeKind.Boolean => raiserBool(false),
		TypeKind.String => raiserString(""),
		_ => raiserNil(),
	};
}

function isValueStruct(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Struct && !t.typeFlags.has(TypeFlag.IsMaybe);
}

function emitZeroOf(s: RaiserCompState, valueType: Type | null, open: Type[]): int32 {
	const t = zeroShape(valueType);
	if (t != null && (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray)) {
		const array = allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.NewArray, array, 0, 0));
		if (t.kind == TypeKind.SizedArray) {
			const count = allocReg(s);
			emitLoadConst(s, count, raiserInt(t.typeValue as int64));
			emitZeroElements(s, array, count, t.typeReturn, open);
		}
		return array;
	}
	if (t != null && isValueStruct(t)) {
		for (const outer of open) {
			if (outer == t) {
				const message = `struct '${t.typeName}' holds itself by value, so it has no zero value`;
				queueRaiserCompileError(message, 0, 0);
				return emitTrapNil(s, message);
			}
		}
		const object = allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.NewObject, object, 0, 0));
		open.push(t);
		for (let i = 0; i < t.typeNames.length; i += 1) {
			const field = emitZeroOf(s, i < t.typeChildren.length ? t.typeChildren[i] : null, open);
			emitInst(s, raiserABC(RaiserOpcode.StoreField, object, addConst(s, raiserString(t.typeNames[i])), field));
		}
		open.pop();
		return object;
	}
	const scalar = allocReg(s);
	emitLoadConst(s, scalar, zeroScalar(t));
	return scalar;
}

function emitZeroElements(s: RaiserCompState, array: int32, count: int32, elementType: Type | null, open: Type[]): void {
	const at = allocReg(s);
	emitLoadConst(s, at, raiserInt(0));
	const one = allocReg(s);
	emitLoadConst(s, one, raiserInt(1));
	const loopStart = codeLen(s);
	emitInst(s, raiserABC(RaiserOpcode.BltI64, at, count, 1));
	const toDone = emitJumpPlaceholder(s);
	const element = emitZeroOf(s, elementType, open);
	emitInst(s, raiserABC(RaiserOpcode.ArrayPush, array, element, 0));
	emitInst(s, raiserABC(RaiserOpcode.AddI64, at, at, one));
	emitInst(s, raiserAx(RaiserOpcode.Jump, loopStart - codeLen(s) - 1));
	patchJumpTo(s, toDone, codeLen(s));
}

export function emitZeroValue(s: RaiserCompState, valueType: Type | null): int32 {
	return emitZeroOf(s, valueType, []);
}

export function emitZeroFill(s: RaiserCompState, array: int32, count: int32, elementType: Type | null): void {
	emitZeroElements(s, array, count, elementType, []);
}

export function zeroArrayType(t: Type | null): Type | null {
	const shape = t != null ? zeroShape(unwrapRef(t)) : null;
	return shape != null && shape.kind == TypeKind.Array ? shape : null;
}

export function emitOmittedFieldZeros(s: RaiserCompState, object: int32, literalType: Type | null, keys: string[]): void {
	const t = literalType != null ? zeroShape(unwrapRef(literalType)) : null;
	if (t == null || !isValueStruct(t) || keys.includes("...")) return;
	for (let i = 0; i < t.typeNames.length; i += 1) {
		const name = t.typeNames[i];
		if (name.startsWith("__") || keys.includes(name)) continue;
		const field = emitZeroValue(s, i < t.typeChildren.length ? t.typeChildren[i] : null);
		emitInst(s, raiserABC(RaiserOpcode.StoreField, object, addConst(s, raiserString(name)), field));
	}
}
