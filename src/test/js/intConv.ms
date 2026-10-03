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
console.log(toInt8(1), toInt16(1), fromUnsigned(1), toInt32(1 as int64));
console.log(fromFloat(1.5), toUnsigned(1), widen(1));
`;

test "a signed narrowing conversion is range checked on JS" {
	const result = compileToJS(CONVERSIONS);
	assert result.ok;
	const emitted = result.value;
	const checked = [
		{ name: "toInt8", helper: "msCheckRangeI8" },
		{ name: "toInt16", helper: "msCheckRangeI16" },
		{ name: "fromUnsigned", helper: "msCheckRangeI8" },
		{ name: "toInt32", helper: "msCheckRangeI32" },
		{ name: "fromFloat", helper: "msCheckRangeI64" },
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
