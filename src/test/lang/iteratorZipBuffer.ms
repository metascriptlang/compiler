function rows<T>(r: T[][]): string {
	const out: string[] = [];
	for (const row of r) out.push(row.join(","));
	return out.join("|");
}

when (c) {
	test "iterator zip: each pair is allocated for exactly the number of sources" {
		const it = Iterator.zip<int32>([[1, 2].values(), [10, 20].values(), [100, 200].values()]);
		const first = it.next();
		assert first.value.length == 3;
		assert first.value.capacity() == 3;
	}
}

test "iterator zip: a for-of that keeps every pair sees each pair intact" {
	const kept: int32[][] = [];
	for (const pair of Iterator.zip<int32>([[1, 2, 3].values(), [10, 20, 30].values()])) kept.push(pair);
	assert rows(kept) == "1,10|2,20|3,30";
	const words: string[][] = [];
	for (const pair of Iterator.zip<string>([["a", "b"].values(), ["x", "y"].values()])) words.push(pair);
	assert rows(words) == "a,x|b,y";
}

test "iterator zip: pairs held across later steps keep their values" {
	const it = Iterator.zip<int32>([[1, 2, 3].values(), [10, 20, 30].values()]);
	const r1 = it.next();
	const r2 = it.next();
	const r3 = it.next();
	assert r1.value.join(",") == "1,10";
	assert r2.value.join(",") == "2,20";
	assert r3.value.join(",") == "3,30";
	const names = Iterator.zip<string>([["a", "b"].values(), ["x", "y"].values()]);
	const s1 = names.next();
	const s2 = names.next();
	assert s1.value.join(",") == "a,x";
	assert s2.value.join(",") == "b,y";
}

test "iterator zip: a pair kept after the loop keeps its values" {
	let held: int32[] = [];
	let heldWord: string[] = [];
	let total: int32 = 0;
	for (const pair of Iterator.zip<int32>([[1, 2, 3].values(), [10, 20, 30].values()])) {
		if (pair[0] == 2) held = pair;
		total += pair[0] * pair[1];
	}
	for (const pair of Iterator.zip<string>([["a", "b", "c"].values(), ["x", "y", "z"].values()])) {
		if (pair[0] == "b") heldWord = pair;
	}
	assert held.join(",") == "2,20";
	assert heldWord.join(",") == "b,y";
	assert total == 10 + 40 + 90;
}

test "iterator zip: a consumer that keeps nothing reads every pair in order" {
	let seen = "";
	for (const pair of Iterator.zip<int32>([[1, 2, 3].values(), [10, 20, 30].values()])) seen += pair.join(",") + ";";
	assert seen == "1,10;2,20;3,30;";
	let padded = "";
	for (const pair of Iterator.zip<int32>([[1, 2, 3].values(), [10].values()], { mode: "longest", padding: [0, -1] })) padded += pair.join(",") + ";";
	assert padded == "1,10;2,-1;3,-1;";
}
