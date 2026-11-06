// An integer formatted in a radix other than ten prints its exact digits on every width and sign,
// through a literal radix and a radix only known at run time.
//
// @stdout: -ff ffffffff -10000000 1ekf -80000000
// @stdout: 21i3v9 -1
// @exit: 0

const a: int32 = -255;
const b: uint32 = 4294967295;
const c: int8 = -128;
const d: uint16 = 65535;
const e: int32 = -2147483648;
console.log(a.toString(16), b.toString(16), c.toString(2), d.toString(36), e.toString(16));

function radixOf(text: string): int32 {
	return text.length * 12;
}
const wide = radixOf("abc");
const seven = wide - 29;
const f: int32 = 123456789;
const g: int32 = -1;
console.log(f.toString(wide), g.toString(seven));
