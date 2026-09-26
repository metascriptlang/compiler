// Symptom: `.length` and `for..of` on a fixed array `T[N]` failed the C build with "no member named 'len' in 'struct msSizedArray_…'"; JS ran.
// Root cause: native lowering rewrote `.length` to the `.len` field for SizedArray as for Array, but the sized array struct has no `len`.
// Fix: `.length` on a SizedArray lowers to the literal N of its type, as Nim's genArrayLen does for tyArray.

struct Fighter206 { power: int64; health: int64; }
type Row206 = int32[3];
struct Roster206 { count: uint8; fighters: Fighter206[4]; }

function roster206(): Roster206 {
	return { count: 4, fighters: [{ power: 1, health: 0 }, { power: 2, health: 0 }, { power: 3, health: 0 }, { power: 4, health: 0 }] };
}

function sumParam206(xs: int64[3]): int64 {
	let total: int64 = 0;
	for (let i = 0; i < xs.length; i += 1) { total = total + xs[i]; }
	return total + xs.length;
}

function sumRef206(ref r: Roster206): int64 {
	let total: int64 = 0;
	for (const fighter of r.fighters) { total = total + fighter.power; }
	return total * r.fighters.length;
}

function viaRef206(): int64 {
	let roster = roster206();
	return sumRef206(roster);
}

test "bug206: length and for..of of a sized struct field" {
	const roster = roster206();
	let total: int64 = 0;
	for (const fighter of roster.fighters) { total = total + fighter.power; }
	assert total == 10;
	assert roster.fighters.length == 4;
}

test "bug206: length of a local sized array in an expression and as a loop bound" {
	const xs: int32[5] = [1, 2, 3, 4, 5];
	let total: int32 = 0;
	for (let i = 0; i < xs.length; i += 1) { total = total + xs[i]; }
	assert total == 15;
	assert xs.length * 2 - 1 == 9;
}

test "bug206: length of a sized array parameter and through a ref struct" {
	const xs: int64[3] = [10, 20, 30];
	assert sumParam206(xs) == 63;
	assert viaRef206() == 40;
}

test "bug206: length of a nested sized array" {
	const grid: Row206[2] = [[1, 2, 3], [4, 5, 6]];
	let cells: int32 = 0;
	for (const row of grid) { cells = cells + row.length; }
	assert grid.length == 2;
	assert cells == 6;
	assert grid[1].length == 3;
}
