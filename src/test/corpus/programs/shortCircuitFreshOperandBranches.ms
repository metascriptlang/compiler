// @stdout: and: 2 6
// @stdout: or: 2 6
// @stdout: loop: 3
// note: an `if` whose `&&` or `||` right operand makes a fresh string takes the branch its operands pick, on the first operand alone and on both.
const WORDS: Readonly<string[]> = ["ab", "b-"];

function andAt(text: string, i: int32, word: string): boolean {
	if (text.charCodeAt(i) == word.charCodeAt(0) && text.slice(i, i + word.length) == word) return true;
	return false;
}

function orAt(text: string, i: int32, word: string): boolean {
	if (text.charCodeAt(i) != word.charCodeAt(0) || text.slice(i, i + word.length) != word) return false;
	return true;
}

const text = "a-ab-aab";
let ands = "";
let ors = "";
let n = 0;
for (let i: int32 = 0; i < text.length; i += 1) {
	if (andAt(text, i, "ab")) ands = ands + " " + i.toString();
	if (orAt(text, i, "ab")) ors = ors + " " + i.toString();
	for (const w of WORDS) {
		if (andAt(text, i, w)) n += 1;
	}
}
console.log(`and:${ands}`);
console.log(`or:${ors}`);
console.log(`loop: ${n}`);
