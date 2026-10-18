// @stdout: 0/d/9 NaN/d/9 s/2.5/2.5 null/d/9 | /d 5/a null/d | false/false s/true null/false | 1/1 null/1 | 0/d s/1.5 0/d s/7 0/d s/-1 0/d s/255 | 0/d s/9 0/d s/1 NaN/d /d false/d null/d | 0/d 0/d s/3 | 1.5 3 1.5 | none q | b c c | end t end 5 3 6 | k 3 7 1 | threw | 1/w w/2 null/2
// note: `a && b` takes the part of a's type that can be falsy joined with b's, and `a || b` the non-null part that can be truthy joined with b's, per operand kind, generic instance, never and nullable right side; a branch join folds an integer into the number member of a nullable union. `x && "s"` on a nullable number died at clang, `e || "d"` stayed `string | null`, and a ternary joining `number | string | null` with an integer printed [object Object] on JS and the Raiser.

function num(v: number, on: boolean): number | null { return on ? v : null; }
function str(v: string, on: boolean): string | null { return on ? v : null; }
function flag(v: boolean, on: boolean): boolean | null { return on ? v : null; }
function int(v: int32, on: boolean): int32 | null { return on ? v : null; }
function either(k: int32): number | string | null { return k == 0 ? 0 : (k == 1 ? "w" : null); }
class Box { v: int32 = 1; }
function box(on: boolean): Box | null { return on ? new Box() : null; }
function fail(): never { throw new Error("no"); }
function len(s: string): int32 { return s.length; }

function rowNum(a: number | null): string {
	const x = a && "s";
	const y = a || "d";
	const z: number = a || 9;
	return `${x}/${y}/${z}`;
}
function rowStr(a: string | null): string {
	const x = a && 5;
	const y: string = a || "d";
	return `${x}/${y}`;
}
function rowBool(a: boolean | null): string {
	const x = a && "s";
	const y: boolean = a || false;
	return `${x}/${y}`;
}
function rowBox(a: Box | null): string {
	const x = a && a.v;
	const y: Box = a || new Box();
	return `${x}/${y.v}`;
}
function row<T>(a: T | null): string {
	const x = a && "s";
	const y = a || "d";
	return `${x}/${y}`;
}
function plain(a: number): string {
	const x = a && "s";
	const y = a || "d";
	return `${x}/${y}`;
}
function mixed(a: int32 | null): string {
	const w: number = a || 1.5;
	return `${w}`;
}
function nullable(a: string | null): string {
	const r = a || null;
	return r === null ? "none" : r;
}
function chain(a: string | null, b: string | null): string {
	const r: string = a && b || "c";
	return r;
}
function sure(a: string | null): string {
	return a || fail();
}
function ternary(k: int32, c: boolean): string {
	const u = either(k);
	const a = c ? 1 : u;
	const o = c ? u : 2;
	return `${a}/${o}`;
}

const parts: string[] = [];
parts.push([rowNum(num(0, true)), rowNum(num(NaN, true)), rowNum(num(2.5, true)), rowNum(num(1, false))].join(" "));
parts.push([rowStr(str("", true)), rowStr(str("a", true)), rowStr(str("x", false))].join(" "));
parts.push([rowBool(flag(false, true)), rowBool(flag(true, true)), rowBool(flag(true, false))].join(" "));
parts.push([rowBox(box(true)), rowBox(box(false))].join(" "));
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
parts.push([row<int64>(zeroI64), row<int64>(nineI64), row<uint64>(zeroU64), row<uint64>(oneU64), row<number>(NaN), row<string>(""), row<boolean>(false), row<int32>(null)].join(" "));
parts.push([plain(0), plain(-0), plain(3)].join(" "));
parts.push([mixed(int(0, true)), mixed(int(3, true)), mixed(int(3, false))].join(" "));
parts.push([nullable(str("", true)), nullable(str("q", true))].join(" "));
parts.push([chain(str("a", true), str("b", true)), chain(str("", true), str("b", true)), chain(str("a", true), str(" ", false))].join(" "));
function tailKeep(a: string | null, k: int32): string {
	if (k == 0) { return "end"; }
	return a || tailKeep(a, k - 1);
}
function matchKeep(a: number | null, k: int32): number {
	return a || match (k) { 1 => 5, _ => 6 };
}
parts.push([tailKeep(str("", true), 2), tailKeep(str("t", true), 2), tailKeep(null, 1), matchKeep(num(0, true), 1), matchKeep(num(3, true), 1), matchKeep(null, 2)].join(" "));
const b = new Box();
const v1 = b && 7;
const v2 = b || new Box();
parts.push(`${sure(str("k", true))} ${len(str("abc", true) || "")} ${v1} ${v2.v}`);
try { sure(str("", true)); } catch (e) { parts.push("threw"); }
parts.push([ternary(1, true), ternary(1, false), ternary(2, false)].join(" "));
console.log(parts.join(" | "));
