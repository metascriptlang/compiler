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
