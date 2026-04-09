// cparse — Type system
// Port of: ~/projects/chibicc type.c + target.ms parameterization.
//
// All constructors take TargetInfo for size/align instead of hardcoding x86-64.
// chibicc's add_type (expression type inference) is NOT ported — we parse
// headers only, so we don't need full expression typing. We port:
// - Type constructors: primitives, pointer, array, func, struct, union, enum
// - Helpers: isInteger, isFlonum, isNumeric, copyType
// - Struct layout: computeStructLayout, computeUnionLayout

import { TargetInfo, targetLinuxX86_64, targetMacosAarch64, targetWindowsX64, targetWasm32 } from "./target";

export enum CTypeKind {
	Void,
	Bool,
	Char,
	Short,
	Int,
	Long,
	LongLong,
	Float,
	Double,
	LongDouble,
	Ptr,
	Array,
	Func,
	Struct,
	Union,
	Enum,
}

export interface CType {
	kind: CTypeKind;
	size: number;
	align: number;
	isSigned: boolean;
	isConst: boolean;
	isVolatile: boolean;
	isRestrict: boolean;
	isAtomic: boolean;
	base: CType;
	arrayLen: number;
	returnType: CType;
	params: CType[];
	paramNames: string[];
	isVariadic: boolean;
	tagName: string;
	members: CMember[];
	isComplete: boolean;
	isPacked: boolean;
	isFlexible: boolean;
	// Typedef name — when this type was resolved from a typedef, stores the name.
	// e.g., "msString" for typedef struct { ... } msString;
	typedefName: string;
	// Typedef origin — tracks the original type before typedef alias.
	// Used by is_compatible to look through typedefs.
	origin: CType;
}

export interface CMember {
	name: string;
	type: CType;
	offset: number;
	align: number;
	bitOffset: number;
	bitWidth: number;
}

// ===== Internal constructor =====

function newType(kind: CTypeKind, size: number, align: number, signed: boolean): CType {
	return {
		kind,
		size,
		align,
		isSigned: signed,
		isConst: false,
		isVolatile: false,
		isRestrict: false,
		isAtomic: false,
		base: null as unknown as CType,
		arrayLen: -1,
		returnType: null as unknown as CType,
		params: [],
		paramNames: [],
		isVariadic: false,
		tagName: "",
		members: [],
		isComplete: true,
		isPacked: false,
		isFlexible: false,
		typedefName: "",
		origin: null as unknown as CType,
	};
}

// ===== Primitive constructors (target-parameterized) =====

export function makeVoid(): CType {
	return newType(CTypeKind.Void, 1, 1, false);
}

export function makeBool(): CType {
	return newType(CTypeKind.Bool, 1, 1, false);
}

export function makeChar(target: TargetInfo): CType {
	return newType(CTypeKind.Char, 1, 1, target.charSigned);
}

export function makeUChar(): CType {
	return newType(CTypeKind.Char, 1, 1, false);
}

export function makeSChar(): CType {
	return newType(CTypeKind.Char, 1, 1, true);
}

export function makeShort(target: TargetInfo): CType {
	return newType(CTypeKind.Short, target.shortSize, target.shortSize, true);
}

export function makeUShort(target: TargetInfo): CType {
	return newType(CTypeKind.Short, target.shortSize, target.shortSize, false);
}

export function makeInt(target: TargetInfo): CType {
	return newType(CTypeKind.Int, target.intSize, target.intSize, true);
}

export function makeUInt(target: TargetInfo): CType {
	return newType(CTypeKind.Int, target.intSize, target.intSize, false);
}

export function makeLong(target: TargetInfo): CType {
	return newType(CTypeKind.Long, target.longSize, target.longSize, true);
}

export function makeULong(target: TargetInfo): CType {
	return newType(CTypeKind.Long, target.longSize, target.longSize, false);
}

export function makeLongLong(target: TargetInfo): CType {
	return newType(CTypeKind.LongLong, target.longLongSize, target.longLongSize, true);
}

export function makeULongLong(target: TargetInfo): CType {
	return newType(CTypeKind.LongLong, target.longLongSize, target.longLongSize, false);
}

export function makeFloat(target: TargetInfo): CType {
	return newType(CTypeKind.Float, target.floatSize, target.floatSize, false);
}

export function makeDouble(target: TargetInfo): CType {
	return newType(CTypeKind.Double, target.doubleSize, target.doubleSize, false);
}

export function makeLongDouble(target: TargetInfo): CType {
	return newType(CTypeKind.LongDouble, target.longDoubleSize, target.longDoubleSize, false);
}

// ===== Compound constructors =====

export function makePointer(target: TargetInfo, base: CType): CType {
	const t = newType(CTypeKind.Ptr, target.pointerSize, target.pointerAlign, false);
	t.base = base;
	return t;
}

export function makeArray(base: CType, len: number): CType {
	const size = len >= 0 ? base.size * len : -1;
	const t = newType(CTypeKind.Array, size, base.align, false);
	t.base = base;
	t.arrayLen = len;
	return t;
}

export function makeFunc(returnType: CType): CType {
	const t = newType(CTypeKind.Func, 1, 1, false);
	t.returnType = returnType;
	return t;
}

export function makeEnum(target: TargetInfo): CType {
	return newType(CTypeKind.Enum, target.intSize, target.intSize, true);
}

export function makeStruct(): CType {
	const t = newType(CTypeKind.Struct, 0, 1, false);
	t.isComplete = false;
	return t;
}

export function makeUnion(): CType {
	const t = newType(CTypeKind.Union, 0, 1, false);
	t.isComplete = false;
	return t;
}

// ===== Type helpers =====

export function isInteger(ty: CType): boolean {
	return ty.kind === CTypeKind.Bool || ty.kind === CTypeKind.Char ||
		ty.kind === CTypeKind.Short || ty.kind === CTypeKind.Int ||
		ty.kind === CTypeKind.Long || ty.kind === CTypeKind.LongLong ||
		ty.kind === CTypeKind.Enum;
}

export function isFlonum(ty: CType): boolean {
	return ty.kind === CTypeKind.Float || ty.kind === CTypeKind.Double ||
		ty.kind === CTypeKind.LongDouble;
}

export function isNumeric(ty: CType): boolean {
	return isInteger(ty) || isFlonum(ty);
}

export function isPointer(ty: CType): boolean {
	return ty.kind === CTypeKind.Ptr;
}

export function isArray(ty: CType): boolean {
	return ty.kind === CTypeKind.Array;
}

export function isFunc(ty: CType): boolean {
	return ty.kind === CTypeKind.Func;
}

export function isAggregate(ty: CType): boolean {
	return ty.kind === CTypeKind.Struct || ty.kind === CTypeKind.Union;
}

export function copyType(ty: CType): CType {
	const t = newType(ty.kind, ty.size, ty.align, ty.isSigned);
	t.isConst = ty.isConst;
	t.isVolatile = ty.isVolatile;
	t.isRestrict = ty.isRestrict;
	t.isAtomic = ty.isAtomic;
	t.base = ty.base;
	t.arrayLen = ty.arrayLen;
	t.returnType = ty.returnType;
	t.params = ty.params;
	t.paramNames = ty.paramNames;
	t.isVariadic = ty.isVariadic;
	t.tagName = ty.tagName;
	t.members = ty.members;
	t.isComplete = ty.isComplete;
	t.isPacked = ty.isPacked;
	t.isFlexible = ty.isFlexible;
	t.origin = ty;
	return t;
}

// ===== Struct / Union layout =====

function alignUp(n: number, align: number): number {
	if (align <= 1) return n;
	const rem = n % align;
	if (rem === 0) return n;
	return n + (align - rem);
}

// Compute struct layout: offsets for each member, total size, alignment.
// Handles packed structs (no padding) and flexible array members.
export function computeStructLayout(ty: CType): void {
	let offset = 0;
	let maxAlign = 1;
	let i = 0;
	while (i < ty.members.length) {
		const mem = ty.members[i];
		const memberAlign = ty.isPacked ? 1 : mem.type.align;
		if (memberAlign > maxAlign) maxAlign = memberAlign;

		// Flexible array member (last member, size 0): no space contribution
		if (i === ty.members.length - 1 && mem.type.kind === CTypeKind.Array && mem.type.arrayLen < 0) {
			mem.offset = alignUp(offset, memberAlign);
			ty.isFlexible = true;
		} else {
			offset = alignUp(offset, memberAlign);
			mem.offset = offset;
			offset = offset + mem.type.size;
		}
		mem.align = memberAlign;
		i = i + 1;
	}
	ty.size = alignUp(offset, ty.isPacked ? 1 : maxAlign);
	ty.align = ty.isPacked ? 1 : maxAlign;
	ty.isComplete = true;
}

// Compute union layout: all members at offset 0, size = max member size.
export function computeUnionLayout(ty: CType): void {
	let maxSize = 0;
	let maxAlign = 1;
	for (const mem of ty.members) {
		mem.offset = 0;
		mem.align = mem.type.align;
		if (mem.type.size > maxSize) maxSize = mem.type.size;
		if (mem.type.align > maxAlign) maxAlign = mem.type.align;
	}
	ty.size = alignUp(maxSize, ty.isPacked ? 1 : maxAlign);
	ty.align = ty.isPacked ? 1 : maxAlign;
	ty.isComplete = true;
}

// Create a CMember.
export function makeMember(name: string, type: CType): CMember {
	return {
		name,
		type,
		offset: 0,
		align: type.align,
		bitOffset: -1,
		bitWidth: -1,
	};
}

// ===== Tests =====

test "int type is target-sized on linux x86_64" {
	const target = targetLinuxX86_64();
	const intT = makeInt(target);
	assert intT.size === 4;
	assert intT.align === 4;
	assert intT.isSigned === true;
}

test "pointer inherits target pointer size on wasm32" {
	const target = targetWasm32();
	const ptrT = makePointer(target, makeVoid());
	assert ptrT.size === 4;
	assert ptrT.align === 4;
}

test "long differs between linux and windows" {
	const linux = targetLinuxX86_64();
	const win = targetWindowsX64();
	assert makeLong(linux).size === 8;
	assert makeLong(win).size === 4;
}

test "array size = element * count" {
	const target = targetLinuxX86_64();
	const arr = makeArray(makeInt(target), 10);
	assert arr.size === 40;
	assert arr.align === 4;
	assert arr.arrayLen === 10;
}

test "array incomplete has size -1" {
	const target = targetLinuxX86_64();
	const arr = makeArray(makeInt(target), -1);
	assert arr.size === -1;
	assert arr.arrayLen === -1;
}

test "func type size is 1" {
	const target = targetLinuxX86_64();
	const fn = makeFunc(makeInt(target));
	assert fn.size === 1;
	assert fn.returnType.kind === CTypeKind.Int;
}

test "enum uses int size" {
	const target = targetLinuxX86_64();
	const e = makeEnum(target);
	assert e.size === 4;
	assert e.isSigned === true;
}

test "isInteger covers enum" {
	const target = targetLinuxX86_64();
	assert isInteger(makeEnum(target)) === true;
	assert isInteger(makeFloat(target)) === false;
}

test "isFlonum" {
	const target = targetLinuxX86_64();
	assert isFlonum(makeDouble(target)) === true;
	assert isFlonum(makeInt(target)) === false;
}

test "isNumeric covers both" {
	const target = targetLinuxX86_64();
	assert isNumeric(makeInt(target)) === true;
	assert isNumeric(makeFloat(target)) === true;
	assert isNumeric(makePointer(target, makeVoid())) === false;
}

test "copyType sets origin" {
	const target = targetLinuxX86_64();
	const original = makeInt(target);
	const copy = copyType(original);
	assert copy.kind === CTypeKind.Int;
	assert copy.origin === original;
}

test "struct layout with padding" {
	const target = targetLinuxX86_64();
	// struct { char a; int b; } — expect 4 bytes padding after a
	const st = makeStruct();
	st.members = [
		makeMember("a", makeChar(target)),
		makeMember("b", makeInt(target)),
	];
	computeStructLayout(st);
	assert st.members[0].offset === 0;
	assert st.members[1].offset === 4; // aligned to 4
	assert st.size === 8; // 4 (a padded) + 4 (b) = 8
	assert st.align === 4;
	assert st.isComplete === true;
}

test "struct layout packed" {
	const target = targetLinuxX86_64();
	const st = makeStruct();
	st.isPacked = true;
	st.members = [
		makeMember("a", makeChar(target)),
		makeMember("b", makeInt(target)),
	];
	computeStructLayout(st);
	assert st.members[0].offset === 0;
	assert st.members[1].offset === 1; // no padding
	assert st.size === 5;
	assert st.align === 1;
}

test "union layout" {
	const target = targetLinuxX86_64();
	const un = makeUnion();
	un.members = [
		makeMember("i", makeInt(target)),
		makeMember("d", makeDouble(target)),
	];
	computeUnionLayout(un);
	assert un.members[0].offset === 0;
	assert un.members[1].offset === 0;
	assert un.size === 8; // max(4, 8)
	assert un.align === 8;
}

test "struct with flexible array member" {
	const target = targetLinuxX86_64();
	const st = makeStruct();
	st.members = [
		makeMember("len", makeInt(target)),
		makeMember("data", makeArray(makeChar(target), -1)), // flexible
	];
	computeStructLayout(st);
	assert st.members[0].offset === 0;
	assert st.members[1].offset === 4;
	assert st.isFlexible === true;
	assert st.size === 4; // flexible array doesn't contribute
}

test "long double differs by target" {
	assert makeLongDouble(targetLinuxX86_64()).size === 16;
	assert makeLongDouble(targetMacosAarch64()).size === 8;
	assert makeLongDouble(targetWindowsX64()).size === 8;
}
