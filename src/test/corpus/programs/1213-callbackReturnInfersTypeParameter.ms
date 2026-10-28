// @stdout: 4 1,1,2,2 a,a 6 x-1
function fm<T, U>(xs: T[], f: (x: T) => U[]): U[] {
	const out: U[] = [];
	for (const x of xs) {
		for (const y of f(x)) out.push(y);
	}
	return out;
}
function mp<T, U>(xs: T[], f: (x: T) => U): U[] {
	const out: U[] = [];
	for (const x of xs) out.push(f(x));
	return out;
}
const dup = fm([1, 2], x => [x, x]);
const letters = fm(["a"], s => [s, s]);
const nested = mp([1, 2], x => [x, x + 1]);
const named = mp([1], n => "x-" + n.toString());
console.log(dup.length, dup.join(","), letters.join(","), nested.length + nested[1].length + 2, named[0]);
