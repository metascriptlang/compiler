// cparse — Type system
// Port of: ~/projects/chibicc type.c + target.ms parameterization.
//
// STATUS: skeleton data model. Constructors land with task #16.

import { TargetInfo, targetLinuxX86_64, targetWasm32 } from "./target";

export enum CTypeKind {
	Void,
	Bool,
	Char,
	Short,
	Int,
	Long,        // 32-bit on Windows LLP64, 64-bit on LP64 — kept distinct
	LongLong,    // always 64-bit on targets we care about
	Float,
	Double,
	LongDouble,
	// Fixed-width (int8_t..uint64_t) reach us as typedefs that resolve to
	// one of the above via ObjKind.TypedefName, not as distinct CType kinds.
	Ptr,
	Array,
	Func,
	Struct,      // forward-declared tags use Struct/Union with empty members[]
	Union,       // and get mutated in place when the body is seen — mirrors
	Enum,        // chibicc's approach. No separate Unresolved/Typedef kinds.
}

// Flat type representation (matches MetaScript's own type layout pattern).
// Unused fields are empty/null per-variant.
export interface CType {
	kind: CTypeKind;
	size: number;             // sizeof in bytes (target-dependent); -1 if incomplete
	align: number;            // alignof in bytes; -1 if incomplete
	isSigned: boolean;        // for integer kinds
	isConst: boolean;
	isVolatile: boolean;
	isRestrict: boolean;
	isAtomic: boolean;        // _Atomic(T) qualifier — parsed, usually ignored
	// Pointer / Array element
	base: CType;              // null as CType if not applicable
	arrayLen: number;         // -1 for incomplete / flexible
	// Function
	returnType: CType;
	params: CType[];
	paramNames: string[];
	isVariadic: boolean;
	// Struct / Union / Enum
	tagName: string;          // "" if anonymous
	members: CMember[];       // empty for non-aggregate; empty + isComplete=false
	                          //   for forward declarations
	isComplete: boolean;      // false for forward-declared tags awaiting body
	isPacked: boolean;        // __attribute__((packed)) / #pragma pack
	isFlexible: boolean;      // last member is a flexible array (T arr[];)
}

export interface CMember {
	name: string;
	type: CType;
	offset: number;           // byte offset in struct
	align: number;            // per-member align override (from __attribute__((aligned)))
	bitOffset: number;        // -1 if not a bitfield
	bitWidth: number;         // -1 if not a bitfield
}

export function makeVoid(): CType {
	return {
		kind: CTypeKind.Void,
		size: 1, align: 1,
		isSigned: false, isConst: false, isVolatile: false, isRestrict: false, isAtomic: false,
		base: null as unknown as CType,
		arrayLen: -1,
		returnType: null as unknown as CType,
		params: [], paramNames: [], isVariadic: false,
		tagName: "", members: [],
		isComplete: true, isPacked: false, isFlexible: false,
	};
}

export function makeInt(target: TargetInfo): CType {
	const t = makeVoid();
	t.kind = CTypeKind.Int;
	t.size = target.intSize;
	t.align = target.intSize;
	t.isSigned = true;
	return t;
}

export function makePointer(target: TargetInfo, base: CType): CType {
	const t = makeVoid();
	t.kind = CTypeKind.Ptr;
	t.size = target.pointerSize;
	t.align = target.pointerAlign;
	t.base = base;
	return t;
}

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
