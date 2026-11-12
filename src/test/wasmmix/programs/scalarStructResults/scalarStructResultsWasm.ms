export struct OptionalScalars {
	wide: int64 | null;
	unsigned: uint64 | null;
	flag: boolean | null;
	real: float64 | null;
}

export struct Scalars {
	s8: int8;
	u8: uint8;
	s16: int16;
	u16: uint16;
	s32: int32;
	u32: uint32;
	s64: int64;
	u64: uint64;
	f32: float32;
	f64: float64;
	yes: boolean;
	nested: OptionalScalars;
}

@wasm
export function reflect(value: Scalars | null): Scalars | null {
	return value;
}

@wasm
export function afterCallback(value: Scalars | null, callback: (n: int32) => int32): Scalars | null {
	callback(1);
	return value;
}
