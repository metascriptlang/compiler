// @stdout: -2147483648 -2147483648 -2147483648 0 -1073741824 2147483647 2147483648 / -2147483648 -2147483648 -2147483648 0 -1073741824 2147483648 -2147483648 | 2147483647 2147483647 2147483647 -2 1073741823 -2147483648 2147483647 / 2147483647 2147483647 2147483647 -2 1073741823 2147483647 2147483647 | 0 0 0 0 0 -1 0 / 0 0 0 0 0 0 0 | 2 2 2 4 1 -3 2 / 2 2 2 4 1 2 2 | -1294967296 -1294967296 -1294967296 1705032704 -647483648 1294967295 3000000000 / -1294967296 -1294967296 -1294967296 1705032704 -647483648 3000000000 -1294967296 | -1 -1 -1 -2 -1 0 4294967295 / -1 -1 -1 -2 -1 4294967295 -1
// note: a `number` operand outside int32 (2^31, -2^31-1, a fraction, 3000000000.7, -4294967297.5) converts by ECMAScript ToInt32 in every bitwise operator and compound assignment, on C, JS and the Raiser (node prints the same line); the Raiser stopped with "not in range".

function binary(v: number): string {
	return `${v | 0} ${v & -1} ${v ^ 0} ${v << 1} ${v >> 1} ${~v} ${v >>> 0}`;
}

function compound(v: number): string {
	let a = v;
	a |= 0;
	let b = v;
	b &= -1;
	let c = v;
	c ^= 0;
	let d = v;
	d <<= 1;
	let e = v;
	e >>= 1;
	let f = v;
	f >>>= 0;
	let k: int32 = 0;
	k |= v;
	return `${a} ${b} ${c} ${d} ${e} ${f} ${k}`;
}

const vals: number[] = [2147483648, -2147483649, -0.5, 2.9, 3000000000.7, -4294967297.5];
const rows: string[] = [];
for (const v of vals) rows.push(`${binary(v)} / ${compound(v)}`);
console.log(rows.join(" | "));
