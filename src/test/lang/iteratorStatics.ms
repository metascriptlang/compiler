struct Point {
	x: int32;
	y: int32;
}

function counter(name: string, n: int32, log: string[]): Iterator<int32> {
	let k: int32 = 0;
	return {
		next: () => {
			log.push(`${name}.next`);
			if (k >= n) return { value: 0, done: true };
			k += 1;
			return { value: k, done: false };
		},
		return: () => {
			log.push(`${name}.return`);
			return { value: 0, done: true };
		},
	};
}

function failingNext(log: string[]): Iterator<int32> {
	return {
		next: () => {
			log.push("f.next");
			throw new Error("source failed");
		},
		return: () => {
			log.push("f.return");
			return { value: 0, done: true };
		},
	};
}

function messageOf(body: () => void): string {
	try {
		body();
	} catch (e) {
		return e.message;
	}
	return "no throw";
}

test "iterator concat: opens each source lazily and in order, closing none that finish" {
	const log: string[] = [];
	const c = Iterator.concat<int32>(counter("a", 2, log), counter("b", 1, log));
	assert log.length == 0;
	assert c.toArray().join(",") == "1,2,1";
	assert log.join(",") == "a.next,a.next,a.next,b.next,b.next";
}

test "iterator concat: an early exit closes only the source that is open" {
	const log: string[] = [];
	const r = Iterator.concat<int32>(counter("a", 3, log), counter("b", 3, log)).take(2).toArray();
	assert r.join(",") == "1,2";
	assert log.join(",") == "a.next,a.next,a.return";
}

test "iterator concat: an early exit in the second source leaves the first untouched" {
	const log: string[] = [];
	const r = Iterator.concat<int32>(counter("a", 1, log), counter("b", 3, log)).take(2).toArray();
	assert r.join(",") == "1,1";
	assert log.join(",") == "a.next,a.next,b.next,b.return";
}

test "iterator concat: a source whose next throws is not closed and later sources never open" {
	const log: string[] = [];
	assert messageOf((): void => {
		Iterator.concat<int32>(counter("a", 1, log), failingNext(log), counter("c", 1, log)).toArray();
	}) == "source failed";
	assert log.join(",") == "a.next,a.next,f.next";
}

test "iterator concat: no sources is empty and string elements concatenate" {
	assert Iterator.concat<int32>().toArray().length == 0;
	const words: string[] = ["x", "y"];
	const more: string[] = ["z"];
	const r = Iterator.concat<string>(words.values(), more.values()).toArray();
	assert r.join(",") == "x,y,z";
}

test "iterator concat: composes with the helpers" {
	const log: string[] = [];
	const r = Iterator.concat<int32>(counter("a", 2, log), counter("b", 2, log))
		.map((x: int32, i: number): int32 => x * 10)
		.toArray();
	assert r.join(",") == "10,20,10,20";
}

function rows<T>(r: T[][]): string {
	const out: string[] = [];
	for (const row of r) out.push(row.join(","));
	return out.join("|");
}

test "iterator zip: shortest is the default and closes the others when one finishes" {
	const log: string[] = [];
	const r = Iterator.zip<int32>([counter("a", 2, log), counter("b", 3, log)]).toArray();
	assert rows(r) == "1,1|2,2";
	assert log.join(",") == "a.next,b.next,a.next,b.next,a.next,b.return";
}

test "iterator zip: the finishing source is not closed, the others are" {
	const log: string[] = [];
	const r = Iterator.zip<int32>([counter("a", 3, log), counter("b", 1, log)]).toArray();
	assert rows(r) == "1,1";
	assert log.join(",") == "a.next,b.next,a.next,b.next,a.return";
}

test "iterator zip longest: finished sources are padded and never pulled again" {
	const log: string[] = [];
	const r = Iterator.zip<int32>(
		[counter("a", 1, log), counter("b", 2, log)],
		{ mode: "longest", padding: [0, 9] },
	).toArray();
	assert rows(r) == "1,1|0,2";
	assert log.join(",") == "a.next,b.next,a.next,b.next,b.next";
}

test "iterator zip longest: missing padding fails at the call and closes every source in reverse" {
	const log: string[] = [];
	assert messageOf((): void => {
		Iterator.zip<int32>([counter("a", 1, log), counter("b", 1, log)], { mode: "longest" });
	}) == "zip: mode longest needs one padding value per iterator";
	assert log.join(",") == "b.return,a.return";
}

test "iterator zip strict: equal lengths finish without a close" {
	const log: string[] = [];
	const r = Iterator.zip<int32>(
		[counter("a", 1, log), counter("b", 1, log)],
		{ mode: "strict" },
	).toArray();
	assert rows(r) == "1,1";
	assert log.join(",") == "a.next,b.next,a.next,b.next";
}

test "iterator zip strict: the first source finishing early throws and closes the rest" {
	const log: string[] = [];
	assert messageOf((): void => {
		Iterator.zip<int32>([counter("a", 1, log), counter("b", 2, log)], { mode: "strict" })
			.toArray();
	}) == "zip: iterators have different lengths";
	assert log.join(",") == "a.next,b.next,a.next,b.next,b.return";
}

test "iterator zip strict: a later source finishing early throws and closes the first" {
	const log: string[] = [];
	assert messageOf((): void => {
		Iterator.zip<int32>([counter("a", 2, log), counter("b", 1, log)], { mode: "strict" })
			.toArray();
	}) == "zip: iterators have different lengths";
	assert log.join(",") == "a.next,b.next,a.next,b.next,a.return";
}

test "iterator zip: an early exit closes every source in reverse order" {
	const log: string[] = [];
	const r = Iterator.zip<int32>([counter("a", 3, log), counter("b", 3, log), counter("c", 3, log)])
		.take(1)
		.toArray();
	assert rows(r) == "1,1,1";
	assert log.join(",") == "a.next,b.next,c.next,c.return,b.return,a.return";
}

test "iterator zip: a source whose next throws is not closed and the others are, in reverse" {
	const log: string[] = [];
	assert messageOf((): void => {
		Iterator.zip<int32>([counter("a", 3, log), failingNext(log), counter("c", 3, log)])
			.toArray();
	}) == "source failed";
	assert log.join(",") == "a.next,f.next,c.return,a.return";
}

test "iterator zip: no sources is empty" {
	const none: Iterator<int32>[] = [];
	assert Iterator.zip<int32>(none).toArray().length == 0;
}

test "iterator zip: string and struct elements, and zip of zips" {
	const left: string[] = ["a", "b", "c"];
	const right: string[] = ["x"];
	const s = Iterator.zip<string>(
		[left.values(), right.values()],
		{ mode: "longest", padding: ["-", "-"] },
	).toArray();
	assert rows(s) == "a,x|b,-|c,-";
	const ps: Point[] = [{ x: 1, y: 2 }, { x: 3, y: 4 }];
	const qs: Point[] = [{ x: 5, y: 6 }, { x: 7, y: 8 }];
	const pairs = Iterator.zip<Point>([ps.values(), qs.values()]).toArray();
	assert pairs.length == 2 && pairs[1][0].y == 4 && pairs[1][1].x == 7;
	const log: string[] = [];
	const inner = Iterator.zip<int32>([counter("a", 2, log), counter("b", 2, log)]);
	const outer = Iterator.zip<int32[]>([inner, [[7], [8]].values()]).toArray();
	assert outer.length == 2 && outer[1][0].join(",") == "2,2" && outer[1][1].join(",") == "8";
}
