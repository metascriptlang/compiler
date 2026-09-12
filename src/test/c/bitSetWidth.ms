import { compileToC } from "../helpers";

const PRELUDE = `
enum Three { A, B, C }
enum Twelve { M0, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11 }
enum Twenty { T0, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19 }
enum Forty { F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31, F32, F33, F34, F35, F36, F37, F38, F39 }
enum Hundred { H0, H1, H2, H3, H4, H5, H6, H7, H8, H9, H10, H11, H12, H13, H14, H15, H16, H17, H18, H19, H20, H21, H22, H23, H24, H25, H26, H27, H28, H29, H30, H31, H32, H33, H34, H35, H36, H37, H38, H39, H40, H41, H42, H43, H44, H45, H46, H47, H48, H49, H50, H51, H52, H53, H54, H55, H56, H57, H58, H59, H60, H61, H62, H63, H64, H65, H66, H67, H68, H69, H70, H71, H72, H73, H74, H75, H76, H77, H78, H79, H80, H81, H82, H83, H84, H85, H86, H87, H88, H89, H90, H91, H92, H93, H94, H95, H96, H97, H98, H99 }
`;

function cFor(body: string): string {
	const c = compileToC(PRELUDE + body);
	if (!c.ok) return "";
	return c.value;
}

test "up to 8 members is one byte" {
	const c = cFor("struct P { a: BitSet<Three>; }");
	assert c != "";
	assert c.contains("uint8_t a;");
}

test "up to 16 members is two bytes" {
	const c = cFor("struct P { b: BitSet<Twelve>; }");
	assert c != "";
	assert c.contains("uint16_t b;");
}

test "up to 32 members is four bytes" {
	const c = cFor("struct P { c: BitSet<Twenty>; }");
	assert c != "";
	assert c.contains("uint32_t c;");
}

test "up to 64 members is eight bytes" {
	const c = cFor("struct P { d: BitSet<Forty>; }");
	assert c != "";
	assert c.contains("uint64_t d;");
}

test "past 64 members is a byte array" {
	const c = cFor("struct P { e: BitSet<Hundred>; }");
	assert c != "";
	assert c.contains("msSizedArray_uint8_t_13 e;");
}

test "a narrow set still lowers to bare bit operations" {
	const c = cFor("function f(s: BitSet<Three>): boolean { return s.has(Three.B); }");
	assert c != "";
	assert !c.contains("BitSet_has");
	assert c.contains("& (1 << Three_");
}
