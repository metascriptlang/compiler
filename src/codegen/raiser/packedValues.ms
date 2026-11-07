import { Type, TypeKind } from "../../ast/node";
import {
	storesNothing, typeKey, isMaybeType, literalBase,
	getElementType, enumMemberValue,
} from "../../checker/types";
import { raiserPackedEligible } from "../../analyzer/classify";
import { MemKind } from "../../raiser/layout";
import {
	RaiserSlotShape, RaiserRegClass, RaiserOpcode, RaiserConvClass,
	raiserABC, convOperand,
} from "../../raiser/bytecode";
import {
	RaiserValueKind, raiserInt, raiserFloat, raiserBool, raiserConstString,
} from "../../raiser/value";
import { VmLayouts, vmLayoutOf } from "./layout";
import {
	packedSlotShapeOf, regClassOf, zeroScalar, structShapeOperand,
	slotClassesOf, fieldInst, newArrayInst,
} from "./valueCopy";
import {
	RaiserCompState, allocPackedBlock, allocReg, allocWord, allocBool,
	allocDyn, allocRef, classOfReg, emitInst, emitLoadConst, addConst,
	slotInst, emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo,
	codeLen, emitTrap,
} from "./context";

export interface RaiserFramePlace {
	base: int32;
	offset: int32;
	valueType: Type;
	whole: boolean;
	words: int32;
}

export interface RaiserLegacyValue {
	reg: int32;
	valueType: Type;
	shape: RaiserSlotShape;
}

export function bodyOf(t: Type): Type {
	let body = t;
	while ((body.kind == TypeKind.Alias || body.kind == TypeKind.Distinct ||
		body.kind == TypeKind.GenericInstance) && body.typeReturn != null) {
		body = body.typeReturn;
	}
	return body;
}

function integerIn(value: number, low: number, high: number): boolean {
	return value >= low && value <= high &&
		value == ((value as int32) as number);
}

function validatePlace(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
): void {
	if (!integerIn(place.base, 0, 65535) ||
		!integerIn(place.words, 1, 65535) ||
		!integerIn(place.offset, 0, place.words * 8) ||
		place.base + place.words > s.regClasses.length ||
		!raiserPackedEligible(place.valueType)) {
		throw new Error("internal: invalid packed frame place");
	}
	const size = vmLayoutOf(layouts, place.valueType).size;
	if (size > place.words * 8 - place.offset ||
		place.whole && (place.offset != 0 ||
			place.words != Math.max(1, Math.ceil((size as number) / 8)))) {
		throw new Error("internal: packed place exceeds its backing extent");
	}
	for (let i = 0; i < place.words; i += 1) {
		if (classOfReg(s, place.base + i) != RaiserRegClass.Word) {
			throw new Error("internal: packed backing is not opaque Word storage");
		}
	}
}

export function packedFramePlace(
	s: RaiserCompState, layouts: VmLayouts, base: int32, valueType: Type,
	actualShape: RaiserSlotShape,
): RaiserFramePlace {
	const expected = packedSlotShapeOf(layouts, valueType);
	if (expected == null || !actualShape.block ||
		actualShape.words != expected.words) {
		throw new Error("internal: packed frame storage shape mismatch");
	}
	const place: RaiserFramePlace = {
		base, offset: 0, valueType, whole: true,
		words: actualShape.words as int32,
	};
	validatePlace(s, layouts, place);
	return place;
}

export function allocPackedValue(
	s: RaiserCompState, layouts: VmLayouts, valueType: Type,
): RaiserFramePlace {
	const shape = packedSlotShapeOf(layouts, valueType);
	if (shape == null) throw new Error("internal: value has no packed block shape");
	const place = packedFramePlace(s, layouts, allocPackedBlock(s, shape),
		valueType, shape);
	emitInst(s, raiserABC(RaiserOpcode.ZeroN, place.base, place.words, 0));
	return place;
}

function subplace(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
	offset: int32, valueType: Type,
): RaiserFramePlace {
	const next: RaiserFramePlace = {
		base: place.base, words: place.words, whole: false,
		offset: place.offset + offset, valueType,
	};
	validatePlace(s, layouts, next);
	if (offset < 0 || offset + vmLayoutOf(layouts, valueType).size >
		vmLayoutOf(layouts, place.valueType).size) {
		throw new Error("internal: packed projection exceeds its parent");
	}
	return next;
}

export function packedField(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
	name: string,
): RaiserFramePlace {
	validatePlace(s, layouts, place);
	const body = bodyOf(place.valueType);
	if (body.kind != TypeKind.Struct) {
		throw new Error("internal: packed field requires a record");
	}
	const at = body.typeNames.indexOf(name);
	if (at < 0 || storesNothing(body, body.typeChildren[at])) {
		throw new Error("internal: packed field has no stored location");
	}
	const layout = vmLayoutOf(layouts, place.valueType);
	for (const slot of layout.slots) {
		if (slot.name == name) {
			return subplace(s, layouts, place, slot.offset, body.typeChildren[at]);
		}
	}
	throw new Error("internal: packed field is missing native layout metadata");
}

export function packedIndex(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
	index: number,
): RaiserFramePlace {
	validatePlace(s, layouts, place);
	const body = bodyOf(place.valueType);
	if (body.kind != TypeKind.Tuple && body.kind != TypeKind.SizedArray) {
		throw new Error("internal: packed index requires a fixed aggregate");
	}
	const count = body.kind == TypeKind.Tuple
		? body.typeChildren.length : body.typeValue;
	if (!integerIn(index, 0, count - 1)) {
		throw new Error("internal: packed fixed index out of bounds");
	}
	if (body.kind == TypeKind.SizedArray && body.typeReturn != null) {
		return subplace(s, layouts, place,
			(index * vmLayoutOf(layouts, body.typeReturn).size) as int32,
			body.typeReturn);
	}
	if (!storesNothing(body, body.typeChildren[index])) {
		for (const slot of vmLayoutOf(layouts, body).slots) {
			if (slot.name == `_${index}`) {
				return subplace(s, layouts, place, slot.offset, body.typeChildren[index]);
			}
		}
	}
	throw new Error("internal: packed tuple index has no storage");
}

function scalarClass(t: Type, kind: MemKind): RaiserRegClass {
	if (kind == MemKind.Block || kind == MemKind.Ptr) {
		throw new Error("internal: packed scalar operation requires a scalar");
	}
	if (kind == MemKind.F32 || kind == MemKind.F64) return RaiserRegClass.Float;
	const body = literalBase(bodyOf(t));
	return body.kind == TypeKind.Boolean ? RaiserRegClass.Bool
		: RaiserRegClass.Word;
}

function frameLoad(
	s: RaiserCompState, base: int32, offset: int32, kind: MemKind,
	cls: RaiserRegClass,
): int32 {
	const result = allocReg(s, cls);
	emitInst(s, slotInst(RaiserOpcode.LoadFrame, result,
		base + offset / 8, offset % 8, kind as int32));
	return result;
}

function frameStore(
	s: RaiserCompState, base: int32, offset: int32, kind: MemKind,
	value: int32,
): void {
	emitInst(s, slotInst(RaiserOpcode.StoreFrame, base + offset / 8,
		offset % 8, value, kind as int32));
}

export function emitPackedLoad(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
): int32 {
	validatePlace(s, layouts, place);
	const kind = vmLayoutOf(layouts, place.valueType).kind;
	return frameLoad(s, place.base, place.offset, kind,
		scalarClass(place.valueType, kind));
}

export function emitPackedStore(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
	value: int32,
): void {
	validatePlace(s, layouts, place);
	const kind = vmLayoutOf(layouts, place.valueType).kind;
	if (classOfReg(s, value) != scalarClass(place.valueType, kind)) {
		throw new Error("internal: packed scalar register class mismatch");
	}
	frameStore(s, place.base, place.offset, kind, value);
}

function rawKind(width: int32): MemKind {
	return match (width) {
		8 => MemKind.U64,
		4 => MemKind.U32,
		2 => MemKind.U16,
		_ => MemKind.U8,
	};
}

export function emitPackedCopy(
	s: RaiserCompState, layouts: VmLayouts, destination: RaiserFramePlace,
	source: RaiserFramePlace,
): void {
	validatePlace(s, layouts, destination);
	validatePlace(s, layouts, source);
	if (typeKey(destination.valueType) != typeKey(source.valueType)) {
		throw new Error("internal: packed copy type mismatch");
	}
	const size = vmLayoutOf(layouts, source.valueType).size;
	if (source.offset % 8 == 0 && destination.offset % 8 == 0 &&
		(source.whole && destination.whole || size % 8 == 0)) {
		if (size > 0) emitInst(s, raiserABC(RaiserOpcode.MoveN,
			destination.base + destination.offset / 8,
			source.base + source.offset / 8, Math.ceil((size as number) / 8)));
		return;
	}
	const from = source.base * 8 + source.offset;
	const to = destination.base * 8 + destination.offset;
	const reverse = to > from && to < from + size;
	if (size == 0) return;
	const value = allocWord(s);
	let copied = 0;
	while (copied < size) {
		const remaining = size - copied;
		let width: int32 = 8;
		while (width > 1) {
			const at = reverse ? size - copied - width : copied;
			if (width <= remaining && (from + at) % width == 0 &&
				(to + at) % width == 0) break;
			width /= 2;
		}
		const at = reverse ? size - copied - width : copied;
		const offset = source.offset + at;
		emitInst(s, slotInst(RaiserOpcode.LoadFrame, value,
			source.base + offset / 8, offset % 8, rawKind(width) as int32));
		frameStore(s, destination.base, destination.offset + at,
			rawKind(width), value);
		copied += width;
	}
}

function validateLegacy(s: RaiserCompState, legacy: RaiserLegacyValue): void {
	if (legacy.shape.block || legacy.shape.words != 1 ||
		!integerIn(legacy.reg, 0, s.regClasses.length - 1) ||
		!raiserPackedEligible(legacy.valueType)) {
		throw new Error("internal: invalid legacy packed-codec carrier");
	}
	const cls = classOfReg(s, legacy.reg);
	const body = bodyOf(legacy.valueType);
	const maybeCarrier = isMaybeType(body) && body.typeReturn != null &&
		(cls == RaiserRegClass.Ref || cls == regClassOf(s, body.typeReturn));
	if (cls != RaiserRegClass.Dyn && cls != regClassOf(s, legacy.valueType) &&
		!maybeCarrier) {
		throw new Error("internal: legacy packed-codec register class mismatch");
	}
}

function requireKind(
	s: RaiserCompState, value: int32, kind: RaiserValueKind,
): void {
	const check = allocBool(s);
	emitInst(s, raiserABC(RaiserOpcode.IsKind, check, value, kind as int32));
	const refused = emitBranchIfFalsy(s, check);
	const accepted = emitJumpPlaceholder(s);
	patchJumpTo(s, refused, codeLen(s));
	emitTrap(s, "invalid legacy carrier at packed data boundary");
	patchJumpTo(s, accepted, codeLen(s));
}

function constant(s: RaiserCompState, value: int64): int32 {
	const reg = allocWord(s);
	emitLoadConst(s, reg, raiserInt(value));
	return reg;
}

export function literalValue(s: RaiserCompState, t: Type): int32 {
	const body = bodyOf(t);
	const value = body.kind == TypeKind.BooleanLiteral
		? raiserBool(body.typeName == "true")
		: body.kind == TypeKind.EnumLiteral
			? raiserInt(enumMemberValue(body.typeReturn!,
				body.typeReturn!.typeNames.indexOf(body.typeNames[0]) as int32) as int64)
			: zeroScalar(body);
	const reg = allocReg(s, body.kind == TypeKind.BooleanLiteral
		? RaiserRegClass.Bool : body.kind == TypeKind.Void
			? RaiserRegClass.Ref : regClassOf(s, body));
	emitLoadConst(s, reg, value);
	return reg;
}

function validateOmitted(s: RaiserCompState, value: int32, t: Type): void {
	const expected = literalValue(s, t);
	emitInst(s, raiserABC(RaiserOpcode.EqVal, value, expected, 1));
	emitTrap(s, "invalid legacy literal at packed data boundary");
}

function packScalar(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
	legacy: int32,
): void {
	const kind = vmLayoutOf(layouts, place.valueType).kind;
	const cls = scalarClass(place.valueType, kind);
	const value = allocReg(s, cls);
	if (cls == RaiserRegClass.Float) {
		const integerKind = allocBool(s);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, integerKind, legacy,
			RaiserValueKind.Int as int32));
		const floating = emitBranchIfFalsy(s, integerKind);
		const integer = allocWord(s);
		emitInst(s, raiserABC(RaiserOpcode.Move, integer, legacy, 0));
		emitInst(s, raiserABC(RaiserOpcode.Conv, value, integer,
			convOperand(kind == MemKind.F32 ? RaiserConvClass.F32
				: RaiserConvClass.F64, RaiserConvClass.I64 as int32)));
		const conversion = kind == MemKind.F32 ? "float32" : "float64";
		const message = `inexact legacy integer-to-${conversion} conversion`;
		const low = allocReg(s, RaiserRegClass.Float);
		const high = allocReg(s, RaiserRegClass.Float);
		emitLoadConst(s, low, raiserFloat(-9223372036854775808.0));
		emitLoadConst(s, high, raiserFloat(9223372036854775808.0));
		emitInst(s, raiserABC(RaiserOpcode.BgeF64, value, low, 1));
		emitTrap(s, message);
		emitInst(s, raiserABC(RaiserOpcode.BltF64, value, high, 1));
		emitTrap(s, message);
		const roundTrip = allocWord(s);
		emitInst(s, raiserABC(RaiserOpcode.Conv, roundTrip, value,
			convOperand(RaiserConvClass.I64, RaiserConvClass.F64 as int32)));
		emitInst(s, raiserABC(RaiserOpcode.BeqI64, roundTrip, integer, 1));
		emitTrap(s, message);
		const converted = emitJumpPlaceholder(s);
		patchJumpTo(s, floating, codeLen(s));
		requireKind(s, legacy, RaiserValueKind.Float);
		emitInst(s, raiserABC(RaiserOpcode.Move, value, legacy, 0));
		patchJumpTo(s, converted, codeLen(s));
	} else {
		requireKind(s, legacy, cls == RaiserRegClass.Bool
			? RaiserValueKind.Bool : RaiserValueKind.Int);
		emitInst(s, raiserABC(RaiserOpcode.Move, value, legacy, 0));
	}
	const bits: int32 = match (kind) {
		MemKind.I8 | MemKind.U8 => 8,
		MemKind.I16 | MemKind.U16 => 16,
		MemKind.I32 | MemKind.U32 => 32,
		_ => 64,
	};
	if (cls == RaiserRegClass.Word && bits < 64) {
		emitInst(s, raiserABC(RaiserOpcode.NarrowS, value, bits,
			kind == MemKind.U8 || kind == MemKind.U16 || kind == MemKind.U32
				? 1 : 0));
	}
	emitPackedStore(s, layouts, place, value);
}

function packInto(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
	legacy: int32,
): void {
	const body = bodyOf(place.valueType);
	if (vmLayoutOf(layouts, place.valueType).kind != MemKind.Block) {
		packScalar(s, layouts, place, legacy);
		return;
	}
	if (isMaybeType(body)) {
		const nil = allocBool(s);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, nil, legacy,
			RaiserValueKind.Nil as int32));
		const present = emitBranchIfFalsy(s, nil);
		const done = emitJumpPlaceholder(s);
		patchJumpTo(s, present, codeLen(s));
		packInto(s, layouts, packedField(s, layouts, place, "value"), legacy);
		const yes = allocBool(s);
		emitLoadConst(s, yes, raiserBool(true));
		emitPackedStore(s, layouts, packedField(s, layouts, place, "present"), yes);
		patchJumpTo(s, done, codeLen(s));
		return;
	}
	if (body.kind == TypeKind.Struct) {
		requireKind(s, legacy, RaiserValueKind.Object);
		for (let i = 0; i < body.typeNames.length; i += 1) {
			const field = allocDyn(s);
			emitInst(s, fieldInst(s, null, body.typeNames[i],
				RaiserOpcode.LoadFieldRequired, RaiserOpcode.LoadSlot, field, legacy,
				addConst(s, raiserConstString(body.typeNames[i]))));
			if (storesNothing(body, body.typeChildren[i])) {
				validateOmitted(s, field, body.typeChildren[i]);
			} else {
				packInto(s, layouts, packedField(s, layouts, place,
					body.typeNames[i]), field);
			}
			emitInst(s, raiserABC(RaiserOpcode.WasMoved, field, 0, 0));
		}
		return;
	}
	requireKind(s, legacy, RaiserValueKind.Array);
	const count = body.kind == TypeKind.Tuple
		? body.typeChildren.length : body.typeValue;
	const len = allocWord(s);
	emitInst(s, raiserABC(RaiserOpcode.ArrayLen, len, legacy, 0));
	emitInst(s, raiserABC(RaiserOpcode.BeqI64, len,
		constant(s, count as int64), 1));
	emitTrap(s, "invalid legacy fixed aggregate length at packed data boundary");
	for (let i = 0; i < count; i += 1) {
		const field = allocDyn(s);
		emitInst(s, raiserABC(RaiserOpcode.LoadIndex, field, legacy,
			constant(s, i as int64)));
		if (body.kind == TypeKind.Tuple && storesNothing(body, body.typeChildren[i])) {
			validateOmitted(s, field, body.typeChildren[i]);
		} else packInto(s, layouts, packedIndex(s, layouts, place, i), field);
		emitInst(s, raiserABC(RaiserOpcode.WasMoved, field, 0, 0));
	}
}

export function emitLegacyToPacked(
	s: RaiserCompState, layouts: VmLayouts, legacy: RaiserLegacyValue,
): RaiserFramePlace {
	validateLegacy(s, legacy);
	const result = allocPackedValue(s, layouts, legacy.valueType);
	const source = allocDyn(s);
	emitInst(s, raiserABC(RaiserOpcode.Move, source, legacy.reg, 0));
	packInto(s, layouts, result, source);
	emitInst(s, raiserABC(RaiserOpcode.WasMoved, source, 0, 0));
	return result;
}

function unpack(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
): int32 {
	const body = bodyOf(place.valueType);
	if (vmLayoutOf(layouts, place.valueType).kind != MemKind.Block) {
		return emitPackedLoad(s, layouts, place);
	}
	if (isMaybeType(body)) {
		const result = allocReg(s, regClassOf(s, place.valueType));
		emitLoadConst(s, result, zeroScalar(place.valueType));
		const absent = emitBranchIfFalsy(s, emitPackedLoad(s, layouts,
			packedField(s, layouts, place, "present")));
		const value = unpack(s, layouts, packedField(s, layouts, place, "value"));
		const nil = allocBool(s);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, nil, value,
			RaiserValueKind.Nil as int32));
		const representable = emitBranchIfFalsy(s, nil);
		emitTrap(s, "present packed payload is not representable by legacy Maybe");
		patchJumpTo(s, representable, codeLen(s));
		emitInst(s, raiserABC(RaiserOpcode.Move, result, value, 0));
		if (classOfReg(s, value) == RaiserRegClass.Ref) {
			emitInst(s, raiserABC(RaiserOpcode.WasMoved, value, 0, 0));
		}
		patchJumpTo(s, absent, codeLen(s));
		return result;
	}
	const result = allocRef(s);
	if (body.kind == TypeKind.Struct) {
		emitInst(s, raiserABC(RaiserOpcode.NewObject, result,
			structShapeOperand(s, place.valueType, body.typeNames, slotClassesOf(s, body)), 0));
		for (let i = 0; i < body.typeNames.length; i += 1) {
			const value = storesNothing(body, body.typeChildren[i])
				? literalValue(s, body.typeChildren[i])
				: unpack(s, layouts, packedField(s, layouts, place, body.typeNames[i]));
			emitInst(s, fieldInst(s, body, body.typeNames[i],
				RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, result,
				addConst(s, raiserConstString(body.typeNames[i])), value));
			if (classOfReg(s, value) == RaiserRegClass.Ref ||
				classOfReg(s, value) == RaiserRegClass.Dyn) {
				emitInst(s, raiserABC(RaiserOpcode.WasMoved, value, 0, 0));
			}
		}
		return result;
	}
	const element = body.kind == TypeKind.Tuple ? getElementType(body)
		: body.typeReturn;
	emitInst(s, newArrayInst(s, result, 0, element));
	const count = body.kind == TypeKind.Tuple
		? body.typeChildren.length : body.typeValue;
	for (let i = 0; i < count; i += 1) {
		const value = body.kind == TypeKind.Tuple && storesNothing(body, body.typeChildren[i])
			? literalValue(s, body.typeChildren[i])
			: unpack(s, layouts, packedIndex(s, layouts, place, i));
		emitInst(s, raiserABC(RaiserOpcode.ArrayPush, result, value, 0));
		if (classOfReg(s, value) == RaiserRegClass.Ref ||
			classOfReg(s, value) == RaiserRegClass.Dyn) {
			emitInst(s, raiserABC(RaiserOpcode.WasMoved, value, 0, 0));
		}
	}
	return result;
}

export function emitPackedToLegacy(
	s: RaiserCompState, layouts: VmLayouts, place: RaiserFramePlace,
): RaiserLegacyValue {
	validatePlace(s, layouts, place);
	return { reg: unpack(s, layouts, place), valueType: place.valueType,
		shape: { words: 1, block: false } };
}
