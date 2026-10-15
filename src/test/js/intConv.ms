// Integer conversion materialization on the JS backend — docs/JS-NUMERIC.md.
//
// A JS number carries its fraction through every slot that C would have
// truncated, so a conversion the checker parked on a HiddenStdConv has to be
// spelled out by the backend or `const x: int32 = 3.9` keeps the .9. C spells
// the same two nodes as msCheckRangeI32(...); these pin the JS spelling.
//
// Runtime coverage for the values themselves: corpus/programs/016-jsIntegerModel.ms.

import { compileToJS } from "../helpers";

test "explicit int32 cast truncates" {
	const result = compileToJS("const f = 3.9; const a = f as int32;");
	assert result.ok;
	assert result.value.contains("| 0");
}

test "uint8 conversion masks to a byte" {
	const result = compileToJS("const f = 3.9; const a = f as uint8;");
	assert result.ok;
	assert result.value.contains("& 255");
}

test "uint16 conversion masks to a half word" {
	const result = compileToJS("const f = 3.9; const a = f as uint16;");
	assert result.ok;
	assert result.value.contains("& 65535");
}

test "uint32 conversion shifts unsigned" {
	const result = compileToJS("const f = 3.9; const a = f as uint32;");
	assert result.ok;
	assert result.value.contains(">>> 0");
}

test "int64 conversion truncates through the global Math" {
	const result = compileToJS("const f = 3.9; const a = f as int64;");
	assert result.ok;
	assert result.value.contains("Math.trunc");
}

// The prelude declares its own `class Math`, and the JS naming oracle mangles a
// module global. The receiver this pass synthesizes has to stay unbound so it
// reaches the engine's Math — hence the pass trailing resolveRuntimeIdents.
test "synthesized Math receiver is not mangled to the prelude class" {
	const result = compileToJS("const f = 3.9; const a = f as int64;");
	assert result.ok;
	assert !result.value.contains("_Math");
}

test "float slot is left alone" {
	const result = compileToJS("const f = 3.9; const a: float64 = f;");
	assert result.ok;
	assert !result.value.contains("| 0");
}

test "string cast is left alone" {
	const result = compileToJS("const s = \"x\"; const a = s as string;");
	assert result.ok;
	assert !result.value.contains("| 0");
}

function bodyOf(emitted: string, name: string): string {
	const at = emitted.indexOf("function " + name, 0);
	if (at < 0) return "";
	return emitted.slice(at, emitted.indexOf("\n}", at));
}

const CONVERSIONS = `
function toInt8(v: int32): int8 { return v as int8; }
function toInt16(v: int32): int16 { return v as int16; }
function fromUnsigned(v: uint8): int8 { return v as int8; }
function toInt32(v: int64): int32 { return v as int32; }
function fromFloat(v: float64): int64 { return v as int64; }
function toUnsigned(v: int32): uint8 { return v as uint8; }
function widen(v: int8): int32 { return v as int32; }
function floatToByte(v: float64): uint8 { return v as uint8; }
function floatToWord(v: float32): uint32 { return v as uint32; }
function floatToU64(v: float64): uint64 { return v as uint64; }
function toChar(v: int32): char { return v as char; }
function floatToChar(v: float64): char { return v as char; }
console.log(toInt8(1), toInt16(1), fromUnsigned(1), toInt32(1 as int64));
console.log(fromFloat(1.5), toUnsigned(1), widen(1));
console.log(floatToByte(1.5), floatToWord(1.5 as float32), floatToU64(1.5));
console.log(toChar(65) as int32, floatToChar(65.5) as int32);
`;

test "a signed narrowing conversion and a float into an unsigned type are range checked on JS" {
	const result = compileToJS(CONVERSIONS);
	assert result.ok;
	const emitted = result.value;
	const checked = [
		{ name: "toInt8", helper: "msCheckRangeI8" },
		{ name: "toInt16", helper: "msCheckRangeI16" },
		{ name: "fromUnsigned", helper: "msCheckRangeI8" },
		{ name: "toInt32", helper: "msCheckRangeI32" },
		{ name: "fromFloat", helper: "msCheckRangeI64" },
		{ name: "floatToByte", helper: "msCheckRangeU8" },
		{ name: "floatToWord", helper: "msCheckRangeU32" },
		{ name: "floatToU64", helper: "msCheckRangeU64" },
		{ name: "toChar", helper: "msCheckRangeU8" },
		{ name: "floatToChar", helper: "msCheckRangeU8" },
	];
	for (const row of checked) {
		assert bodyOf(emitted, row.name).contains(row.helper), row.name + " lacks " + row.helper;
	}
}

test "an unsigned or widening conversion stays unchecked on JS" {
	const result = compileToJS(CONVERSIONS);
	assert result.ok;
	const emitted = result.value;
	const unchecked = ["toUnsigned", "widen"];
	for (const name of unchecked) {
		const body = bodyOf(emitted, name);
		assert body != "", name;
		assert !body.contains("msCheckRange"), body;
	}
}

const ENUM_CONVERSIONS = `
enum Kind { A, B, C }
enum Port { Low = 256, High = 70000 }
function toKind(v: int32): Kind { return v as Kind; }
function toPort(v: int64): Port { return v as Port; }
function same(k: Kind): Kind { return k as Kind; }
console.log(toKind(1), toPort(256 as int64), same(Kind.A));
`;

test "an integer converted into an enum is checked against its lowest and highest member on JS" {
	const result = compileToJS(ENUM_CONVERSIONS);
	assert result.ok;
	const emitted = result.value;
	assert bodyOf(emitted, "toKind").contains("msCheckRangeI32"), bodyOf(emitted, "toKind");
	assert bodyOf(emitted, "toKind").contains(", 0, 2)"), bodyOf(emitted, "toKind");
	assert bodyOf(emitted, "toPort").contains(", 256, 70000)"), bodyOf(emitted, "toPort");
	assert !bodyOf(emitted, "same").contains("msCheckRange"), bodyOf(emitted, "same");
}

test "an int64 converted into an enum leaves the BigInt on JS" {
	const result = compileToJS(ENUM_CONVERSIONS);
	assert result.ok;
	assert bodyOf(result.value, "toPort").contains("BigInt.asIntN(32,"), bodyOf(result.value, "toPort");
}
