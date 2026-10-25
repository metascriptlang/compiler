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
			log.push("next");
			throw new Error("source failed");
		},
		return: () => {
			log.push("return");
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

test "iterator helpers: every stage runs on an element before the next element is pulled" {
	const log: string[] = [];
	const r = counter("s", 100, log)
		.map((x: int32, i: number): int32 => {
			log.push(`map${x}`);
			return x * 10;
		})
		.filter((y: int32, i: number): boolean => {
			log.push(`filter${y}`);
			return y % 20 == 0;
		})
		.take(1)
		.toArray();
	assert r.join(",") == "20";
	assert log.join(",") == "s.next,map1,filter10,s.next,map2,filter20,s.return";
}

test "iterator helpers: nothing runs until the chain is pulled" {
	const log: string[] = [];
	const chain = counter("s", 3, log).map((x: int32, i: number): int32 => x).take(2);
	assert log.length == 0;
	assert chain.toArray().length == 2;
}

test "iterator take: pulls at most the limit and closes the source on the next pull" {
	const log: string[] = [];
	const t = counter("s", 100, log).take(2);
	t.next();
	t.next();
	assert log.join(",") == "s.next,s.next";
	assert t.next().done;
	assert log.join(",") == "s.next,s.next,s.return";
	assert t.next().done;
	assert log.length == 3;
}

test "iterator take: a limit of zero closes without a pull and a fraction truncates" {
	const log: string[] = [];
	assert counter("z", 5, log).take(0).toArray().length == 0;
	assert log.join(",") == "z.return";
	assert counter("g", 5, log).take(1.7).toArray().join(",") == "1";
}

test "iterator take: an infinite limit takes everything and never closes a finished source" {
	const log: string[] = [];
	assert counter("w", 2, log).take(Infinity).toArray().join(",") == "1,2";
	assert log.join(",") == "w.next,w.next,w.next";
}

test "iterator some, every and find: stop at the first decision and close the source" {
	const log: string[] = [];
	assert counter("a", 100, log).some((x: int32, i: number): boolean => x == 2);
	assert !counter("b", 100, log).every((x: int32, i: number): boolean => x < 3);
	assert counter("c", 100, log).find((x: int32, i: number): boolean => x == 3) == 3;
	assert log.join(",") == "a.next,a.next,a.return,b.next,b.next,b.next,b.return,"
		+ "c.next,c.next,c.next,c.return";
}

test "iterator some, every and find: a source that finishes is not closed" {
	const log: string[] = [];
	assert !counter("a", 2, log).some((x: int32, i: number): boolean => false);
	assert counter("b", 2, log).every((x: int32, i: number): boolean => true);
	assert counter("c", 2, log).find((x: int32, i: number): boolean => false) == null;
	assert log.join(",") == "a.next,a.next,a.next,b.next,b.next,b.next,c.next,c.next,c.next";
}

test "iterator helpers: a throwing callback closes the source and the error wins" {
	const log: string[] = [];
	const boom = (x: int32, i: number): int32 => {
		if (x == 2) throw new Error("boom");
		return x;
	};
	assert messageOf((): void => {
		counter("m", 100, log).map(boom).toArray();
	}) == "boom";
	assert messageOf((): void => {
		counter("f", 100, log).filter((x: int32, i: number): boolean => boom(x, i) > 0).toArray();
	}) == "boom";
	assert messageOf((): void => {
		counter("e", 100, log).forEach((x: int32, i: number): void => {
			boom(x, i);
		});
	}) == "boom";
	assert messageOf((): void => {
		counter("r", 100, log).reduce((a: int32, x: int32, i: number): int32 => a + boom(x, i), 0);
	}) == "boom";
	assert log.join(",") == "m.next,m.next,m.return,f.next,f.next,f.return,e.next,e.next,e.return,"
		+ "r.next,r.next,r.return";
}

test "iterator flatMap: a throwing mapper closes only the outer source" {
	const log: string[] = [];
	const message = messageOf((): void => {
		counter("o", 100, log)
			.flatMap((x: int32, i: number): Iterator<int32> => {
				if (x == 2) throw new Error("boom");
				return counter(`i${x}`, 1, log);
			})
			.toArray();
	});
	assert message == "boom";
	assert log.join(",") == "o.next,i1.next,i1.next,o.next,o.return";
}

test "iterator flatMap: an early exit closes the inner source and then the outer" {
	const log: string[] = [];
	const r = counter("o", 3, log)
		.flatMap((x: int32, i: number): Iterator<int32> => counter(`i${x}`, 3, log))
		.take(2)
		.toArray();
	assert r.join(",") == "1,2";
	assert log.join(",") == "o.next,i1.next,i1.next,i1.return,o.return";
}

test "iterator flatMap: sources that finish are not closed" {
	const log: string[] = [];
	const r = counter("o", 2, log)
		.flatMap((x: int32, i: number): Iterator<int32> => counter(`j${x}`, 1, log))
		.toArray();
	assert r.join(",") == "1,1";
	assert log.join(",") == "o.next,j1.next,j1.next,o.next,j2.next,j2.next,o.next";
}

test "iterator flatMap: a mapper may return an array" {
	const r = [1, 2]
		.values()
		.flatMap((x: int32, i: number): int32[] => [x, x * 10])
		.toArray();
	assert r.join(",") == "1,10,2,20";
}

test "iterator helpers: a consumer break closes the chain" {
	const log: string[] = [];
	for (const x of counter("k", 100, log).map((x: int32, i: number): int32 => x)) {
		if (x == 2) break;
	}
	assert log.join(",") == "k.next,k.next,k.return";
}

test "iterator helpers: a source whose next throws is not closed" {
	const log: string[] = [];
	const message = messageOf((): void => {
		failingNext(log).map((x: int32, i: number): int32 => x).toArray();
	});
	assert message == "source failed";
	assert log.join(",") == "next";
}

test "iterator take and drop: a negative limit fails at the call and closes the receiver" {
	const log: string[] = [];
	assert messageOf((): void => {
		counter("t", 3, log).take(-1);
	}) == "-1 must be positive";
	assert messageOf((): void => {
		counter("d", 3, log).drop(-1);
	}) == "-1 must be positive";
	assert log.join(",") == "t.return,d.return";
}

test "iterator take and drop: NaN fails at the call and a fraction below one is zero" {
	const log: string[] = [];
	assert messageOf((): void => {
		counter("t", 3, log).take(NaN);
	}) == "NaN must be positive";
	assert log.join(",") == "t.return";
	assert counter("d", 3, log).drop(-0.5).toArray().join(",") == "1,2,3";
}

function errorClassOf(body: () => void): string {
	try {
		body();
	} catch (e) {
		if (e instanceof RangeError) return "RangeError";
		if (e instanceof TypeError) return "TypeError";
		return "Error";
	}
	return "no throw";
}

test "iterator helpers: a bad limit or size is a RangeError and a missing value a TypeError, as in TS" {
	const none: int32[] = [];
	const log: string[] = [];
	assert errorClassOf((): void => {
		none.values().take(-1);
	}) == "RangeError";
	assert errorClassOf((): void => {
		none.values().drop(NaN);
	}) == "RangeError";
	assert errorClassOf((): void => {
		none.values().chunks(1.5);
	}) == "RangeError";
	assert errorClassOf((): void => {
		none.values().reduce((a: int32, x: int32, i: number): int32 => a + x);
	}) == "TypeError";
	assert errorClassOf((): void => {
		none.reduce((a: int32, x: int32, i: number): int32 => a + x);
	}) == "TypeError";
	assert errorClassOf((): void => {
		Iterator.zip<int32>([counter("a", 1, log), counter("b", 2, log)], { mode: "strict" }).toArray();
	}) == "TypeError";
}

test "iterator helpers: each helper counts the elements it received" {
	const seen: string[] = [];
	const source = (): Iterator<int32> => [5, 6, 7, 8].values();
	source()
		.filter((x: int32, i: number): boolean => x % 2 == 0)
		.forEach((x: int32, i: number): void => {
			seen.push(`${x}@${i}`);
		});
	source().drop(2).forEach((x: int32, i: number): void => {
		seen.push(`${x}@${i}`);
	});
	source()
		.flatMap((x: int32, i: number): Iterator<number> => [i, i].values())
		.forEach((x: number, i: number): void => {
			seen.push(`${x}@${i}`);
		});
	assert seen.join(",") == "6@0,8@1,7@0,8@1,0@0,0@1,1@2,1@3,2@4,2@5,3@6,3@7";
}

test "iterator helpers: map after filter counts only the survivors" {
	const r = [5, 6, 7, 8]
		.values()
		.filter((x: int32, i: number): boolean => x % 2 == 0)
		.map((x: int32, i: number): string => `${x}@${i}`)
		.toArray();
	assert r.join(",") == "6@0,8@1";
}

test "iterator reduce: without an initial value the callback starts at index 1" {
	const seen: string[] = [];
	const sum = [1, 2, 3].values().reduce((a: int32, x: int32, i: number): int32 => {
		seen.push(`${a}+${x}@${i}`);
		return a + x;
	});
	assert sum == 6;
	assert seen.join(",") == "1+2@1,3+3@2";
}

test "iterator reduce: with an initial value the callback starts at index 0" {
	const seen: string[] = [];
	const sum = [1, 2].values().reduce((a: int32, x: int32, i: number): int32 => {
		seen.push(`${a}+${x}@${i}`);
		return a + x;
	}, 10);
	assert sum == 13;
	assert seen.join(",") == "10+1@0,11+2@1";
}

test "iterator reduce: an empty source fails without an initial value and returns it with one" {
	const none: int32[] = [];
	assert messageOf((): void => {
		none.values().reduce((a: int32, x: int32, i: number): int32 => a + x);
	}) == "Reduce of a done iterator with no initial value";
	assert none.values().reduce((a: int32, x: int32, i: number): int32 => a + x, 7) == 7;
}

test "iterator reduce: one element is returned without calling back" {
	let calls = 0;
	const r = [9].values().reduce((a: int32, x: int32, i: number): int32 => {
		calls += 1;
		return a + x;
	});
	assert r == 9 && calls == 0;
}

test "iterator toArray and forEach: drain a finite chain" {
	const seen: string[] = [];
	counter("h", 2, seen).forEach((x: int32, i: number): void => {
		seen.push(`each${x}@${i}`);
	});
	assert seen.join(",") == "h.next,each1@0,h.next,each2@1,h.next";
	const pair: int32[] = [3, 4];
	assert pair.values().toArray().join(",") == "3,4";
}

test "iterator helpers: a chain is single pass" {
	const log: string[] = [];
	const chain = counter("p", 2, log).map((x: int32, i: number): int32 => x);
	assert chain.toArray().join(",") == "1,2";
	assert chain.toArray().length == 0;
	assert log.join(",") == "p.next,p.next,p.next";
}

test "iterator helpers: string elements" {
	const words: string[] = ["a", "bb", "ccc", "dd"];
	const r = words
		.values()
		.filter((w: string, i: number): boolean => w.length != 3)
		.map((w: string, i: number): string => `${w}${i}`)
		.drop(1)
		.toArray();
	assert r.join(",") == "bb1,dd2";
	assert words.values().find((w: string, i: number): boolean => w.length == 3) == "ccc";
	assert words.values().reduce((n: int32, w: string, i: number): int32 => n + w.length, 0) == 8;
}

test "iterator helpers: struct elements" {
	const points: Point[] = [{ x: 1, y: 2 }, { x: 3, y: 4 }, { x: 5, y: 6 }];
	const r = points
		.values()
		.filter((p: Point, i: number): boolean => p.x > 1)
		.map((p: Point, i: number): int32 => p.x + p.y)
		.toArray();
	assert r.join(",") == "7,11";
	assert points.values().some((p: Point, i: number): boolean => p.y == 6);
	assert points.values().every((p: Point, i: number): boolean => p.x < p.y);
}

function rows<T>(r: T[][]): string {
	const out: string[] = [];
	for (const row of r) out.push(row.join(","));
	return out.join("|");
}

test "iterator chunks: groups in order and yields the short tail" {
	const log: string[] = [];
	assert rows(counter("c", 5, log).chunks(2).toArray()) == "1,2|3,4|5";
	assert log.join(",") == "c.next,c.next,c.next,c.next,c.next,c.next";
	assert rows(counter("e", 4, log).chunks(2).toArray()) == "1,2|3,4";
}

test "iterator chunks: an early exit closes the source" {
	const log: string[] = [];
	const r = counter("c", 9, log).chunks(2).take(1).toArray();
	assert rows(r) == "1,2";
	assert log.join(",") == "c.next,c.next,c.return";
}

test "iterator chunks: a bad size fails at the call, closes the receiver and names the error" {
	const log: string[] = [];
	assert messageOf((): void => {
		counter("a", 3, log).chunks(0);
	}) == "chunkSize must be between 1 and 4294967295";
	assert messageOf((): void => {
		counter("b", 3, log).chunks(4294967296);
	}) == "chunkSize must be between 1 and 4294967295";
	assert messageOf((): void => {
		counter("c", 3, log).chunks(1.5);
	}) == "chunkSize must be an integer";
	assert messageOf((): void => {
		counter("d", 3, log).chunks(NaN);
	}) == "chunkSize must be an integer";
	assert log.join(",") == "a.return,b.return,c.return,d.return";
}

test "iterator windows: slides one element and drops the undersized tail by default" {
	const log: string[] = [];
	assert rows(counter("w", 5, log).windows(3).toArray()) == "1,2,3|2,3,4|3,4,5";
	assert rows(counter("s", 2, log).windows(3).toArray()) == "";
}

test "iterator windows: allow-partial yields one short window only when the source ran short" {
	const log: string[] = [];
	assert rows(counter("p", 2, log).windows(3, "allow-partial").toArray()) == "1,2";
	assert rows(counter("f", 4, log).windows(3, "allow-partial").toArray()) == "1,2,3|2,3,4";
	assert rows(counter("o", 1, log).windows(1, "allow-partial").toArray()) == "1";
	assert counter("z", 0, log).windows(2, "allow-partial").toArray().length == 0;
}

test "iterator windows: every window is its own array" {
	const all = counter("w", 4, []).windows(2).toArray();
	all[0].push(99);
	assert rows(all) == "1,2,99|2,3|3,4";
}

test "iterator windows: a bad size closes the receiver and an early exit closes the source" {
	const log: string[] = [];
	assert messageOf((): void => {
		counter("a", 3, log).windows(0);
	}) == "windowSize must be between 1 and 4294967295";
	assert messageOf((): void => {
		counter("b", 3, log).windows(2.5, "allow-partial");
	}) == "windowSize must be an integer";
	assert rows(counter("c", 9, log).windows(2).take(1).toArray()) == "1,2";
	assert log.join(",") == "a.return,b.return,c.next,c.next,c.return";
}

test "iterator chunks and windows: string and struct elements" {
	const words: string[] = ["a", "b", "c"];
	assert rows(words.values().chunks(2).toArray()) == "a,b|c";
	assert rows(words.values().windows(2).toArray()) == "a,b|b,c";
	const points: Point[] = [{ x: 1, y: 2 }, { x: 3, y: 4 }, { x: 5, y: 6 }];
	const w = points.values().windows(2).toArray();
	assert w.length == 2 && w[0][1].x == 3 && w[1][0].y == 4;
	const c = points.values().chunks(2).toArray();
	assert c.length == 2 && c[0][1].y == 4 && c[1].length == 1 && c[1][0].x == 5;
}

test "iterator cycle: buffers the first pass, then repeats it without touching the source" {
	const log: string[] = [];
	assert counter("a", 2, log).cycle().take(5).toArray().join(",") == "1,2,1,2,1";
	assert log.join(",") == "a.next,a.next,a.next";
}

test "iterator cycle: an empty source ends and an early exit closes the open source" {
	const log: string[] = [];
	assert counter("e", 0, log).cycle().toArray().length == 0;
	assert counter("b", 3, log).cycle().take(1).toArray().join(",") == "1";
	assert log.join(",") == "e.next,b.next,b.return";
}

test "iterator cycle: string elements" {
	const xy: string[] = ["x", "y"];
	assert xy.values().cycle().take(5).toArray().join("") == "xyxyx";
}

test "iterator stepBy: yields the first element and then every step-th, pulling lazily" {
	const log: string[] = [];
	assert counter("s", 7, log).stepBy(3).toArray().join(",") == "1,4,7";
	assert log.length == 8;
	const early: string[] = [];
	assert counter("t", 9, early).stepBy(2).take(2).toArray().join(",") == "1,3";
	assert early.join(",") == "t.next,t.next,t.next,t.return";
	assert counter("u", 3, early).stepBy(1).toArray().join(",") == "1,2,3";
	const abcd: string[] = ["a", "b", "c", "d"];
	assert abcd.values().stepBy(3).toArray().join("") == "ad";
}

test "iterator stepBy: a bad step throws eagerly and closes the source" {
	const log: string[] = [];
	assert messageOf((): void => {
		counter("a", 3, log).stepBy(0);
	}) == "step must be between 1 and 4294967295";
	assert messageOf((): void => {
		counter("b", 3, log).stepBy(1.5);
	}) == "step must be an integer";
	assert log.join(",") == "a.return,b.return";
}

test "iterator scan: yields each accumulated value with the element index" {
	const log: string[] = [];
	const sums = counter("a", 3, log).scan((acc: int32, x: int32): int32 => acc + x, 0);
	assert log.length == 0;
	assert sums.toArray().join(",") == "1,3,6";
	const fives: number[] = [5, 5, 5];
	const idx = fives.values().scan((acc: string, x: number, i: number): string => `${acc}${x + i}`, "");
	assert idx.toArray().join(",") == "5,56,567";
	assert counter("b", 1, log).scan((acc: int32, x: int32): int32 => acc, 7).toArray().join(",") == "7";
}

test "iterator scan: an early exit closes the source" {
	const log: string[] = [];
	counter("a", 5, log).scan((acc: int32, x: int32): int32 => acc + x, 0).take(1).toArray();
	assert log.join(",") == "a.next,a.return";
}

test "iterator peekable: peek does not consume and is null once the source is done" {
	const log: string[] = [];
	const p = counter("a", 2, log).peekable();
	assert log.length == 0;
	assert `${p.peek()}` == "1" && `${p.peek()}` == "1";
	assert log.join(",") == "a.next";
	assert p.next().value == 1;
	assert `${p.peek()}` == "2";
	assert p.next().value == 2;
	assert p.peek() == null && p.peek() == null;
	assert log.join(",") == "a.next,a.next,a.next";
}

test "iterator peekable: works in for-of and with the helpers" {
	const ones: number[] = [1, 2, 3];
	const p = ones.values().peekable();
	let seen = "";
	for (const x of p) seen += `${x}:${p.peek()} `;
	assert seen == "1:2 2:3 3:null ";
	const q = ones.values().peekable();
	assert `${q.peek()}` == "1";
	assert q.map((x: number): number => x * 2).toArray().join(",") == "2,4,6";
	const words = ["a", "b"].values().peekable();
	assert words.peek() == "a";
	assert words.toArray<string>().join("") == "ab";
}

test "iterator peekable: return closes the source" {
	const log: string[] = [];
	const p = counter("a", 3, log).peekable();
	p.peek();
	p.take<int32>(1).toArray<int32>();
	assert log.join(",") == "a.next,a.return";
}

function pulled(pulls: int32[], n: int32, closable: boolean): Iterator<int32> {
	return {
		next: () => {
			pulls[0] += 1;
			if (pulls[0] > n) return { value: 0, done: true };
			return { value: pulls[0], done: false };
		},
		return: closable ? () => {
			pulls[1] += 1;
			return { value: 0, done: true };
		} : null,
	};
}

test "iterator peekable: closing a source without return pulls nothing more" {
	const pulls: int32[] = [0, 0];
	for (const x of pulled(pulls, 9, false).peekable<int32>().toItems<int32>()) {
		if (x == 2) break;
	}
	assert pulls[0] == 2;
	let taken = 0;
	const names: Iterator<string> = {
		next: () => {
			taken += 1;
			return { value: `n${taken}`, done: false };
		},
		return: null,
	};
	const it = names.peekable<string>();
	assert it.peek() == "n1";
	assert it.return == null;
	assert taken == 1;
}

test "iterator peekable: return closes the source once, drops the peeked element and ends" {
	const pulls: int32[] = [0, 0];
	const p = pulled(pulls, 9, true).peekable<int32>();
	assert `${p.peek()}` == "1";
	assert p.return != null;
	if (p.return != null) assert p.return().done;
	assert pulls[0] == 1 && pulls[1] == 1;
	assert p.next().done && p.peek() == null;
	assert pulls[0] == 1;
}

test "iterator peekable: a source that reported done is not pulled again" {
	const pulls: int32[] = [0, 0];
	const p = pulled(pulls, 1, true).peekable<int32>();
	assert p.next().value == 1;
	assert p.peek() == null && p.peek() == null;
	assert p.next().done && p.next().done;
	assert pulls[0] == 2;
	const q = pulled(pulls, 0, true).peekable<int32>();
	assert q.next().done && q.next().done && q.peek() == null;
	assert pulls[0] == 3;
}

function throwingReturn(log: string[]): Iterator<int32> {
	let k: int32 = 0;
	return {
		next: () => {
			log.push("next");
			k += 1;
			return { value: k, done: false };
		},
		return: () => {
			log.push("return");
			throw new Error("close failed");
		},
	};
}

function closeOutcome(body: (it: Iterator<int32>) => void): string {
	const log: string[] = [];
	return `${messageOf(() => body(throwingReturn(log)))} ${log.join(",")}`;
}

test "iterator close: a throwing return propagates from an early exit" {
	const early = "close failed next,return";
	assert closeOutcome((it: Iterator<int32>): void => { it.take<int32>(1).toArray<int32>(); }) == early;
	assert closeOutcome((it: Iterator<int32>): void => {
		it.some<int32>((x: int32, i: number): boolean => x == 1);
	}) == early;
	assert closeOutcome((it: Iterator<int32>): void => {
		it.find<int32>((x: int32, i: number): boolean => x == 1);
	}) == early;
	assert closeOutcome((it: Iterator<int32>): void => {
		for (const x of it.map<int32, int32>((y: int32, i: number): int32 => y)) break;
	}) == early;
}

test "iterator close: the body's error wins over a throwing return" {
	const early = "body failed next,return";
	assert closeOutcome((it: Iterator<int32>): void => {
		for (const x of it.map<int32, int32>((y: int32, i: number): int32 => y)) throw new Error("body failed");
	}) == early;
	assert closeOutcome((it: Iterator<int32>): void => {
		for (const x of it) throw new Error("body failed");
	}) == early;
	assert closeOutcome((it: Iterator<int32>): void => {
		it.map<int32, int32>((x: int32, i: number): int32 => { throw new Error("body failed"); }).toArray<int32>();
	}) == early;
}

test "iterator close: a throwing return propagates for string elements" {
	let pulls = 0;
	const names: Iterator<string> = {
		next: () => {
			pulls += 1;
			return { value: `n${pulls}`, done: false };
		},
		return: () => {
			throw new Error("close failed");
		},
	};
	assert messageOf(() => { names.take<string>(1).toArray<string>(); }) == "close failed";
	assert messageOf(() => { names.find<string>((x: string, i: number): boolean => x == "n2"); }) == "close failed";
}

test "iterator sum, min and max: reductions with null for an empty min and max" {
	const log: string[] = [];
	assert counter("a", 4, log).sum() == 10;
	assert counter("e", 0, log).sum() == 0;
	const halves: number[] = [1.5, 2.25];
	assert halves.values().sum() == 3.75;
	assert `${counter("b", 4, log).min()}` == "1" && `${counter("c", 4, log).max()}` == "4";
	assert counter("e", 0, log).min() == null && counter("e", 0, log).max() == null;
	const nums: number[] = [3, 1, 2];
	assert nums.values().min() == 1 && nums.values().max() == 3;
	const words: string[] = ["b", "a", "c"];
	assert words.values().min() == "a" && words.values().max() == "c";
}

test "iterator consumer: a compound assignment reads its target before the chain runs, as in TS" {
	const nums: int32[] = [1, 2, 3];
	let t: int32 = 10;
	t += nums.values().map((x: int32, i: number): int32 => x * 2).reduce((acc: int32, x: int32, i: number): int32 => {
		t = 100;
		return acc + x;
	}, 0);
	assert t == 22;
	const words: string[] = ["b", "c"];
	let s = "a";
	s += words.values().reduce((acc: string, x: string, i: number): string => {
		s = "z";
		return acc + x;
	}, "");
	assert s == "abc";
}
