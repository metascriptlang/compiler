// @stdout: 7 2 5 2147483645 -2147483648 -3 15 28
// @stdout: 7
// @exit: 0
// note: a compound bitwise or shift assignment on a number local, parameter, field, array element and global works on int32 bits and stores a number back.

class Box { v: number = 6; }
function compound(x: number, y: number): string {
	let a = x; a |= 1;
	let b = x; b &= y;
	let c = x; c ^= 3;
	let d = -x; d >>>= 1;
	let e = x; e <<= 30;
	let f = -x; f >>= 1;
	const box = new Box(); box.v |= 9;
	const arr: number[] = [6, 7]; arr[1] <<= 2;
	return `${a} ${b} ${c} ${d} ${e} ${f} ${box.v} ${arr[1]}`;
}
console.log(compound(6, 3));
let g: number = 5; g |= 2; console.log(g);
