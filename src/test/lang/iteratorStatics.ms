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
