// @stdout: 4294967295 1 4294967295 2147483647 4294967295 1 4294967295 2147483647 | 4294967288 1 4294967288 2147483644 4294967288 1 4294967288 2147483644 | 3000000000 1 3000000000 1500000000 2147483647 0 2147483647 1073741823 | 2147483647 2147483647 4294967295 4294967294 1073741820,4294967295 calls=2 4294967295 4294967295
// note: `>>>` on an int32 or a `number` is the uint32 TypeScript gives (node prints the same line): by 0, by 31, by 32 (the count masked to 0), by 33, on a struct field, and stored back by `>>>=` into a `number` variable, field and array element, the element index read once.

struct Cell {
	n: number;
	i: int32;
}

function shifts(n: number, i: int32): string {
	return `${n >>> 0} ${n >>> 31} ${n >>> 32} ${n >>> 33} ${i >>> 0} ${i >>> 31} ${i >>> 32} ${i >>> 33}`;
}

let calls: int32 = 0;
function next(): int32 {
	calls += 1;
	return calls - 1;
}

let cell: Cell = { n: -2, i: -2 };
const fromField = `${cell.n >>> 1} ${cell.i >>> 1}`;
let n: number = -1;
n >>>= 0;
cell.n >>>= 0;
const nums: number[] = [-16, -1];
nums[next()] >>>= 2;
nums[next()] >>>= 32;
const i: int32 = -1;
const wide: uint32 = i >>> 0;
const literal = -1 >>> 0;
console.log(`${shifts(-1, -1)} | ${shifts(-8.5, -8)} | ${shifts(3000000000.7, 2147483647)} | ${fromField} ${n} ${cell.n} ${nums.join(",")} calls=${calls} ${wide} ${literal}`);
