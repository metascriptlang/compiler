import { Type, TypeKind } from "../ast/node";
import {
	TargetInfo, hostTargetInfo, sizeOfType, alignOfType, offsetOfField, storesNothing, enumStorageKind, unwrapRefNullUnion, literalUnionBase,
	createStruct, createPrimitive, isAwaitable, typeDisplayName, typeKey, offsetOfUnionPayload,
} from "../checker/types";

export enum MemKind { Block, I8, I16, I32, I64, U8, U16, U32, U64, F32, F64, Ptr }

export const CELL_HEADER_SIZE: int32 = 24;

export interface VmSlot {
	name: string;
	offset: int32;
	kind: MemKind;
}

export interface VmLayout {
	size: int32;
	align: int32;
	kind: MemKind;
	header: int32;
	slots: VmSlot[];
}

export interface VmLayouts {
	target: TargetInfo;
	values: HashMap<string, VmLayout>;
	cells: HashMap<string, VmLayout>;
}

export function createVmLayouts(): VmLayouts {
	return { target: hostTargetInfo(), values: new HashMap<string, VmLayout>(), cells: new HashMap<string, VmLayout>() };
}

function stripped(t: Type): Type {
	let cur = t;
	while ((cur.kind == TypeKind.Distinct || cur.kind == TypeKind.Alias || cur.kind == TypeKind.Sink || cur.kind == TypeKind.Lent) && cur.typeReturn != null) cur = cur.typeReturn;
	return cur;
}

export function memKindOf(t: Type): MemKind {
	const cur = stripped(t);
	if (cur.kind == TypeKind.Union) {
		if (unwrapRefNullUnion(cur) != null) return MemKind.Ptr;
		const carried = literalUnionBase(cur);
		return carried != null ? memKindOf(carried) : MemKind.Block;
	}
	if (cur.kind == TypeKind.GenericInstance && isAwaitable(cur)) return MemKind.Ptr;
	return match (cur.kind == TypeKind.Enum || cur.kind == TypeKind.EnumLiteral ? enumStorageKind(cur) : cur.kind) {
		TypeKind.Boolean | TypeKind.BooleanLiteral | TypeKind.Char | TypeKind.Uint8 => MemKind.U8,
		TypeKind.Int8 => MemKind.I8,
		TypeKind.Int16 => MemKind.I16,
		TypeKind.Uint16 => MemKind.U16,
		TypeKind.Int32 => MemKind.I32,
		TypeKind.Uint32 => MemKind.U32,
		TypeKind.Int64 => MemKind.I64,
		TypeKind.Uint64 => MemKind.U64,
		TypeKind.Float32 => MemKind.F32,
		TypeKind.Number | TypeKind.Float64 => MemKind.F64,
		TypeKind.CString | TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow | TypeKind.Null | TypeKind.BigInt => MemKind.Ptr,
		_ => MemKind.Block,
	};
}

function fieldSlots(tg: TargetInfo, owner: Type, names: string[], children: Type[]): VmSlot[] {
	const slots: VmSlot[] = [];
	for (let i = 0; i < children.length; i += 1) {
		if (storesNothing(owner, children[i])) continue;
		slots.push({ name: names[i], offset: offsetOfField(tg, owner, names[i]), kind: memKindOf(children[i]) });
	}
	return slots;
}

function tupleSlots(tg: TargetInfo, t: Type): VmSlot[] {
	const names: string[] = [];
	for (let i = 0; i < t.typeChildren.length; i += 1) names.push(`_${i}`);
	return fieldSlots(tg, createStruct("", names, t.typeChildren, true), names, t.typeChildren);
}

function unionSlots(tg: TargetInfo, t: Type): VmSlot[] {
	const tag = t.typeExtra != null && t.typeExtra.kind == TypeKind.Enum ? t.typeExtra : createPrimitive(TypeKind.Int32);
	const slots: VmSlot[] = [{ name: "_tag", offset: 0, kind: memKindOf(tag) }];
	const payload = offsetOfUnionPayload(tg, t);
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		if (t.typeChildren[i].kind == TypeKind.Null) continue;
		slots.push({ name: `v${i}`, offset: payload, kind: memKindOf(t.typeChildren[i]) });
	}
	return slots;
}

function lenPtrSlots(): VmSlot[] {
	return [{ name: "len", offset: 0, kind: MemKind.I64 }, { name: "p", offset: 8, kind: MemKind.Ptr }];
}

function closureSlots(): VmSlot[] {
	return [{ name: "fn", offset: 0, kind: MemKind.Ptr }, { name: "env", offset: 8, kind: MemKind.Ptr }];
}

function slotsOf(tg: TargetInfo, t: Type): VmSlot[] {
	if (t.kind == TypeKind.Struct) return fieldSlots(tg, t, t.typeNames, t.typeChildren);
	if (t.kind == TypeKind.Tuple) return tupleSlots(tg, t);
	if (t.kind == TypeKind.Union) {
		if (unwrapRefNullUnion(t) != null) return [];
		const carried = literalUnionBase(t);
		return carried != null ? slotsOf(tg, stripped(carried)) : unionSlots(tg, t);
	}
	if (t.kind == TypeKind.String || t.kind == TypeKind.StringLiteral || t.kind == TypeKind.Array) return lenPtrSlots();
	if (t.kind == TypeKind.Function) return closureSlots();
	return [];
}

function buildLayout(tg: TargetInfo, t: Type, header: int32): VmLayout {
	const size = sizeOfType(tg, t);
	const align = alignOfType(tg, t);
	if (size < 0 || align < 1) throw new Error(`internal: no VM layout for type ${typeDisplayName(t)} (kind ${t.kind as number})`);
	return { size, align, kind: memKindOf(t), header, slots: slotsOf(tg, stripped(t)) };
}

export function vmLayoutOf(layouts: VmLayouts, t: Type): VmLayout {
	const key = typeKey(t);
	const cached = layouts.values.get(key);
	if (cached != null) return cached;
	const built = buildLayout(layouts.target, t, 0);
	layouts.values.set(key, built);
	return built;
}

export function vmCellOf(layouts: VmLayouts, classType: Type): VmLayout {
	const key = typeKey(classType);
	const cached = layouts.cells.get(key);
	if (cached != null) return cached;
	const body = stripped(classType);
	if (body.kind != TypeKind.Ref || body.typeReturn == null) throw new Error(`internal: ${typeDisplayName(classType)} is not a class reference`);
	const built = buildLayout(layouts.target, body.typeReturn, CELL_HEADER_SIZE);
	layouts.cells.set(key, built);
	return built;
}
