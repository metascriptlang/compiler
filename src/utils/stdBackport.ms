export function int64Bits(u: uint64): int64 {
	return u > 9223372036854775807 ? -((~u) as int64) - 1 : u as int64;
}
