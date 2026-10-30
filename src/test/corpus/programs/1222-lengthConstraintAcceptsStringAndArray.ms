// @stdout: abc 3 7 hello
function longest<T extends { length: number }>(a: T, b: T): T { return a.length >= b.length ? a : b; }
function total<T extends { length: number }>(items: T[]): number {
	let n = 0;
	for (const item of items) n += item.length;
	return n;
}
console.log(longest("abc", "de"), longest([1, 2, 3], [1]).length, total(["ab", "cde", "fg"]), longest("hello", "hi"));
