// @stdout: same=true,true,true,true
// @stdout: 1,2,3|3,2,1|c,b,a|c,b,a
// @stdout: 3,1,2|2,1,3|b,c
// @stdout: 1,2,3|3,2,1
class P {
	n: int32 = 0;
	constructor(n: int32) {
		this.n = n;
	}
}
const nums: number[] = [3, 1, 2];
const inferred = [3, 1, 2];
const words = ["b", "c", "a"];
const ps: P[] = [new P(2), new P(1), new P(3)];
const sortedNums = nums.sort();
const sortedInferred = inferred.sort();
const sortedWords = words.sort();
const sortedPs = ps.sort((a, b) => a.n - b.n);
console.log(`same=${sortedNums === nums},${sortedInferred === inferred},${sortedWords === words},${sortedPs === ps}`);
const reversedNums = nums.reverse();
const reversedWords = words.reverse();
console.log(`${sortedInferred.join(",")}|${reversedNums.join(",")}|${sortedWords.reverse().reverse().join(",")}|${reversedWords.join(",")}`);
const base = [3, 1, 2];
console.log(`${base.join(",")}|${base.slice().reverse().join(",")}|${["a", "b", "c"].slice(1).join(",")}`);
console.log(`${ps.map((p) => p.n).join(",")}|${ps.reverse().map((p) => p.n).join(",")}`);
