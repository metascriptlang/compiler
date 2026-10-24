// One home for facts about a numeric TypeKind that the integer and float
// lowerings (JS coercions, C range and division checks) each need.

import { TypeKind } from "../ast/node";

export function is64Kind(kind: TypeKind): boolean {
	return kind == TypeKind.Int64 || kind == TypeKind.Uint64;
}

export function isSignedKind(kind: TypeKind): boolean {
	return kind == TypeKind.Int8 || kind == TypeKind.Int16 || kind == TypeKind.Int32 || kind == TypeKind.Int64;
}

export function isFloatKind(kind: TypeKind): boolean {
	return kind == TypeKind.Number || kind == TypeKind.Float64 || kind == TypeKind.Float32;
}

export function isNarrowIntKind(kind: TypeKind): boolean {
	return match (kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 => true,
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 => true,
		_ => false,
	};
}

// 0 for a kind that is not one of the eight integer kinds.
export function bitsOfKind(kind: TypeKind): int32 {
	return match (kind) {
		TypeKind.Int8 | TypeKind.Uint8 => 8,
		TypeKind.Int16 | TypeKind.Uint16 => 16,
		TypeKind.Int32 | TypeKind.Uint32 => 32,
		TypeKind.Int64 | TypeKind.Uint64 => 64,
		_ => 0,
	};
}
