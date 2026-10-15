import { compileToC } from "../helpers";

const PRELUDE = `
enum Grade { Low, Mid, High }
type Meters = distinct int32;
function opaqueF64(x: float64): float64 { return x; }
function opaqueI64(x: int64): int64 { return x; }
function opaqueU32(x: uint32): uint32 { return x; }
function opaqueU8(x: uint8): uint8 { return x; }
function opaqueGrade(g: Grade): Grade { return g; }
function opaqueI32(x: int32): int32 { return x; }
function opaqueMeters(m: Meters): Meters { return m; }
`;

function cFor(body: string): string {
	const c = compileToC(PRELUDE + body);
	if (!c.ok) return "";
	return c.value;
}

test "enum to int32 needs no range check" {
	const c = cFor("function f(): int32 { return opaqueGrade(Grade.Mid) as int32; }");
	assert c != "";
	assert !c.contains("msCheckRange");
}

test "distinct int32 to int32 needs no range check" {
	const c = cFor("function f(): int32 { return opaqueMeters(3 as Meters) as int32; }");
	assert c != "";
	assert !c.contains("msCheckRange");
}

test "uint8 to int16 needs no range check" {
	const c = cFor("function f(): int16 { return opaqueU8(3 as uint8) as int16; }");
	assert c != "";
	assert !c.contains("msCheckRange");
}

test "float64 to int32 keeps the range check" {
	const c = cFor("function f(): int32 { return opaqueF64(3.9) as int32; }");
	assert c != "";
	assert c.contains("msCheckRangeI32");
}

test "int64 to int32 keeps the range check" {
	const c = cFor("function f(): int32 { return opaqueI64(3 as int64) as int32; }");
	assert c != "";
	assert c.contains("msCheckRangeI32");
}

test "uint32 to int32 keeps the range check" {
	const c = cFor("function f(): int32 { return opaqueU32(3 as uint32) as int32; }");
	assert c != "";
	assert c.contains("msCheckRangeI32");
}

test "a float to an unsigned type keeps the range check at every width" {
	const c32 = cFor("function f(): uint32 { return opaqueF64(3.9) as uint32; }");
	assert c32.contains("msCheckRangeU32"), c32;
	const c8 = cFor("function f(x: float32): uint8 { return x as uint8; }");
	assert c8.contains("msCheckRangeU8"), c8;
	const c64 = cFor("function f(): uint64 { return opaqueF64(3.9) as uint64; }");
	assert c64.contains("msCheckRangeU64"), c64;
}

test "an integer to an unsigned type wraps without a range check" {
	const c = cFor("function f(): uint8 { return opaqueI64(300 as int64) as uint8; }");
	assert c != "";
	assert !c.contains("msCheckRange");
}

test "int32 to an enum is checked against the enum's ordinals" {
	const c = cFor("function f(): Grade { return opaqueI32(1) as Grade; }");
	assert c != "";
	assert c.contains("msCheckRangeI32");
	assert c.contains(", 0, 2)");
}

test "float64 to an enum keeps a range check" {
	const c = cFor("function f(): Grade { return opaqueF64(1.0) as Grade; }");
	assert c != "";
	assert c.contains("msCheckRangeI32");
}

test "an enum member to its own enum needs no range check" {
	const c = cFor("function f(): Grade { return opaqueGrade(Grade.High) as Grade; }");
	assert c != "";
	assert !c.contains("msCheckRange");
}
