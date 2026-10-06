// Parity program — an array of array literals whose element widths differ widens the element type to
// hold every value, one and two levels deep, an empty literal, a uint64, a float and a field included,
// as TypeScript prints.
//
// @stdout: 4294967295 4294967295 1 | 1 4294967295 | 1 18446744073709551615 | 0 2 | 1 1.5 | 1 4294967295 | 1 4294967295

const cases = [[1, 2], [3, 4294967295]];
const big: int64 = cases[1][1];
const deep = [[[1]], [[4294967295]]];
const u: uint64 = 18446744073709551615;
const unsigned = [[1], [u]];
const empty = [[], [1, 2]];
const fraction = [[1], [1.5]];
const fields = [{ v: [1] }, { v: [4294967295] }];

function pick(c: boolean) {
	return c ? [1] : [4294967295];
}

console.log(`${cases[1][1]} ${big} ${cases[0][0]} | ${deep[0][0][0]} ${deep[1][0][0]} | ${unsigned[0][0]} ${unsigned[1][0]} | ${empty[0].length} ${empty[1][1]} | ${fraction[0][0]} ${fraction[1][0]} | ${fields[0].v[0]} ${fields[1].v[0]} | ${pick(true)[0]} ${pick(false)[0]}`);
