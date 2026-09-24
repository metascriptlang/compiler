// @stdout: enum-const 16 4 5 | 1 2 3 3 -2 -8 -2147483648 | -2147483648 2147483647 2147483646 | 6
// note: each member value comes from the checker folding its initializer. Pre-fix `B = (1 << 2)` took A + 1 (17), and then the parser refused anything but a literal.

enum Bits { A = 0x10, B = (1 << 2), C }
enum Perm { Read = 1 << 0, Write = 1 << 1, ReadWrite = Read | Write, Both = Perm.Read | Perm.Write, NotRead = ~Read, Neg = -(1 << 3), Top = 1 << 31 }
enum Edge { Lo = -2147483648, Hi = 2147483647, Mask = 0x7fffffff & ~1 }

function local(): int32 {
	enum L { P = 3, Q = P * 2 }
	return L.Q as int32;
}

const bits = `${Bits.A as int32} ${Bits.B as int32} ${Bits.C as int32}`;
const perm = `${Perm.Read as int32} ${Perm.Write as int32} ${Perm.ReadWrite as int32} ${Perm.Both as int32} ${Perm.NotRead as int32} ${Perm.Neg as int32} ${Perm.Top as int32}`;
const edge = `${Edge.Lo as int32} ${Edge.Hi as int32} ${Edge.Mask as int32}`;
console.log(`enum-const ${bits} | ${perm} | ${edge} | ${local()}`);
