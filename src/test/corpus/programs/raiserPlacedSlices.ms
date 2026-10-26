// @stdout: 2 3 5
// @stdout: 1 26
// @stdout: 2 b c
// note: an array slice is a borrowed view of its array: the view cell the VM builds for it goes when the array does, for a number array, a string array, a slice inside a loop, and a slice of a slice.
function numbers(): void {
	const a: uint8[] = [1, 2, 3, 4, 5];
	const v = a[1...2];
	const w = a[2...4];
	console.log(v.length, w[0], w[2]);
	let total = 0;
	for (let i = 0; i < 3; i++) {
		const part = a[i...i + 1];
		total += part.length;
	}
	const mid = a[1...3];
	const inner = mid[1...1];
	console.log(inner.length, total * 4 + 2);
}
function words(): void {
	const s: string[] = ["a", "b", "c", "d"];
	const v = s[1...2];
	console.log(v.length, v[0], v[1]);
}
numbers();
words();
