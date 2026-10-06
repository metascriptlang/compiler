// @stdout: bits i32=-2473910,-10,-1 u32=463129088,2 i64=373392592,-6 u64=4611686018427126392 narrow=77,56,-11072,-50,32768 once=16,-7,0,-20,18446744073709541767,3,56 calls=9 sets=10,14,00011,00111 picks=2
// note: `x op= y` for & | ^ << >> stores the binary `x op y` into x and reads x once: the same values as the binary form on every width (an 8- or 16-bit shift wraps at its width, every count is masked to the width), and `a[next()] op= v` calls next() once. A BitSet takes |= &= ^= with a member or a set, the array band (over 64 members) included.

enum Mod {
	Overtime,
	Scavenger,
	ThickHide,
	Pacifist,
}

enum Big {
	M0,
	M1,
	M2,
	M3,
	M4,
	M5,
	M6,
	M7,
	M8,
	M9,
	M10,
	M11,
	M12,
	M13,
	M14,
	M15,
	M16,
	M17,
	M18,
	M19,
	M20,
	M21,
	M22,
	M23,
	M24,
	M25,
	M26,
	M27,
	M28,
	M29,
	M30,
	M31,
	M32,
	M33,
	M34,
	M35,
	M36,
	M37,
	M38,
	M39,
	M40,
	M41,
	M42,
	M43,
	M44,
	M45,
	M46,
	M47,
	M48,
	M49,
	M50,
	M51,
	M52,
	M53,
	M54,
	M55,
	M56,
	M57,
	M58,
	M59,
	M60,
	M61,
	M62,
	M63,
	M64,
	M65,
	M66,
	M67,
	M68,
	M69,
}

struct Box { v: uint32; w: int8; }

let calls: int32 = 0;
function next(): int32 { calls += 1; return 1; }
let picks: int32 = 0;
function pick(): int32 { picks += 1; return 0; }

function widths(): string {
	let a: int32 = -1234567;
	a |= 0x0F0F; a &= 0x7FFFF0F0; a ^= 0x55; a <<= 3; a >>= 2;
	let c: int32 = -5;
	const n: int32 = 33;
	c <<= n;
	let d: int32 = -1;
	d >>= n;
	let u: uint32 = 4000000000;
	u |= 0x0F; u &= 0xFFFFFFF0; u ^= 0x80000000; u <<= 1; u >>= 3;
	let v: uint32 = 0x80000001;
	v <<= 1;
	let l: int64 = -123456789012;
	const m: int64 = 0xFF00;
	l |= m; l &= m * 1000; l ^= 77; l <<= 5; l >>= 1;
	let k: int64 = -3;
	const sixtyFive: int64 = 65;
	k <<= sixtyFive;
	let w: uint64 = 18446744073709551000;
	w |= 0xF; w &= 0xFFFFFFFFFFFF00FF; w ^= 1; w <<= 4; w >>= 2;
	let b8: uint8 = 200;
	b8 |= 0x05; b8 &= 0xFE; b8 ^= 0x81; b8 <<= 1; b8 >>= 1;
	let s8: int8 = -100;
	s8 <<= 1;
	let s16: int16 = 30000;
	s16 <<= 2;
	let t8: int8 = -100;
	const nine: int8 = 9;
	t8 >>= nine;
	let u16: uint16 = 65535;
	u16 <<= 15;
	return `i32=${a},${c},${d} u32=${u},${v} i64=${l},${k} u64=${w} narrow=${b8},${s8},${s16},${t8},${u16}`;
}

function bump(ref b: Box): void {
	b.v |= 0x80000000;
	b.w <<= 1;
}

function once(): string {
	const a: uint32[] = [1, 2, 3];
	a[next()] |= 0x80000000;
	a[next()] <<= 3;
	const b: int32[] = [1, -16, 3];
	b[next()] >>= 2;
	b[next()] ^= 5;
	const c: uint8[] = [1, 200, 3];
	c[next()] <<= 1;
	c[next()] &= 0x0F;
	const d: int64[] = [1, -5, 3];
	d[next()] <<= 2;
	const e: uint64[] = [1, 18446744073709551000, 3];
	e[next()] <<= 4;
	e[next()] |= 7;
	let box: Box = { v: 1, w: -100 };
	box.v |= 2;
	bump(box);
	return `once=${a[1]},${b[1]},${c[1]},${d[1]},${e[1]},${box.v - 2147483648},${box.w} calls=${calls}`;
}

function bigText(b: BitSet<Big>): string {
	let t = "";
	for (const m of [Big.M1, Big.M2, Big.M3, Big.M40, Big.M69]) {
		t = t + (b.has(m) ? "1" : "0");
	}
	return t;
}

function sets(): string {
	let s = (0 as BitSet<Mod>).incl(Mod.Overtime);
	s |= Mod.Pacifist;
	s |= Mod.Scavenger | Mod.ThickHide;
	s &= Mod.Pacifist | Mod.Scavenger | Mod.Overtime;
	s ^= Mod.Overtime;
	let b = (0 as BitSet<Big>).incl(Big.M1);
	b |= Big.M69;
	b |= (0 as BitSet<Big>).incl(Big.M40).incl(Big.M2);
	b &= (0 as BitSet<Big>).incl(Big.M69).incl(Big.M40).incl(Big.M1);
	b ^= Big.M1;
	const bigs: BitSet<Big>[] = [b];
	bigs[pick()] |= Big.M3;
	const words: BitSet<Mod>[] = [s];
	words[pick()] |= Mod.ThickHide;
	return `sets=${s as uint8},${words[0] as uint8},${bigText(b)},${bigText(bigs[0])} picks=${picks}`;
}

console.log(`bits ${widths()} ${once()} ${sets()}`);
