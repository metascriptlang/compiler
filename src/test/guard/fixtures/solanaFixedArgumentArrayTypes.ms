type FourBytes = uint8[4];

export enum FixedArrayOp { Read, Scalar }
export struct FixedArrayAccounts {}
export struct FixedArrayInput {
	prefix: boolean;
	empty: uint8[0];
	one: uint8[1];
	four: FourBytes;
	eight: uint8[8];
	nearKey: uint8[31];
	pastKey: uint8[33];
	last: boolean;
}

export struct ScalarArrayInput {
	prefix: uint8;
	u8: uint8[2];
	u16: uint16[2];
	u32: uint32[2];
	u64: uint64[2];
	i8: int8[2];
	i16: int16[2];
	i32: int32[2];
	i64: int64[2];
	flags: boolean[2];
	last: uint8;
}
