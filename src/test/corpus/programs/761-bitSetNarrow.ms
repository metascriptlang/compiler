// Parity program — `BitSet<E>` over enums small enough for the 1-byte and
// 2-byte bands; the operations and the struct layout must behave the same as
// the wider bands on both backends.
//
// @stdout: 5,6,true,false,true,true,2049,1,false,true,true,true,true,false
// @exit: 0

enum Three { A, B, C }
enum Twelve { M0, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11 }
enum Twenty { T0, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19 }
struct Packed { a: BitSet<Three>; b: BitSet<Twelve>; c: BitSet<Twenty>; }

function mk3(): BitSet<Three> { return Three.A | Three.C; }

function main(): void {
	const s3: BitSet<Three> = mk3();
	const t3 = s3.incl(Three.B).excl(Three.A);
	const s12: BitSet<Twelve> = Twelve.M0 | Twelve.M11;
	const t12 = s12.excl(Twelve.M11);
	const p: Packed = { a: s3, b: s12, c: Twenty.T19 | Twenty.T0 };
	console.log(`${s3 as uint32 as int32},${t3 as uint32 as int32},${s3.has(Three.C)},${t3.has(Three.A)},${t3.has(Three.B)},${(0 as BitSet<Three>).isEmpty()},${s12 as uint32 as int32},${t12 as uint32 as int32},${t12.has(Twelve.M11)},${p.a.has(Three.A)},${p.b.has(Twelve.M11)},${p.c.has(Twenty.T19)},${s3 == mk3()},${s3 == t3}`);
}
main();
