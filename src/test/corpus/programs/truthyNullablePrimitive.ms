// @stdout: F!e0--b F!e0--b F!e0--b T.i2L&|B F!e0--b | F!e0--b T.i2L&|B F!e0--b | F!e0--b T.i2L&|B F!e0--b | F!e0-- T.i2&| F!e0-- T.i2&| F!e0-- T.i2&| F!e0-- T.i2&| | F!e0-- T.i2&| F!e0-- T.i2&| F!e0-- F!e0-- F!e0-- T.i2&| F!e0-- F!e0-- | F!e0- F!e0- F!e0- T.i1| | FTTF FTTT TTFT FTTF | 7 0 7 d | kept 0 | narrowed-falsy | 6 | 10 | len 0
// note: a nullable primitive in a condition tests TS truthiness (0, -0, NaN, "", false and null are falsy) in if, while, for, ?:, !, && and ||, per member kind and per generic instance, and the falsy branch keeps the value: after `if (!x)` x is still T | null. C and JS tested presence, so 0, "" and false read true; `!x`, `x && y` and `x || y` on a nullable died at the C compiler; the Raiser read every float and string as false.

function num(v: number, on: boolean): number | null { return on ? v : null; }
function str(v: string, on: boolean): string | null { return on ? v : null; }
function flag(v: boolean, on: boolean): boolean | null { return on ? v : null; }
class Box { v: int32 = 1; }

function rowNum(a: number | null): string {
	let s = a ? "T" : "F";
	s += !a ? "!" : ".";
	if (a) { s += "i"; } else { s += "e"; }
	let n = 0;
	while (a) { n++; if (n > 1) { break; } }
	s += `${n}`;
	for (let i = 0; a && i < 1; i++) { s += "L"; }
	s += (a && true) ? "&" : "-";
	s += (a || false) ? "|" : "-";
	const b = !a;
	return s + (b ? "b" : "B");
}

function rowStr(a: string | null): string {
	let s = a ? "T" : "F";
	s += !a ? "!" : ".";
	if (a) { s += "i"; } else { s += "e"; }
	let n = 0;
	while (a) { n++; if (n > 1) { break; } }
	s += `${n}`;
	for (let i = 0; a && i < 1; i++) { s += "L"; }
	s += (a && true) ? "&" : "-";
	s += (a || false) ? "|" : "-";
	const b = !a;
	return s + (b ? "b" : "B");
}

function rowBool(a: boolean | null): string {
	let s = a ? "T" : "F";
	s += !a ? "!" : ".";
	if (a) { s += "i"; } else { s += "e"; }
	let n = 0;
	while (a) { n++; if (n > 1) { break; } }
	s += `${n}`;
	for (let i = 0; a && i < 1; i++) { s += "L"; }
	s += (a && true) ? "&" : "-";
	s += (a || false) ? "|" : "-";
	const b = !a;
	return s + (b ? "b" : "B");
}

function row<T>(a: T | null): string {
	let s = a ? "T" : "F";
	s += !a ? "!" : ".";
	if (a) { s += "i"; } else { s += "e"; }
	let n = 0;
	while (a) { n++; if (n > 1) { break; } }
	s += `${n}`;
	s += (a && true) ? "&" : "-";
	s += (a || false) ? "|" : "-";
	return s;
}

function plain(x: number): string {
	let s = x ? "T" : "F";
	s += !x ? "!" : ".";
	if (x) { s += "i"; } else { s += "e"; }
	let n = 0;
	while (x && n < 1) { n++; }
	return s + `${n}` + ((x || false) ? "|" : "-");
}

function pair(a: number | null, b: string | null): string {
	return (a && b ? "T" : "F") + (a || b ? "T" : "F") + (!(a && b) ? "T" : "F") + ((a && b) || a ? "T" : "F");
}

const parts: string[] = [];
parts.push([rowNum(num(0, true)), rowNum(num(-0, true)), rowNum(num(NaN, true)), rowNum(num(2.5, true)), rowNum(num(1, false))].join(" "));
parts.push([rowStr(str("", true)), rowStr(str("a", true)), rowStr(str("x", false))].join(" "));
parts.push([rowBool(flag(false, true)), rowBool(flag(true, true)), rowBool(flag(true, false))].join(" "));
const zero32: float32 = 0;
const half32: float32 = 1.5;
const zeroI8: int8 = 0;
const negI8: int8 = -1;
const zeroU8: uint8 = 0;
const fullU8: uint8 = 255;
const zeroI64: int64 = 0;
const nineI64: int64 = 9;
const zeroU64: uint64 = 0;
const oneU64: uint64 = 1;
parts.push([row<float32>(zero32), row<float32>(half32), row<int32>(0), row<int32>(7), row<int8>(zeroI8), row<int8>(negI8), row<uint8>(zeroU8), row<uint8>(fullU8)].join(" "));
parts.push([row<int64>(zeroI64), row<int64>(nineI64), row<uint64>(zeroU64), row<uint64>(oneU64), row<number>(NaN), row<string>(""), row<boolean>(false), row<Box>(new Box()), row<Box>(null), row<int32>(null)].join(" "));
parts.push([plain(0), plain(-0), plain(NaN), plain(3)].join(" "));
parts.push([pair(num(0, true), str("a", true)), pair(num(2, true), str("", true)), pair(num(2, true), str("a", true)), pair(num(0, false), str("b", true))].join(" "));
const z = num(0, true);
const v1 = z || 7;
const v2 = z && 7;
const v3 = num(3, true) && 7;
const e = str("", true);
parts.push(`${v1} ${v2} ${v3} ${(e || "d") ?? "?"}`);
const n0 = num(0, true);
if (!n0) { parts.push(n0 === null ? "null" : `kept ${n0}`); }
if (n0 !== null) { if (n0) { parts.push("narrowed-truthy"); } else { parts.push("narrowed-falsy"); } }
const n5 = num(5, true);
if (n5) { const k: number = n5; parts.push(`${k + 1}`); }
if (!n5) { parts.push("none"); } else { const k: number = n5; parts.push(`${k * 2}`); }
const s0 = str("", true);
if (!s0) { parts.push(s0 === null ? "null" : `len ${s0.length}`); }
console.log(parts.join(" | "));
