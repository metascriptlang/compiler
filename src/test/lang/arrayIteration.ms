struct Point {
	x: int32;
	y: int32;
}

test "array every: true for empty, stops at the first miss, passes the index" {
	const xs: int32[] = [2, 4, 5, 6];
	let calls = 0;
	const empty: int32[] = [];
	assert empty.every((x: int32, i: number): boolean => false);
	assert !xs.every((x: int32, i: number): boolean => {
		calls += 1;
		return x % 2 == 0;
	});
	assert calls == 3;
	assert xs.every((x: int32, i: number): boolean => i < 4);
}

test "array every: other element types" {
	const words: string[] = ["a", "bb", "cc"];
	const points: Point[] = [{ x: 1, y: 1 }, { x: 2, y: 2 }];
	assert words.every((w: string, i: number): boolean => w.length > 0);
	assert !words.every((w: string, i: number): boolean => w.length == 1);
	assert points.every((p: Point, i: number): boolean => p.x == p.y);
}

test "array every: elements pushed by the callback are not visited" {
	const xs: int32[] = [1, 2];
	let calls = 0;
	assert xs.every((x: int32, i: number): boolean => {
		calls += 1;
		xs.push(x + 10);
		return true;
	});
	assert calls == 2;
	assert xs.length == 4;
}

test "array map, filter, find, findIndex and some: elements pushed by the callback are not visited, as in TS" {
	const xs: int32[] = [1, 2];
	let calls = 0;
	const grow = (x: int32, i: number): boolean => {
		calls += 1;
		if (xs.length < 20) xs.push(x + 10);
		return false;
	};
	assert xs.map((x: int32, i: number): int32 => {
		grow(x, i);
		return x;
	}).length == 2;
	assert xs.filter(grow).length == 0;
	assert xs.find(grow) == null;
	assert xs.findIndex(grow) == -1;
	assert !xs.some(grow);
	assert calls == 2 + 4 + 8 + 16 + 20;
}

test "array filter, find, findLastIndex and map: a callback that shrinks the array never reads past its end" {
	const fresh = (): int32[] => [1, 2, 3, 4, 5, 6];
	let xs = fresh();
	const seen: string[] = [];
	const shrink = (x: int32, i: number): boolean => {
		seen.push(`${i}:${x}`);
		if (xs.length > 2) {
			xs.pop();
			xs.pop();
			xs.pop();
		}
		return false;
	};
	assert xs.findLastIndex(shrink) == -1;
	assert seen[0] == "5:6";
	xs = fresh();
	assert xs.filter((x: int32, i: number): boolean => {
		shrink(x, i);
		return true;
	}).join(",") == "1,2";
	xs = fresh();
	assert xs.find((x: int32, i: number): boolean => {
		shrink(x, i);
		return i == 1;
	}) == 2;
	xs = fresh();
	const mapped = xs.map((x: int32, i: number): int32 => {
		shrink(x, i);
		return x * 10;
	});
	assert mapped[0] == 10 && mapped[1] == 20;
}

test "array reduce: without an initial value starts at index 1" {
	const xs: int32[] = [1, 2, 3, 4];
	let first: number = -1;
	const sum = xs.reduce((acc: int32, x: int32, i: number): int32 => {
		if (first < 0) first = i;
		return acc + x;
	});
	assert sum == 10;
	assert first == 1;
	const one: int32[] = [7];
	assert one.reduce((acc: int32, x: int32, i: number): int32 => acc + 100) == 7;
}

test "array reduce: with an initial value starts at index 0 and the accumulator type may differ" {
	const xs: int32[] = [1, 2, 3];
	let first: number = -1;
	const text = xs.reduce((acc: string, x: int32, i: number): string => {
		if (first < 0) first = i;
		return acc + x;
	}, "n");
	assert text == "n123";
	assert first == 0;
	const none: int32[] = [];
	assert none.reduce((acc: string, x: int32, i: number): string => acc + x, "init") == "init";
	const words: string[] = ["a", "bb", "ccc"];
	assert words.reduce((acc: int32, w: string, i: number): int32 => acc + w.length, 0) == 6;
	assert words.reduce((acc: string, w: string, i: number): string => acc + w) == "abbccc";
}

test "array reduce: an empty array without an initial value fails with the same message" {
	const none: int32[] = [];
	try {
		none.reduce((acc: int32, x: int32, i: number): int32 => acc + x);
		assert false;
	} catch (e) {
		assert e.message == "Reduce of empty array with no initial value";
	}
}

test "array reduce: elements pushed by the callback are not visited" {
	const xs: int32[] = [1, 2, 3];
	const sum = xs.reduce((acc: int32, x: int32, i: number): int32 => {
		xs.push(100);
		return acc + x;
	}, 0);
	assert sum == 6;
	assert xs.length == 6;
}

test "array values keys entries: yield elements, indices and pairs in order" {
	const xs: string[] = ["a", "b", "c"];
	let vs = "";
	for (const v of xs.values()) vs += v;
	let ks = "";
	for (const k of xs.keys()) ks += `${k},`;
	let es = "";
	for (const [k, v] of xs.entries()) es += `${k}${v};`;
	assert vs == "abc";
	assert ks == "0,1,2,";
	assert es == "0a;1b;2c;";
}

test "array values: reads the length at every step so a pushed element is visited" {
	const xs: int32[] = [1, 2];
	let seen = "";
	for (const v of xs.values()) {
		seen += `${v},`;
		if (v < 3) xs.push(v + 2);
	}
	assert seen == "1,2,3,4,";
}

test "array keys entries: pushed elements are visited and break stops early" {
	const xs: int32[] = [5];
	let ks = "";
	for (const k of xs.keys()) {
		ks += `${k},`;
		if (xs.length < 3) xs.push(0);
	}
	assert ks == "0,1,2,";
	const ys: int32[] = [1, 2, 3, 4];
	let sum = 0;
	for (const [i, v] of ys.entries()) {
		if (i == 2) break;
		sum += v;
	}
	assert sum == 3;
}

test "array values: struct elements and an empty array" {
	const points: Point[] = [{ x: 1, y: 2 }, { x: 3, y: 4 }];
	let total = 0;
	for (const p of points.values()) total += p.x + p.y;
	assert total == 10;
	const none: int32[] = [];
	let n = 0;
	for (const v of none.values()) n += 1;
	assert n == 0;
}

test "map and hash map keys and values still return arrays" {
	const m = new Map<string, int32>();
	m.set("a", 1);
	m.set("b", 2);
	assert m.keys().length == 2;
	assert m.values().length == 2;
	const h = new HashMap<string, int32>();
	h.set("a", 1);
	assert h.keys().length == 1;
	assert h.values()[0] == 1;
}
