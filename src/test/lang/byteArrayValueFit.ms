test "byte arrays: generic operations preserve narrow element stride and values" {
	const bytes: uint8[] = [10, 20, 30];
	assert bytes.indexOf(20) == 1;
	assert bytes.indexOf(99) == -1;
	assert bytes.includes(30);
	assert !bytes.includes(99);
	assert bytes.count(20) == 1;
	assert bytes.pop() == 30;
	assert bytes.shift() == 10;
	assert bytes.length == 1 && bytes[0] == 20;
	const source: uint8[] = [1, 2, 3, 4];
	const slice = source.slice(1, 3);
	assert slice.length == 2 && slice[0] == 2 && slice[1] == 3;
	slice.fill(9);
	assert slice[0] == 9 && slice[1] == 9;
	assert source[1] == 2 && source[2] == 3;
	source.reverse();
	assert source[0] == 4 && source[3] == 1;
	const extra: uint8[] = [5];
	const combined = source.concat(extra);
	assert combined.length == 5 && combined[0] == 4 && combined[4] == 5;
	assert source.length == 4 && extra.length == 1;
}

test "byte arrays: copied string views own growth without mutating the source" {
	const variants = [
		{ source: "abc", last: 99 },
		{ source: "ab" + (3).toString(), last: 51 },
	];
	for (const variant of variants) {
		const view = variant.source.asBytes();
		assert view.indexOf(98) == 1;
		const middle = view.slice(1, 3);
		assert middle.length == 2 && middle[0] == 98 && middle[1] == variant.last;
		const owned = view.slice(0);
		owned.push(33);
		for (let i = 1; i < 40; i += 1) owned.push(88);
		assert owned.length == 43;
		assert owned[0] == 97 && owned[2] == variant.last;
		assert owned[3] == 33 && owned[42] == 88;
		assert variant.source.length == 3;
		assert view.length == 3 && view[2] == variant.last;
		const neighbor = "hello-neighbor";
		assert neighbor.length == 14;
		assert neighbor.charCodeAt(0) == 104 && neighbor.charCodeAt(13) == 114;
	}
}

test "array lookup: generic integer and extern number or string surfaces agree on indices" {
	const inferred = [10, 20, 30];
	const integers: int32[] = [10, 20, 30];
	const numbers: number[] = [10.5, 20.5];
	const strings: string[] = ["a", "b"];
	assert inferred.indexOf(20) == 1;
	assert integers.indexOf(20) == 1 && integers.includes(30);
	assert numbers.indexOf(20.5) == 1 && numbers.includes(10.5);
	assert strings.indexOf("b") == 1;
}
