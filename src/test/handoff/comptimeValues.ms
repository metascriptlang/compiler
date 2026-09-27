import { evalSourceFull } from "../../codegen/raiser/eval";
import { RaiserValueKind } from "../../raiser/value";

const arrayEnum = "enum E { M0,M1,M2,M3,M4,M5,M6,M7,M8,M9,M10,M11,M12,M13,M14,M15,M16,M17,M18,M19,M20,M21,M22,M23,M24,M25,M26,M27,M28,M29,M30,M31,M32,M33,M34,M35,M36,M37,M38,M39,M40,M41,M42,M43,M44,M45,M46,M47,M48,M49,M50,M51,M52,M53,M54,M55,M56,M57,M58,M59,M60,M61,M62,M63,M64,M65,M66,M67,M68,M69,M70,M71,M72,M73,M74,M75,M76,M77,M78,M79,M80,M81,M82,M83,M84,M85,M86,M87,M88,M89,M90,M91,M92,M93,M94,M95,M96,M97,M98,M99 }";

test "comptime values: boolean representation" {
	const cases = [
		{ name: "numeric === produces Bool kind r", source: "const a = 1; const b = 1; return a === b;", low: 1, high: 1 },
		{ name: "numeric !== produces Bool kind r", source: "const a = 1; const b = 2; return a !== b;", low: 1, high: 1 },
		{ name: "relational > produces Bool kind r", source: "const a = 3; const b = 2; return a > b;", low: 1, high: 1 },
		{ name: "string === produces Bool kind r", source: "const s = \"a\"; const t = \"a\"; return s === t;", low: 1, high: 1 },
		{ name: "string !== produces Bool kind r", source: "const s = \"a\"; const t = \"b\"; return s !== t;", low: 1, high: 1 },
		{ name: "unary ! produces Bool kind r", source: "const a = 1; return !(a === 1);", low: 0, high: 0 },
		{ name: "has reads the member bit r", source: "enum E { A, B, C } const s: BitSet<E> = E.A | E.C; return s.has(E.C);", low: 1, high: 1 },
		{ name: "has is false for an absent member r", source: "enum E { A, B, C } const s: BitSet<E> = E.A | E.C; return s.has(E.B);", low: 0, high: 0 },
		{ name: "isEmpty on the zero set and on a populated set z", source: "enum E { A, B, C } const z = 0 as BitSet<E>; return z.isEmpty();", low: 1, high: 1 },
		{ name: "isEmpty on the zero set and on a populated set s", source: "enum E { A, B, C } const s: BitSet<E> = E.A | E.C; return s.isEmpty();", low: 0, high: 0 },
		{ name: "isEmpty on the zero array set and on a populated one z", source: arrayEnum + " const z = 0 as BitSet<E>; return z.isEmpty();", low: 1, high: 1 },
		{ name: "isEmpty on the zero array set and on a populated one s", source: arrayEnum + " const s: BitSet<E> = E.M99 | E.M1; return s.isEmpty();", low: 0, high: 0 },
		{ name: "comparing a float against an integer literal reads the fraction r", source: "const f: float64 = 0.5; return f > 0;", low: 1, high: 1 },
	];
	for (const item of cases) {
		const result = evalSourceFull(item.source);
		assert result.lastError == "", item.name + ": " + result.lastError;
		assert result.lastResult.kind == RaiserValueKind.Bool, item.name;
		assert result.lastResult.intVal == item.low, item.name;
	}
}

test "comptime values: integer representation" {
	const cases = [
		{ name: "chained Ref<Struct> field access returns real value not Nil ctx", source: `
		interface Inner { msg: string; }
		interface Outer { inner: Inner; }
		function makeInner(): Inner { return { msg: "hello_world" }; }
		function inlineInside(): Outer { return { inner: makeInner() }; }
		const o = inlineInside();
		return o.inner.msg.length;
	`, low: 11, high: 11 },
		{ name: "a union of two members is the or of their bits r", source: "enum E { A, B, C } const s: BitSet<E> = E.A | E.C; return s as uint32 as int32;", low: 5, high: 5 },
		{ name: "incl and excl rewrite the word r", source: "enum E { A, B, C } const s: BitSet<E> = E.A | E.C; const t = s.incl(E.B).excl(E.A); return t as uint32 as int32;", low: 6, high: 6 },
		{ name: "intersection keeps the shared bit r", source: "enum E { A, B, C } const s: BitSet<E> = E.A | E.C; const u = s & (E.C | E.B); return u as uint32 as int32;", low: 4, high: 4 },
		{ name: "the 16-bit band shifts by the ordinal r", source: "enum E { M0, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11 } const s: BitSet<E> = E.M11 | E.M1; return (s as uint32 as int32) + (s.has(E.M11) ? 100000 : 0) + (s.has(E.M0) ? 200000 : 0);", low: 102050, high: 102050 },
		{ name: "the array band reads and rewrites the member bits r", source: arrayEnum + " const s: BitSet<E> = E.M99 | E.M1; return (s.has(E.M99) ? 1 : 0) + (s.has(E.M1) ? 2 : 0) + (s.has(E.M0) ? 4 : 0) + (s.incl(E.M70).has(E.M70) ? 8 : 0) + (s.excl(E.M99).has(E.M99) ? 16 : 0);", low: 11, high: 11 },
		{ name: "equality on the array band compares every word r", source: arrayEnum + " const a: BitSet<E> = E.M99 | E.M1; const b: BitSet<E> = E.M1 | E.M99; const c: BitSet<E> = E.M98 | E.M1; return (a == b ? 1 : 0) + (a != b ? 2 : 0) + (a == c ? 4 : 0) + (a != c ? 8 : 0);", low: 9, high: 9 },
		{ name: "intersection, union and symmetric difference on the array band r", source: arrayEnum + " const a: BitSet<E> = E.M99 | E.M1; const b: BitSet<E> = E.M1 | E.M99; const c: BitSet<E> = E.M98 | E.M1; const d = a & c; const u = a | c; return (d.has(E.M1) ? 1 : 0) + (d.has(E.M99) ? 2 : 0) + (u.has(E.M98) ? 4 : 0) + (u.has(E.M99) ? 8 : 0) + ((a ^ b).isEmpty() ? 16 : 0);", low: 29, high: 29 },
		{ name: "the 64-bit band shifts past bit 31 r", source: "enum E { M0,M1,M2,M3,M4,M5,M6,M7,M8,M9,M10,M11,M12,M13,M14,M15,M16,M17,M18,M19,M20,M21,M22,M23,M24,M25,M26,M27,M28,M29,M30,M31,M32,M33,M34,M35,M36,M37,M38,M39 } const s: BitSet<E> = E.M39 | E.M1; const t: BitSet<E> = E.M7 | E.M1; return (s.has(E.M7) ? 1 : 0) + (s.has(E.M39) ? 2 : 0) + ((E.M33 | E.M0).has(E.M1) ? 4 : 0) + (s == t ? 8 : 0);", low: 2, high: 2 },
		{ name: "integer division stays integer r", source: "const a: int32 = 7; const b: int32 = 2; return a / b;", low: 3, high: 3 },
		{ name: "integer multiplication stays integer r", source: "const a: int64 = 3; const b: int64 = 4; return a * b;", low: 12, high: 12 },
		{ name: "integer modulo keeps the integer opcode r", source: "const a: int32 = 7; const b: int32 = 2; return a % b;", low: 1, high: 1 },
		{ name: "integer exponent converts the pow result back to an integer r", source: "const a: int32 = 2; const b: int32 = 10; return a ** b;", low: 1024, high: 1024 },
		{ name: "float to int truncates toward zero r", source: "const f: float64 = 7.9; return f as int32;", low: 7, high: 7 },
		{ name: "float to int truncates toward zero n", source: "const f: float64 = -7.9; return f as int32;", low: -7, high: -7 },
		{ name: "unsigned narrowing wraps r", source: "const i: int32 = 300; return i as uint8;", low: 44, high: 44 },
	];
	for (const item of cases) {
		const result = evalSourceFull(item.source);
		assert result.lastError == "", item.name + ": " + result.lastError;
		assert result.lastResult.kind == RaiserValueKind.Int, item.name;
		assert result.lastResult.intVal == item.low, item.name;
	}
}

test "comptime values: floating representation" {
	const cases = [
		{ name: "nested ObjectLiteral with inline call preserves a number payload", source: `
		interface Inner { tag: number; }
		interface Outer { inner: Inner; }
		function makeInner(t: number): Inner { return { tag: t }; }
		function inlineInside(): Outer { return { inner: makeInner(42) }; }
		const o = inlineInside();
		return o.inner.tag;
	`, low: 42.0, high: 42.0 },
		{ name: "a float literal spelled without a fraction still multiplies as a float r", source: "const f: float64 = 0.5; return f * 2.0;", low: 1.0, high: 1.0 },
		{ name: "a float survives a copy r", source: "const a: float64 = 0.5; const b = a; return b * 2.0;", low: 1.0, high: 1.0 },
		{ name: "a float survives a return r", source: "function t(x: float64): float64 { return x * 2.0; } return t(0.5);", low: 1.0, high: 1.0 },
		{ name: "a float survives an array element read r", source: "const xs: float64[] = [0.5]; return xs[0] * 2.0;", low: 1.0, high: 1.0 },
		{ name: "negating a float keeps the fraction r", source: "const f: float64 = 0.5; return -f;", low: -0.5, high: -0.5 },
		{ name: "float modulo calls fmod r", source: "const a: float64 = 7.5; const b: float64 = 2.0; return a % b;", low: 1.5, high: 1.5 },
		{ name: "float exponent calls pow r", source: "const a: float64 = 2.0; const b: float64 = 3.0; return a ** b;", low: 8.0, high: 8.0 },
		{ name: "int to float carries the float kind r", source: "const i: int32 = 7; const b: float64 = 2.0; return (i as float64) / b;", low: 3.5, high: 3.5 },
		{ name: "the std math externs reach the engine s", source: "return Math.sqrt(9.0);", low: 3.0, high: 3.0 },
		{ name: "the std math externs reach the engine a", source: "return Math.abs(-2.5);", low: 2.5, high: 2.5 },
		{ name: "the std math externs reach the engine p", source: "return Math.pow(2.0, 10.0);", low: 1024.0, high: 1024.0 },
		{ name: "the std math externs reach the engine t", source: "return Math.atan2(1.0, 1.0) * 4.0;", low: 3.14159, high: 3.1416 },
		{ name: "a readonly static inlines its initializer r", source: "return Math.PI;", low: 3.14159, high: 3.1416 },
	];
	for (const item of cases) {
		const result = evalSourceFull(item.source);
		assert result.lastError == "", item.name + ": " + result.lastError;
		assert result.lastResult.kind == RaiserValueKind.Float, item.name;
		if (item.low == item.high) {
			assert result.lastResult.floatVal == item.low, item.name;
		} else {
			assert result.lastResult.floatVal > item.low && result.lastResult.floatVal < item.high, item.name;
		}
	}
}

test "comptime values: unsupported evaluation" {
	const cases = [
		{ name: "an operator the engine cannot evaluate is a compile error, not a silent 0 r", source: "const a: int32 = -8; return a >>> 1;", low: 0, high: 0 },
		{ name: "signed narrowing out of range is an error, as at runtime r", source: "const i: int32 = 300; return i as int8;", low: 0, high: 0 },
	];
	for (const item of cases) {
		const result = evalSourceFull(item.source);
		assert result.lastError != "", item.name;
	}
}
