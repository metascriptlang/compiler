import { Type, TypeKind, TypeFlag, AttachedOp } from "../../ast/node";
import { userHookOf } from "../../transform/lowering/destructorLifting";
import { getOpByKey } from "../c/types";
import { isSlotUnion } from "../../checker/fit";
import { raiserFlatCellUnion } from "../../analyzer/classify";
import { RaiserCopyPlan, RaiserCopyKind } from "../../raiser/valueCopy";
import { distinctBody, enumMemberValue, isMaybeType, isStructType, needsValueCopy, valueCopyRepr, skipModifier, peelToStructOrUnion, setRepr, isAwaitable, numberLiteralBase, literalBase } from "../../checker/types";
import { RaiserOpcode, RaiserInstruction, RaiserRegClass, raiserABC, raiserAx, MAX_SLOT, arrayClassSlot, ElemWidth } from "../../raiser/bytecode";
import { MemKind, memKindOf } from "../../raiser/layout";
import { RaiserValue, RaiserValueKind, createClassType, raiserInt, raiserConstString, raiserFloat, raiserBool, raiserNil, RAISER_NO_CLASS } from "../../raiser/value";
import { isMetaWireSym } from "../../compiler/meta/nodeSym";
import { peelToRepr, unwrapRef, isUncountedElement, getElementType, isPlainFunctionPointer } from "../../checker/types";
import { createNameSet } from "../../transform/context";
import { canFormAcycle } from "../../transform/cycles";
import { RaiserCompState, emitInst, allocReg, allocWord, allocBool, allocRef, allocDyn, classOfReg, addConst, emitLoadConst, classOfConstant, emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, codeLen, queueRaiserCompileError, emitTrap, emitTrapNil, resolveRoutine, slotInst, CLOSURE_PAIR, CLOSURE_PAIR_KINDS, classSymOfType } from "./context";

function copyPlan(s: RaiserCompState, valueType: Readonly<Type | null>): int32 {
	const base = distinctBody(valueType);
	if (base != null) return copyPlan(s, base);
	if (valueType != null && valueType.kind == TypeKind.Alias) {
		return copyPlan(s, valueType.typeReturn);
	}
	if (valueType != null && (valueType.kind == TypeKind.GenericInstance || isMaybeType(valueType))) {
		const repr = valueCopyRepr(valueType);
		if (repr != valueType) return copyPlan(s, repr);
	}
	if (valueType == null) return -1;
	for (let i = 0; i < s.copyTypes.length; i += 1) {
		if (s.copyTypes[i] == valueType) return i;
	}
	const plan: RaiserCopyPlan = { kind: RaiserCopyKind.Preserve, names: [], children: [], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] };
	const index = s.copyPlans.length;
	s.copyTypes.push(valueType);
	s.copyPlans.push(plan);
	if (valueType.kind == TypeKind.Array || valueType.kind == TypeKind.SizedArray) {
		plan.kind = RaiserCopyKind.Array;
		plan.children.push(copyPlan(s, valueType.typeReturn));
	} else if (valueType.kind == TypeKind.Struct) {
		plan.kind = RaiserCopyKind.Object;
		for (let i = 0; i < valueType.typeNames.length; i += 1) {
			plan.names.push(valueType.typeNames[i]);
			plan.children.push(copyPlan(s, valueType.typeChildren[i]));
		}
	} else if (valueType.kind == TypeKind.Union && raiserFlatCellUnion(valueType)) {
		plan.kind = RaiserCopyKind.Object;
		for (const arm of valueType.typeChildren) {
			if (arm.kind == TypeKind.Function) continue;
			for (let i = 0; i < arm.typeNames.length; i += 1) {
				const child = copyPlan(s, arm.typeChildren[i]);
				const at = plan.names.indexOf(arm.typeNames[i]);
				if (at < 0) {
					plan.names.push(arm.typeNames[i]);
					plan.children.push(child);
				} else if (plan.children[at] != child) {
					if (s.copyPlans[plan.children[at]].kind != RaiserCopyKind.Preserve) throw new Error(`internal: the arms of union '${valueType.typeName}' give field '${arm.typeNames[i]}' different copy plans`);
					plan.children[at] = child;
				}
			}
		}
	} else if (valueType.kind == TypeKind.Union && needsValueCopy(valueType)) {
		plan.kind = RaiserCopyKind.Union;
		plan.names.push(valueType.typeNames[0]);
		for (let i = 0; i < valueType.typeChildren.length; i += 1) {
			plan.discriminants.push(armDiscriminant(valueType, valueType.typeNames[i + 1]));
			plan.children.push(copyPlan(s, valueType.typeChildren[i]));
		}
	}
	return index;
}

function armDiscriminant(union: Readonly<Type>, key: string): int64 {
	const discriminant = union.typeExtra as Readonly<Type>;
	if (discriminant.kind == TypeKind.Boolean) return key == "true" ? 1 : 0;
	const member = key.slice(key.lastIndexOf(".") + 1);
	const at = discriminant.typeNames.indexOf(member);
	if (at < 0) throw new Error(`internal: value union '${union.typeName}' names arm '${key}', which is no member of its discriminant enum`);
	return enumMemberValue(discriminant, at as int32);
}

export function emitValueCopy(
	s: RaiserCompState,
	source: int32,
	valueType: Readonly<Type | null>,
): int32 {
	const index = copyPlan(s, valueType);
	if (index < 0 || s.copyPlans[index].kind == RaiserCopyKind.Preserve) return source;
	const destination = allocReg(s, classOfReg(s, source));
	emitInst(s, raiserABC(RaiserOpcode.CopyValue, destination, source, index));
	return destination;
}

export function needsValueAssign(s: RaiserCompState, valueType: Type | null): boolean {
	const index = copyPlan(s, valueType);
	if (index < 0) return false;
	const kind = s.copyPlans[index].kind;
	return kind == RaiserCopyKind.Array || kind == RaiserCopyKind.Object;
}

function valueShape(t: Type | null): Type | null {
	if (t != null && (t.kind == TypeKind.Alias || t.kind == TypeKind.Distinct)) return valueShape(t.typeReturn);
	if (t != null && t.kind == TypeKind.Struct && t.typeFlags.has(TypeFlag.IsMaybe)) return valueShape(t.typeReturn);
	if (t != null && t.kind == TypeKind.GenericInstance && isStructType(t.typeReturn)) return valueShape(t.typeReturn);
	return t;
}

// Assignment of a value into a location that already holds one writes into that
// location's object, so every pointer to the location keeps seeing it (NIM-REF CG-40).
export function emitValueAssign(s: RaiserCompState, destination: int32, source: int32, valueType: Type | null): int32 {
	const t = valueShape(valueType);
	if (t == null) return source;
	if (!needsValueAssign(s, t)) return source;
	const result = allocRef(s);
	const toEnd: int32[] = [];
	const sourceNil = allocBool(s);
	emitInst(s, raiserABC(RaiserOpcode.IsKind, sourceNil, source, RaiserValueKind.Nil as number));
	const sourceHeld = emitBranchIfFalsy(s, sourceNil);
	emitInst(s, raiserABC(RaiserOpcode.Move, result, source, 0));
	toEnd.push(emitJumpPlaceholder(s));
	patchJumpTo(s, sourceHeld, codeLen(s));
	const destinationNil = allocBool(s);
	emitInst(s, raiserABC(RaiserOpcode.IsKind, destinationNil, destination, RaiserValueKind.Nil as number));
	const destinationHeld = emitBranchIfFalsy(s, destinationNil);
	emitInst(s, raiserABC(RaiserOpcode.Move, result, source, 0));
	toEnd.push(emitJumpPlaceholder(s));
	patchJumpTo(s, destinationHeld, codeLen(s));
	if (t.kind == TypeKind.Struct) {
		for (let i = 0; i < t.typeNames.length; i += 1) {
			const name = addConst(s, raiserConstString(t.typeNames[i]));
			const fieldType = i < t.typeChildren.length ? t.typeChildren[i] : null;
			const held = allocFor(s, fieldType);
			emitInst(s, fieldInst(s, t, t.typeNames[i], RaiserOpcode.LoadField, RaiserOpcode.LoadSlot, held, destination, name));
			const next = allocFor(s, fieldType);
			emitInst(s, fieldInst(s, t, t.typeNames[i], RaiserOpcode.LoadField, RaiserOpcode.LoadSlot, next, source, name));
			const assigned = emitValueAssign(s, held, next, fieldType);
			emitInst(s, fieldInst(s, t, t.typeNames[i], RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, destination, name, assigned));
		}
	} else {
		const nextLen = allocWord(s);
		emitInst(s, raiserABC(RaiserOpcode.ArrayLen, nextLen, source, 0));
		emitInst(s, raiserABC(RaiserOpcode.ArraySetLen, destination, nextLen, 0));
		const at = allocWord(s);
		emitLoadConst(s, at, raiserInt(0));
		const one = allocWord(s);
		emitLoadConst(s, one, raiserInt(1));
		const loopStart = codeLen(s);
		emitInst(s, raiserABC(RaiserOpcode.BltI64, at, nextLen, 1));
		const toDone = emitJumpPlaceholder(s);
		const held = allocDyn(s);
		emitInst(s, raiserABC(RaiserOpcode.LoadIndex, held, destination, at));
		const next = allocFor(s, t.typeReturn);
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

export function isInPlaceCell(s: RaiserCompState, valueType: Type | null): boolean {
	const t = valueShape(valueType);
	return t != null && t.kind == TypeKind.Struct && needsValueAssign(s, t);
}

export function aggregateAssignPlan(s: RaiserCompState, valueType: Type | null): int32 {
	const t = valueShape(valueType);
	if (t == null) return -1;
	if (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray) return copyPlan(s, t);
	if (t.kind == TypeKind.Union && isUnionCell(t) && userHookOf(t, AttachedOp.AttachedDestructor) == null) return copyPlan(s, t);
	return -1;
}

export function emitAggregateAssign(s: RaiserCompState, destination: int32, source: int32, valueType: Type | null, sourceIsFresh: boolean): int32 {
	const plan = aggregateAssignPlan(s, valueType);
	if (plan < 0 && !isInPlaceCell(s, valueType)) return -1;
	const incoming = sourceIsFresh ? source : emitValueCopy(s, source, valueType);
	if (plan < 0) {
		emitCellSwap(s, destination, incoming, valueType);
		emitInst(s, raiserABC(RaiserOpcode.RcDec, incoming, 0, 0));
		return destination;
	}
	emitInst(s, raiserABC(RaiserOpcode.AssignInPlace, destination, incoming, plan));
	return destination;
}

export function isNilBranch(s: RaiserCompState, reg: int32): int32 {
	const isNil = allocBool(s);
	emitInst(s, raiserABC(RaiserOpcode.IsKind, isNil, reg, RaiserValueKind.Nil as number));
	return emitBranchIfFalsy(s, isNil);
}

export function emitCellSwap(s: RaiserCompState, destination: int32, source: int32, valueType: Type | null): void {
	const t = valueShape(valueType);
	if (t == null || t.kind != TypeKind.Struct) throw new Error("internal: Raiser exchanges the cells of a struct only");
	for (let i = 0; i < t.typeNames.length; i += 1) {
		const fieldType = i < t.typeChildren.length ? t.typeChildren[i] : null;
		const name = addConst(s, raiserConstString(t.typeNames[i]));
		const held = allocFor(s, fieldType);
		emitInst(s, fieldInst(s, t, t.typeNames[i], RaiserOpcode.LoadField, RaiserOpcode.LoadSlot, held, destination, name));
		const next = allocFor(s, fieldType);
		emitInst(s, fieldInst(s, t, t.typeNames[i], RaiserOpcode.LoadField, RaiserOpcode.LoadSlot, next, source, name));
		const toNext: int32[] = [];
		const toExchange: int32[] = [];
		if (isInPlaceCell(s, fieldType)) {
			const heldPresent = isNilBranch(s, held);
			toExchange.push(emitJumpPlaceholder(s));
			patchJumpTo(s, heldPresent, codeLen(s));
			const nextPresent = isNilBranch(s, next);
			toExchange.push(emitJumpPlaceholder(s));
			patchJumpTo(s, nextPresent, codeLen(s));
			emitCellSwap(s, held, next, fieldType);
			toNext.push(emitJumpPlaceholder(s));
		}
		for (const jump of toExchange) patchJumpTo(s, jump, codeLen(s));
		emitInst(s, fieldInst(s, t, t.typeNames[i], RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, destination, name, next));
		emitInst(s, fieldInst(s, t, t.typeNames[i], RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, source, name, held));
		for (const jump of toNext) patchJumpTo(s, jump, codeLen(s));
	}
}

function zeroShape(t: Type | null): Type | null {
	if (t == null) return null;
	if (t.kind == TypeKind.Alias || t.kind == TypeKind.GenericInstance) return zeroShape(t.typeReturn);
	const repr = peelToRepr(t);
	if (repr == null || repr == t) return t;
	return zeroShape(repr);
}

export function zeroScalar(t: Type | null): RaiserValue {
	if (t == null) return raiserNil();
	if (isPlainFunctionPointer(t)) return raiserInt(0);
	return match (literalBase(t).kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 | TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 | TypeKind.Enum | TypeKind.Char => raiserInt(0),
		TypeKind.Number | TypeKind.Float32 | TypeKind.Float64 => raiserFloat(0),
		TypeKind.Boolean => raiserBool(false),
		TypeKind.String => raiserConstString(""),
		_ => raiserNil(),
	};
}

function isValueStruct(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Struct && !t.typeFlags.has(TypeFlag.IsMaybe);
}

export function structShapeOperand(s: RaiserCompState, t: Type | null, fields: string[], kinds: RaiserRegClass[]): int32 {
	const body = t != null && t.kind == TypeKind.GenericInstance && t.typeReturn != null ? t.typeReturn : t;
	const destroyOp = t != null && body != null && (body.kind != TypeKind.Union || userHookOf(t, AttachedOp.AttachedDestructor) != null) ? getOpByKey(t, AttachedOp.AttachedDestructor) : null;
	if (fields.length == 0 && destroyOp == null) return 0;
	const classType = createClassType("", -1, [], fields, kinds);
	const cyclic = slotCyclicOf(t);
	for (let i = 0; i < cyclic.length && i < classType.cyclic.length; i += 1) classType.cyclic[i] = cyclic[i];
	const uncounted = slotUncountedOf(t);
	for (let i = 0; i < uncounted.length && i < classType.uncounted.length; i += 1) classType.uncounted[i] = uncounted[i];
	if (destroyOp != null) classType.destroyFn = resolveRoutine(s, destroyOp);
	s.classTypes.push(classType);
	return s.classTypes.length;
}

function emitZeroOf(s: RaiserCompState, valueType: Type | null, open: Type[]): int32 {
	const t = zeroShape(valueType);
	if (t != null && (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray)) {
		const array = allocRef(s);
		emitInst(s, newArrayInst(s, array, 0, t.typeReturn));
		if (t.kind == TypeKind.SizedArray) {
			const count = allocWord(s);
			emitLoadConst(s, count, raiserInt(t.typeValue as int64));
			emitZeroElements(s, array, count, t.typeReturn, open);
		}
		return array;
	}
	if (t != null && t.kind == TypeKind.Tuple) {
		const tuple = allocRef(s);
		emitInst(s, newArrayInst(s, tuple, 0, getElementType(t)));
		for (const member of t.typeChildren) {
			emitInst(s, raiserABC(RaiserOpcode.ArrayPush, tuple, emitZeroOf(s, member, open), 0));
		}
		return tuple;
	}
	if (t != null && isValueStruct(t)) {
		for (const outer of open) {
			if (outer == t) {
				const message = `struct '${t.typeName}' holds itself by value, so it has no zero value`;
				queueRaiserCompileError(message, 0, 0);
				return emitTrapNil(s, message);
			}
		}
		const object = allocRef(s);
		emitInst(s, raiserABC(RaiserOpcode.NewObject, object, structShapeOperand(s, valueType, t.typeNames, slotClassesOf(s, t)), 0));
		open.push(t);
		for (let i = 0; i < t.typeNames.length; i += 1) {
			const field = emitZeroOf(s, i < t.typeChildren.length ? t.typeChildren[i] : null, open);
			emitInst(s, fieldInst(s, t, t.typeNames[i], RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, object, addConst(s, raiserConstString(t.typeNames[i])), field));
		}
		open.pop();
		return object;
	}
	const zero = zeroScalar(t);
	const scalar = allocReg(s, classOfConstant(zero));
	emitLoadConst(s, scalar, zero);
	return scalar;
}

function emitZeroElements(s: RaiserCompState, array: int32, count: int32, elementType: Type | null, open: Type[]): void {
	const at = allocWord(s);
	emitLoadConst(s, at, raiserInt(0));
	const one = allocWord(s);
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

export function emitTrapValue(s: RaiserCompState, message: string, valueType: Type | null): int32 {
	emitTrap(s, message);
	return emitZeroValue(s, valueType);
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
		if (keys.includes(name)) continue;
		const field = emitZeroValue(s, i < t.typeChildren.length ? t.typeChildren[i] : null);
		emitInst(s, fieldInst(s, t, name, RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, object, addConst(s, raiserConstString(name)), field));
	}
}

const MAX_TYPE_DEPTH = 32;

function isStructSlotUnion(t: Type): boolean {
	if (!isSlotUnion(t)) return false;
	let structs = 0;
	for (const child of t.typeChildren) {
		if (child.kind == TypeKind.Struct) structs += 1;
		else if (child.kind != TypeKind.Function) return false;
	}
	return structs > 0;
}

export function isUnionCell(t: Type): boolean {
	const body = t.kind == TypeKind.GenericInstance && t.typeReturn != null ? t.typeReturn : t;
	return body.kind == TypeKind.Union && (body.typeFlags.has(TypeFlag.ValueUnion) || isStructSlotUnion(body));
}

export function heldByLocation(s: RaiserCompState, pointee: Type | null): boolean {
	const t = skipModifier(pointee);
	if (t == null) return false;
	if (isMaybeType(t)) return true;
	if (t.kind == TypeKind.GenericInstance) {
		const body = peelToStructOrUnion(t);
		if (body != null && body.kind == TypeKind.Struct) return false;
	}
	if (isUnionCell(t) || t.kind == TypeKind.SizedArray) return false;
	return !needsValueAssign(s, t);
}

export function joinClass(a: RaiserRegClass, b: RaiserRegClass): RaiserRegClass {
	return a == b ? a : RaiserRegClass.Dyn;
}

export function regClassOf(s: RaiserCompState, t: Type | null): RaiserRegClass {
	return classOfType(s, t, 0);
}

// The register class of each field of a struct shape, in the order of its names: the class its slot holds.
export function slotClassesOf(s: RaiserCompState, shape: Type): RaiserRegClass[] {
	const kinds: RaiserRegClass[] = [];
	for (let i = 0; i < shape.typeNames.length; i += 1) kinds.push(i < shape.typeChildren.length ? regClassOf(s, shape.typeChildren[i]) : RaiserRegClass.Dyn);
	return kinds;
}

// Every object of a struct, interface or class type holds its fields in the order
// of `typeNames`, which puts a parent's fields first; a structural match is a prefix
// of it. A function value is a closure pair. NewObject lays that order out, so the
// type fixes each field's slot.
export function layoutOf(t: Type | null): string[] {
	if (isMetaWireSym(classSymOfType(skipModifier(t)))) return [];
	const bare = skipModifier(t);
	if (bare != null && bare.kind == TypeKind.Function && !isPlainFunctionPointer(bare)) return CLOSURE_PAIR;
	const shape = peelToStructOrUnion(t);
	return shape != null && shape.kind == TypeKind.Struct && !isMaybeType(shape) ? shape.typeNames : [];
}

// Per slot of layoutOf(t): a cursor field borrows its referent.
export function slotUncountedOf(t: Type | null): boolean[] {
	const shape = peelToStructOrUnion(t);
	const flags: boolean[] = [];
	if (shape == null || shape.kind != TypeKind.Struct || isMaybeType(shape)) return flags;
	for (let i = 0; i < shape.typeNames.length; i += 1) flags.push(i < shape.typeChildren.length && isUncountedElement(shape.typeChildren[i]));
	return flags;
}

const cyclicTypes = createNameSet();
const acyclicTypes = createNameSet();

export function isCyclicType(t: Type | null): boolean {
	return canFormAcycle(t, cyclicTypes, acyclicTypes);
}

export function slotCyclicOf(t: Type | null): boolean[] {
	const shape = peelToStructOrUnion(t);
	const flags: boolean[] = [];
	if (shape == null || shape.kind != TypeKind.Struct || isMaybeType(shape)) return flags;
	for (let i = 0; i < shape.typeNames.length; i += 1) flags.push(i < shape.typeChildren.length && isCyclicType(shape.typeChildren[i]));
	return flags;
}

// The register class each slot of layoutOf(t) holds.
export function slotKindsOf(s: RaiserCompState, t: Type | null): RaiserRegClass[] {
	if (isMetaWireSym(classSymOfType(skipModifier(t)))) return [];
	const bare = skipModifier(t);
	if (bare != null && bare.kind == TypeKind.Function && !isPlainFunctionPointer(bare)) return CLOSURE_PAIR_KINDS;
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

// An array holds its elements in the register class of their type, each as wide in memory as the type is.
function elemWidthOf(cls: RaiserRegClass, t: Type | null): ElemWidth {
	if (t == null || (cls != RaiserRegClass.Word && cls != RaiserRegClass.Float && cls != RaiserRegClass.Bool)) return ElemWidth.Wide;
	const kind = memKindOf(t);
	if (cls == RaiserRegClass.Float) return kind == MemKind.F32 ? ElemWidth.F32 : ElemWidth.Wide;
	if (cls == RaiserRegClass.Bool) return ElemWidth.U8;
	return match (kind) {
		MemKind.I32 => ElemWidth.I32,
		MemKind.I16 => ElemWidth.I16,
		MemKind.I8 => ElemWidth.I8,
		MemKind.U32 => ElemWidth.U32,
		MemKind.U16 => ElemWidth.U16,
		MemKind.U8 => ElemWidth.U8,
		_ => ElemWidth.Wide,
	};
}

export function newArrayInst(s: RaiserCompState, dest: number, count: number, elementType: Type | null): RaiserInstruction {
	const cls = regClassOf(s, elementType);
	return slotInst(RaiserOpcode.NewArray, dest, count, 0, arrayClassSlot(cls, isCyclicType(elementType), isUncountedElement(elementType), elemWidthOf(cls, elementType)));
}

export function allocFor(s: RaiserCompState, t: Type | null): int32 {
	return allocReg(s, regClassOf(s, t));
}

function classOfUnion(s: RaiserCompState, t: Type, depth: int32): RaiserRegClass {
	if (t.typeChildren.length == 0) return RaiserRegClass.Dyn;
	let joined = classOfType(s, t.typeChildren[0], depth + 1);
	for (let i = 1; i < t.typeChildren.length; i += 1) joined = joinClass(joined, classOfType(s, t.typeChildren[i], depth + 1));
	return joined != RaiserRegClass.Ref && joined != RaiserRegClass.Dyn && t.typeChildren.length > 1 ? RaiserRegClass.Dyn : joined;
}

function classOfType(s: RaiserCompState, t: Type | null, depth: int32): RaiserRegClass {
	if (t == null) return RaiserRegClass.Dyn;
	if (depth > MAX_TYPE_DEPTH) throw new Error(`internal: a type nested deeper than ${MAX_TYPE_DEPTH} levels has no register class`);
	if (isPlainFunctionPointer(t)) return RaiserRegClass.Word;
	return match (t.kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
			| TypeKind.Char | TypeKind.Enum | TypeKind.EnumLiteral => RaiserRegClass.Word,
		TypeKind.Number | TypeKind.Float32 | TypeKind.Float64 => RaiserRegClass.Float,
		TypeKind.Boolean | TypeKind.BooleanLiteral => RaiserRegClass.Bool,
		TypeKind.String | TypeKind.StringLiteral | TypeKind.CString | TypeKind.Null
			| TypeKind.Array | TypeKind.SizedArray | TypeKind.Span | TypeKind.Function | TypeKind.Tuple | TypeKind.Varargs => RaiserRegClass.Ref,
		TypeKind.Struct => {
			if (!t.typeFlags.has(TypeFlag.IsMaybe) || t.typeReturn == null) return RaiserRegClass.Ref;
			const held = classOfType(s, t.typeReturn, depth + 1);
			return held == RaiserRegClass.Ref ? RaiserRegClass.Ref : RaiserRegClass.Dyn;
		},
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Var | TypeKind.Borrow => {
			if (t.kind == TypeKind.Ptr && skipModifier(t.typeReturn) != null && skipModifier(t.typeReturn)!.kind == TypeKind.Void) return RaiserRegClass.Ref;
			if (heldByLocation(s, t.typeReturn)) return RaiserRegClass.Dyn;
			return classOfType(s, t.typeReturn, depth + 1);
		},
		TypeKind.Sink | TypeKind.Lent | TypeKind.Cursor | TypeKind.Alias | TypeKind.Distinct => classOfType(s, t.typeReturn, depth + 1),
		TypeKind.NumberLiteral => classOfType(s, numberLiteralBase(t), depth + 1),
		TypeKind.GenericInstance => {
			if (isAwaitable(t)) return RaiserRegClass.Dyn;
			const repr = distinctBody(t);
			if (repr != null) return classOfType(s, repr, depth + 1);
			const body = peelToStructOrUnion(t);
			if (body != null) return classOfType(s, body, depth + 1);
			return t.typeReturn != null ? classOfType(s, t.typeReturn, depth + 1) : RaiserRegClass.Ref;
		},
		TypeKind.Union => classOfUnion(s, t, depth),
		TypeKind.Set => classOfType(s, setRepr(t), depth + 1),
		TypeKind.Pending | TypeKind.GenericParam | TypeKind.TypeReference | TypeKind.Result | TypeKind.Error
			| TypeKind.Conditional | TypeKind.Void | TypeKind.Unknown | TypeKind.Never | TypeKind.None | TypeKind.Inferred | TypeKind.BigInt
			| TypeKind.Module | TypeKind.IndexedAccess | TypeKind.KeyOf | TypeKind.Mapped => RaiserRegClass.Dyn,
		_ => { throw new Error(`internal: type kind ${t.kind} has no register class`); },
	};
}
