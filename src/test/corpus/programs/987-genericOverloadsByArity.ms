// @stdout: 3 1,2,3 | x,y,z | 1 2
function put<T>(a: T[], x: T): void { a.push(x); }
function put<T>(a: T[], x: T, y: T): void {
	a.push(x);
	a.push(y);
}

function count<T>(x: T): int32 { return 1; }
function count<T, U>(x: T, y: U): int32 { return 2; }

const nums: int32[] = [];
put(nums, 1 as int32);
put(nums, 2 as int32, 3 as int32);
const words: string[] = [];
put(words, "x", "y");
put(words, "z");
console.log(`${nums.length} ${nums[0]},${nums[1]},${nums[2]} | ${words.join(",")} | ${count(1 as int32)} ${count(1 as int32, "s")}`);
