// @stdout: module: h e l
// @stdout: found: 2 0
// @stdout: local: 6
// @stdout: skipped: 1 3
// note: a for-of over a const read-only array literal visits each element once, in order, through calls, early returns and continue.
const LETTERS: Readonly<string[]> = ["h", "e", "l"];

function spell(): string {
	let out = "";
	for (const c of LETTERS) out = out + " " + c;
	return out;
}

function indexOf(c: string): int32 {
	let i: int32 = 0;
	for (const l of LETTERS) {
		if (l == c) return i;
		i += 1;
	}
	return -1;
}

function sum(): int32 {
	const NUMS: Readonly<int32[]> = [1, 2, 3];
	let total: int32 = 0;
	for (const n of NUMS) total += n;
	return total;
}

function odd(): string {
	const NUMS: Readonly<int32[]> = [1, 2, 3];
	let out = "";
	for (const n of NUMS) {
		if (n % 2 == 0) continue;
		out = out + " " + n.toString();
	}
	return out;
}

console.log(`module:${spell()}`);
console.log(`found: ${indexOf("l")} ${indexOf("h")}`);
console.log(`local: ${sum()}`);
console.log(`skipped:${odd()}`);

