// @stdout: -2147483647 true -128 32767 -2147483648 255 0 4294967295
// @stdout: -9223372036854775808 18446744073709551615 0.25 1.5
// @stdout: true -7 4294967295 -9007199254740993 18446744073709551615 0.1 High filled é
// @stdout: 3 4 a/High bé!!/Low
// @stdout: 7 1,2,6 false -1 1 1 8 1
// @stdout: 1 ~ Mid ~
// @stdout: ~ was null ~ 2.5
// @stdout: caught boom after the writes: 5 2 text written
// @stdout: 5 3 text written written
// @stdout: caught boom before the write: 3
// @stdout: 9
import { Level, stepNarrow, stepWide, fillAll, stepText, flip, fillThenThrow, throwBeforeFill } from "./refOutScalarsWasm";

function showInt(v: int32 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showText(v: string | null): string {
	if (v == null) { return "~"; }
	return v;
}

function showLevel(v: Level | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showNum(v: float64 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

let b = false;
let i8: int8 = -127;
let i16: int16 = 32766;
let i32: int32 = -1073741824;
let u8: uint8 = 254;
let u16: uint16 = 1;
let u32: uint32 = 4294967294;
const r = stepNarrow(b, i8, i16, i32, u8, u16, u32);
console.log(`${r} ${b} ${i8} ${i16} ${i32} ${u8} ${u16} ${u32}`);

function wide(): void {
	let i64: int64 = -4611686018427387904;
	let u64: uint64 = 18446744073709551614;
	let f32: float32 = 1;
	let f64: float64 = 0.5;
	stepWide(i64, u64, f32, f64);
	console.log(`${i64} ${u64} ${f32} ${f64}`);
}
wide();

function unassigned(): void {
	let b: boolean;
	let i32: int32;
	let u32: uint32;
	let i64: int64;
	let u64: uint64;
	let f64: float64;
	let lvl: Level;
	let s: string;
	fillAll(out b, out i32, out u32, out i64, out u64, out f64, out lvl, out s);
	console.log(`${b} ${i32} ${u32} ${i64} ${u64} ${f64} ${lvl} ${s}`);
}
unassigned();

struct Slot { text: string; level: Level; }
let slots: Vec<Slot> = [{ text: "a", level: Level.Low }, { text: "bé", level: Level.High }];
const n0 = stepText(slots[1].text, slots[1].level);
const n1 = stepText(slots[1].text, slots[0].level);
console.log(`${n0} ${n1} ${slots[0].text}/${slots[0].level} ${slots[1].text}/${slots[1].level}`);

let counts: Vec<int32> = [1, 2, 3];
i8 = 0;
i16 = 0;
u8 = 0;
u16 = 9;
u32 = 0;
const n2 = stepNarrow(b, i8, i16, counts[2], u8, u16, u32);
console.log(`${n2} ${counts.join(",")} ${b} ${i8} ${i16} ${u8} ${u16} ${u32}`);

let mn: int32 | null = null;
let ms: string | null = "text";
let ml: Level | null = null;
let mf: float64 | null = 7;
flip(mn, ms, ml, mf);
console.log(`${showInt(mn)} ${showText(ms)} ${showLevel(ml)} ${showNum(mf)}`);
flip(mn, ms, ml, mf);
console.log(`${showInt(mn)} ${showText(ms)} ${showLevel(ml)} ${showNum(mf)}`);

let x: int32 = 0;
let y: int32 = 1;
let t: string = "text";
try {
	fillThenThrow(x, y, t, true);
} catch (e) {
	console.log(`caught ${e.message}: ${x} ${y} ${t}`);
}
fillThenThrow(x, y, t, false);
console.log(`${x} ${y} ${t}`);

let kept: int32 = 3;
try {
	throwBeforeFill(kept, true);
} catch (e) {
	console.log(`caught ${e.message}: ${kept}`);
}
throwBeforeFill(kept, false);
console.log(`${kept}`);
