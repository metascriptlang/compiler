// @stdout: 0 0 0 0 7 0 9 2 0 2 4
// note: a sized array of length 0 has no storage and reads as empty: a local, a returned value, a span over it, a field in the middle or first in its struct, an array of such structs and a field of managed elements. Same output on every lane.
struct Meta { key: uint64; flag: uint8; }
struct Lead { pad: uint8[0]; n: uint32; }
struct Hdr { tag: uint8; pad: uint8[0]; n: uint32; }
struct Names { names: string[0]; count: int32; }

function total(xs: Readonly<Span<Meta>>): uint64 {
	let t: uint64 = 0;
	for (const m of xs) { t += m.key; }
	return t;
}
function none(): Meta[0] { return []; }
function lead(n: uint32): Lead { return { pad: [], n: n }; }

function main(): void {
	const empty: Meta[0] = [];
	let count = 0;
	for (const m of empty) { count += m.flag as int32; }
	const h: Hdr = { tag: 1, pad: [], n: 7 };
	const l = lead(9);
	const nm: Names = { names: [], count: 2 };
	const grid: Lead[2] = [{ pad: [], n: 3 }, { pad: [], n: 4 }];
	console.log(`${empty.length} ${count} ${total(empty)} ${none().length} ${h.n} ${h.pad.length} ${l.n} ${nm.count} ${nm.names.length} ${grid.length} ${grid[1].n}`);
}
main();
