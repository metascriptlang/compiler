// @stdout: const=4,0 let=4,0 undef=4,0 field=4,0 param=4,0 nullFirst=0,4 int=7,0 sub=1,0 ret=4,0 arg=4,0 lit=a,b kept=4 generic=1,2
// note: `c ? value : null` written into a `T | null` slot has the slot's type, so the null arm stays possible: `?.` and `??` test the value and do not read through null.

class Leaf { v: int32 = 4; }
class Base { v: int32 = 1; }
class Sub extends Base { w: int32 = 2; }
class Box { l: Leaf | null = null; }

function constNull(flag: boolean): int32 {
	const i: Leaf | null = flag ? new Leaf() : null;
	return i?.v ?? 0;
}
function letNull(flag: boolean): int32 {
	let i: Leaf | null = flag ? new Leaf() : null;
	return i?.v ?? 0;
}
function undefinedArm(flag: boolean): int32 {
	const i: Leaf | null = flag ? new Leaf() : undefined;
	return i?.v ?? 0;
}
function fieldTarget(flag: boolean): int32 {
	const b = new Box();
	b.l = flag ? new Leaf() : null;
	return b.l?.v ?? 0;
}
function paramArm(flag: boolean, p: Leaf): int32 {
	const i: Leaf | null = flag ? p : null;
	return i?.v ?? 0;
}
function nullFirst(flag: boolean): int32 {
	const i: Leaf | null = flag ? null : new Leaf();
	return i?.v ?? 0;
}
function intNull(flag: boolean): int32 {
	const i: int32 | null = flag ? 7 : null;
	return i ?? 0;
}
function subArm(flag: boolean): int32 {
	const i: Base | null = flag ? new Sub() : null;
	return i?.v ?? 0;
}
function returned(flag: boolean): Leaf | null {
	return flag ? new Leaf() : null;
}
function take(i: Leaf | null): int32 {
	return i?.v ?? 0;
}
function literalArms(flag: boolean): string {
	const s: "a" | "b" = flag ? "a" : "b";
	const t: "a" | "b" = s;
	return t;
}
function keptNonNull(flag: boolean, a: Leaf, b: Leaf): Leaf {
	let x: Leaf | null = null;
	x = flag ? a : b;
	return x;
}
function argument(flag: boolean): int32 {
	return take(flag ? new Leaf() : null);
}

function both(f: (flag: boolean) => int32): string {
	return `${f(true)},${f(false)}`;
}

const line = [
	`const=${both(constNull)}`,
	`let=${both(letNull)}`,
	`undef=${both(undefinedArm)}`,
	`field=${both(fieldTarget)}`,
	`param=${paramArm(true, new Leaf())},${paramArm(false, new Leaf())}`,
	`nullFirst=${both(nullFirst)}`,
	`int=${both(intNull)}`,
	`sub=${both(subArm)}`,
	`ret=${returned(true)?.v ?? 0},${returned(false)?.v ?? 0}`,
	`arg=${both(argument)}`,
	`lit=${literalArms(true)},${literalArms(false)}`,
	`kept=${keptNonNull(false, new Leaf(), new Leaf()).v}`,
	`generic=${String(both(constNull) == "4,0" ? 1 : 3)},${String(both(constNull) == "" ? 1 : 2)}`,
];
console.log(line.join(" "));
