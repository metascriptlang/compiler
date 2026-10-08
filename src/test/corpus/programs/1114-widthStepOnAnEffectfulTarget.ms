// Parity program — `++` and `--` at a wrapping width (8/16-bit, uint32, uint64)
// on a target whose index or receiver has an effect: the effect runs once and
// the step wraps, in statement position and inside a larger expression.
//
// @stdout: 1 255 4294967295 18446744073709551615 0 1 true 9
// @exit: 0

class Cell { v: uint8 = 0; }

let calls = 0;
function pick(): int32 { calls += 1; return 0; }
function show(v: uint32): uint32 { return v; }

function main(): void {
	const a: uint8[] = [0 as uint8];
	const b: uint16[] = [0 as uint16];
	const c: uint32[] = [0 as uint32];
	const d: uint64[] = [0 as uint64];
	const cells: Cell[] = [new Cell()];

	a[pick()]++;
	a[pick()]--;
	--a[pick()];
	b[pick()]--;
	const shown = show(c[pick()]--);
	d[pick()]--;
	cells[pick()].v++;
	const before = a[pick()]++;
	let hit = false;
	if (b[pick()]++ == (65535 as uint16)) { hit = true; }

	console.log(cells[0].v, before, c[0], d[0], b[0], a[0] == (0 as uint8) ? 1 : 0, hit, calls - shown);
}

main();
