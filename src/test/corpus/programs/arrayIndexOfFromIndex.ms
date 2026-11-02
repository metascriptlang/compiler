// @stdout: 2 2 2 3|-1 0 2|true false true|2 -1 0|2 3 false
// @exit: 0

const bytes: uint8[] = [10, 1, 10, 2];
const nums: number[] = [5, 6, 5, 7];
const words: string[] = ["a", "b", "a", "c"];
const ints: int32[] = [4, 3, 4, 3];
const fixed: uint8[4] = [10, 1, 10, 2];
console.log(`${bytes.indexOf(10, 1)} ${nums.indexOf(5, 1)} ${words.indexOf("a", 1)} ${ints.indexOf(3, 2)}`
	+ `|${nums.indexOf(5, 9)} ${words.indexOf("a", -9)} ${bytes.indexOf(10, -2)}`
	+ `|${nums.includes(7, -1)} ${words.includes("b", 2)} ${bytes.includes(2, 3)}`
	+ `|${words.indexOf("a", -2)} ${ints.indexOf(4, 3)} ${bytes.indexOf(10)}`
	+ `|${fixed.indexOf(10, 1)} ${fixed.indexOf(2, -1)} ${fixed.includes(1, 2)}`);
