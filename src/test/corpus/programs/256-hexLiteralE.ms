// Hex literals whose digits contain 'e'/'E' are integers, not floats:
// the isFloat heuristic must not read a hex digit as an exponent marker.

function main(): void {
	const a = 0x80 | 1;
	const b = 0xe0 | 1;
	const c = 0xE0 | 1;
	const d = 0xbeef & 0xffff;
	const e: int32 = 0xffee;
	console.log("a=" + a.toString() + " b=" + b.toString() + " c=" + c.toString()
		+ " d=" + d.toString() + " e=" + e.toString());
}

main();
