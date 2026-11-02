// @stdout: 3 -1 2|10 -1|local -1 3
// @exit: 0
// note: a nullable span is a value view with no spare bit for absence, so it carries a present flag like any value type: a read-only byte view parameter given a Vec, an array and null; a mutable int32 view given an array and null; and a local that starts null and is then given a Vec.

function size(bytes: Readonly<Span<uint8>> | null): int32 {
	if (bytes === null) {
		return -1;
	}
	return bytes.length as int32;
}

function total(xs: Span<int32> | null): int32 {
	if (xs === null) {
		return -1;
	}
	let sum: int32 = 0;
	for (const x of xs) {
		sum += x;
	}
	return sum;
}

function main(): void {
	const held: Vec<uint8> = [1, 2, 3];
	const pair: uint8[] = [7, 8];
	const nums: int32[] = [1, 2, 3, 4];
	const passed = `${size(held)} ${size(null)} ${size(pair)}|${total(nums)} ${total(null)}`;
	let view: Readonly<Span<uint8>> | null = null;
	const before = size(view);
	view = held;
	console.log(`${passed}|local ${before} ${size(view)}`);
}
main();
