// Parity program — `typeof x` reads one tag table on every backend: as text it
// is the TS tag ("number" for every numeric kind, an int64 included), and
// compared in place with a primitive name it tests the exact kind, folding a
// single static type and casing on a union's held member.
//
// @stdout: tags number number number number number number number number number number
// @stdout: single true false true false true true
// @stdout: wide i-5 u5 u7 i-7
// @stdout: narrow u32 i32
// @stdout: text int 42 str 3 n s
// @stdout: switch i-1 u2 sz u8 num other
// @stdout: match u32 n b
// @stdout: field true false true
// @stdout: stored number int64|string
// @exit: 0

struct Holder {
	v: int64 | uint64;
}

function pickWide(n: int32): int64 | uint64 {
	if (n > 0) return 5 as uint64;
	return -5 as int64;
}

function pickWideSwapped(n: int32): uint64 | int64 {
	if (n > 0) return 7 as uint64;
	return -7 as int64;
}

function pickNarrow(n: int32): int32 | uint32 {
	if (n > 0) return 9 as uint32;
	return -9 as int32;
}

function showWide(v: int64 | uint64): string {
	if (typeof v === "int64") {
		const held: int64 = v;
		return `i${held}`;
	}
	return `u${v}`;
}

function showWideSwapped(v: uint64 | int64): string {
	if ("uint64" !== typeof v) return `i${v}`;
	return `u${v}`;
}

function showNarrow(v: int32 | uint32): string {
	if (typeof v == "uint32") return "u32";
	if (typeof v != "int32") return "none";
	return "i32";
}

function showText(v: int64 | string): string {
	if (typeof v === "int64") return `int ${v + 1}`;
	return `str ${v.length}`;
}

function tagOfText(v: string | int64): string {
	return typeof v === "number" ? "n" : "s";
}

function kindSwitch(v: int64 | uint64 | string): string {
	switch (typeof v) {
		case "int64": {
			const a: int64 = v;
			return `i${a}`;
		}
		case "uint64": {
			const b: uint64 = v;
			return `u${b}`;
		}
		default: {
			const c: string = v;
			return `s${c}`;
		}
	}
}

function tagSwitch(v: uint8 | float32 | string): string {
	switch (typeof v) {
		case "uint8": return "u8";
		case "number": return "num";
		default: return "other";
	}
}

function kindMatch(v: int32 | uint32 | boolean): string {
	return match (typeof v) {
		"uint32" => "u32",
		"number" => "n",
		_ => "b",
	};
}

function mkHolder(n: int32): Holder {
	if (n > 0) return { v: 3 as uint64 };
	return { v: -3 as int64 };
}

const i8: int8 = 1;
const i16: int16 = 1;
const i32: int32 = 1;
const i64: int64 = 1;
const u8: uint8 = 1;
const u16: uint16 = 1;
const u32: uint32 = 1;
const u64: uint64 = 1;
const f32: float32 = 1.5;
const f64: float64 = 1.5;
console.log("tags", typeof i8, typeof i16, typeof i32, typeof i64, typeof u8, typeof u16, typeof u32, typeof u64, typeof f32, typeof f64);
console.log("single", typeof u8 === "uint8", typeof u8 === "int8", typeof i64 === "int64", typeof i64 !== "int64", "float32" == typeof f32, typeof u64 === "number");
console.log("wide", showWide(pickWide(0)), showWide(pickWide(1)), showWideSwapped(pickWideSwapped(1)), showWideSwapped(pickWideSwapped(0)));
console.log("narrow", showNarrow(pickNarrow(1)), showNarrow(pickNarrow(0)));
console.log("text", showText(41), showText("abc"), tagOfText(3), tagOfText("x"));
console.log("switch", kindSwitch(-1 as int64), kindSwitch(2 as uint64), kindSwitch("z"), tagSwitch(3 as uint8), tagSwitch(1.5 as float32), tagSwitch("q"));
console.log("match", kindMatch(1 as uint32), kindMatch(-1 as int32), kindMatch(true));
const up = mkHolder(1);
const down = mkHolder(0);
console.log("field", typeof up.v === "uint64", typeof down.v === "uint64", typeof down.v === "int64");
const mixed: int64 | string = 4;
const stored = typeof i64;
console.log("stored", stored, `${typeof mixed === "int64" ? "int64" : "other"}|${typeof "s"}`);
