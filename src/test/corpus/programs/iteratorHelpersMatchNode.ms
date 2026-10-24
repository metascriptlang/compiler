// @xfail(raiser): a call through the narrowed `return` field inside a generic is an unknown host function (inbox 2026-10-25-raiser-calls-a-narrowed-nullable-function-field-in-a-generic-as-a-host-function)
// Iterator helpers trace the same events as the native ES2025 helpers: which stage runs per
// element, when the source is closed, what an eager argument check does.
// @stdout: ok
const trace: string[] = [];

function log(s: string): void {
	trace.push(s);
}

function counter(name: string, n: int32): Iterator<int32> {
	let k: int32 = 0;
	return {
		next: () => {
			log(`${name}.next`);
			if (k >= n) return { value: 0, done: true };
			k += 1;
			return { value: k, done: false };
		},
		return: () => {
			log(`${name}.return`);
			return { value: 0, done: true };
		},
	};
}

function failing(name: string): Iterator<int32> {
	let k: int32 = 0;
	return {
		next: () => {
			log(`${name}.next`);
			k += 1;
			if (k == 2) throw new Error("nx");
			return { value: k, done: false };
		},
		return: () => {
			log(`${name}.return`);
			return { value: 0, done: true };
		},
	};
}

function section(name: string, body: () => void): void {
	log(`# ${name}`);
	try {
		body();
	} catch (e) {
		log(`threw ${e.message}`);
	}
}

function pull(it: Iterator<int32>): void {
	const r = it.next();
	log(r.done ? "pulled done" : `pulled ${r.value}`);
}

section("map then filter then take interleave per element", (): void => {
	const r = counter("a", 100)
		.map((x: int32, i: number): int32 => {
			log(`map ${x}@${i}`);
			return x * 10;
		})
		.filter((y: int32, i: number): boolean => {
			log(`filter ${y}@${i}`);
			return y % 20 == 0;
		})
		.take(2)
		.toArray();
	log(`result ${r.join(",")}`);
});

section("take closes the source on the next pull", (): void => {
	const t = counter("b", 100).take(2);
	log("built");
	pull(t);
	pull(t);
	log("two pulled");
	pull(t);
	pull(t);
});

section("drop skips then the index restarts", (): void => {
	const r = counter("c", 5)
		.drop(2)
		.map((x: int32, i: number): string => `${x}@${i}`)
		.toArray();
	log(`result ${r.join(",")}`);
});

section("flatMap early exit closes inner then outer", (): void => {
	const r = counter("o", 3)
		.flatMap((x: int32, i: number): Iterator<int32> => {
			log(`mapper ${x}@${i}`);
			return counter(`i${x}`, 3);
		})
		.take(2)
		.toArray();
	log(`result ${r.join(",")}`);
});

section("flatMap to the end closes nothing", (): void => {
	const r = counter("o", 2)
		.flatMap((x: int32, i: number): Iterator<int32> => counter(`j${x}`, 1))
		.toArray();
	log(`result ${r.join(",")}`);
});

section("some short-circuit closes", (): void => {
	const r = counter("s", 100).some((x: int32, i: number): boolean => {
		log(`cb ${x}@${i}`);
		return x == 2;
	});
	log(`some ${r}`);
});

section("some without a hit closes nothing", (): void => {
	log(`some ${counter("s", 2).some((x: int32, i: number): boolean => false)}`);
});

section("every short-circuit closes", (): void => {
	const r = counter("v", 100).every((x: int32, i: number): boolean => {
		log(`cb ${x}@${i}`);
		return x < 3;
	});
	log(`every ${r}`);
});

section("every without a miss closes nothing", (): void => {
	log(`every ${counter("v", 2).every((x: int32, i: number): boolean => true)}`);
});

section("find short-circuit closes", (): void => {
	const r = counter("f", 100).find((x: int32, i: number): boolean => {
		log(`cb ${x}@${i}`);
		return x == 3;
	});
	log(`find ${r == null ? "none" : `${r}`}`);
});

section("find without a hit closes nothing", (): void => {
	const r = counter("f", 2).find((x: int32, i: number): boolean => false);
	log(`find ${r == null ? "none" : `${r}`}`);
});

section("a throwing map callback closes the source", (): void => {
	counter("m", 100)
		.map((x: int32, i: number): int32 => {
			if (x == 2) throw new Error("boom");
			return x;
		})
		.toArray();
});

section("a throwing filter callback closes the source", (): void => {
	counter("m", 100)
		.filter((x: int32, i: number): boolean => {
			if (x == 2) throw new Error("boom");
			return true;
		})
		.toArray();
});

section("a throwing forEach callback closes the source", (): void => {
	counter("m", 100).forEach((x: int32, i: number): void => {
		if (x == 2) throw new Error("boom");
	});
});

section("a throwing reduce callback closes the source", (): void => {
	counter("m", 100).reduce((a: int32, x: int32, i: number): int32 => {
		if (x == 2) throw new Error("boom");
		return a + x;
	}, 0);
});

section("a throwing flatMap mapper closes the outer source", (): void => {
	counter("m", 100)
		.flatMap((x: int32, i: number): Iterator<int32> => {
			if (x == 2) throw new Error("boom");
			return counter(`i${x}`, 1);
		})
		.toArray();
});

section("a throwing some callback closes the source", (): void => {
	counter("m", 100).some((x: int32, i: number): boolean => {
		if (x == 2) throw new Error("boom");
		return false;
	});
});

section("a throwing source next is not closed", (): void => {
	failing("n")
		.map((x: int32, i: number): int32 => x)
		.toArray();
});

section("a finished source is not closed", (): void => {
	const r = counter("d", 2)
		.map((x: int32, i: number): int32 => x)
		.toArray();
	log(`result ${r.join(",")}`);
});

section("take negative fails before a pull and closes the receiver", (): void => {
	counter("e", 3).take(-1);
});

section("drop negative fails before a pull and closes the receiver", (): void => {
	counter("e", 3).drop(-1);
});

section("take NaN fails before a pull and closes the receiver", (): void => {
	counter("e", 3).take(NaN);
});

section("take truncates a fraction", (): void => {
	const r = counter("g", 5).take(1.7).toArray();
	log(`result ${r.join(",")}`);
});

section("take zero closes without a pull", (): void => {
	const r = counter("z", 5).take(0).toArray();
	log(`result ${r.length}`);
});

section("take infinity never closes a short source", (): void => {
	const r = counter("w", 3).take(Infinity).toArray();
	log(`result ${r.join(",")}`);
});

section("reduce with an initial value starts at index 0", (): void => {
	const r = counter("r", 3).reduce((a: int32, x: int32, i: number): int32 => {
		log(`cb ${a}+${x}@${i}`);
		return a + x;
	}, 10);
	log(`reduce ${r}`);
});

section("reduce without an initial value starts at index 1", (): void => {
	const r = counter("r", 3).reduce((a: int32, x: int32, i: number): int32 => {
		log(`cb ${a}+${x}@${i}`);
		return a + x;
	});
	log(`reduce ${r}`);
});

section("reduce of one element never calls back", (): void => {
	const r = counter("r", 1).reduce((a: int32, x: int32, i: number): int32 => {
		log("cb");
		return a + x;
	});
	log(`reduce ${r}`);
});

section("reduce of an empty source without an initial value fails", (): void => {
	counter("r", 0).reduce((a: int32, x: int32, i: number): int32 => a + x);
});

section("reduce of an empty source with an initial value returns it", (): void => {
	log(`reduce ${counter("r", 0).reduce((a: int32, x: int32, i: number): int32 => a + x, 7)}`);
});

section("forEach passes the index and finishes", (): void => {
	counter("h", 2).forEach((x: int32, i: number): void => log(`each ${x}@${i}`));
	log("forEach done");
});

section("a consumer break closes the chain", (): void => {
	for (const x of counter("k", 100).map((x: int32, i: number): int32 => x)) {
		log(`body ${x}`);
		if (x == 2) break;
	}
});

section("a consumer break over take closes before the limit", (): void => {
	for (const x of counter("k", 100).take(5)) {
		log(`body ${x}`);
		if (x == 2) break;
	}
});

section("a helper is single pass", (): void => {
	const h = counter("p", 2).map((x: int32, i: number): int32 => x);
	log(`first ${h.toArray().join(",")}`);
	log(`again ${h.toArray().length}`);
});

const expected: string[] = [
	"# map then filter then take interleave per element",
	"a.next",
	"map 1@0",
	"filter 10@0",
	"a.next",
	"map 2@1",
	"filter 20@1",
	"a.next",
	"map 3@2",
	"filter 30@2",
	"a.next",
	"map 4@3",
	"filter 40@3",
	"a.return",
	"result 20,40",
	"# take closes the source on the next pull",
	"built",
	"b.next",
	"pulled 1",
	"b.next",
	"pulled 2",
	"two pulled",
	"b.return",
	"pulled done",
	"pulled done",
	"# drop skips then the index restarts",
	"c.next",
	"c.next",
	"c.next",
	"c.next",
	"c.next",
	"c.next",
	"result 3@0,4@1,5@2",
	"# flatMap early exit closes inner then outer",
	"o.next",
	"mapper 1@0",
	"i1.next",
	"i1.next",
	"i1.return",
	"o.return",
	"result 1,2",
	"# flatMap to the end closes nothing",
	"o.next",
	"j1.next",
	"j1.next",
	"o.next",
	"j2.next",
	"j2.next",
	"o.next",
	"result 1,1",
	"# some short-circuit closes",
	"s.next",
	"cb 1@0",
	"s.next",
	"cb 2@1",
	"s.return",
	"some true",
	"# some without a hit closes nothing",
	"s.next",
	"s.next",
	"s.next",
	"some false",
	"# every short-circuit closes",
	"v.next",
	"cb 1@0",
	"v.next",
	"cb 2@1",
	"v.next",
	"cb 3@2",
	"v.return",
	"every false",
	"# every without a miss closes nothing",
	"v.next",
	"v.next",
	"v.next",
	"every true",
	"# find short-circuit closes",
	"f.next",
	"cb 1@0",
	"f.next",
	"cb 2@1",
	"f.next",
	"cb 3@2",
	"f.return",
	"find 3",
	"# find without a hit closes nothing",
	"f.next",
	"f.next",
	"f.next",
	"find none",
	"# a throwing map callback closes the source",
	"m.next",
	"m.next",
	"m.return",
	"threw boom",
	"# a throwing filter callback closes the source",
	"m.next",
	"m.next",
	"m.return",
	"threw boom",
	"# a throwing forEach callback closes the source",
	"m.next",
	"m.next",
	"m.return",
	"threw boom",
	"# a throwing reduce callback closes the source",
	"m.next",
	"m.next",
	"m.return",
	"threw boom",
	"# a throwing flatMap mapper closes the outer source",
	"m.next",
	"i1.next",
	"i1.next",
	"m.next",
	"m.return",
	"threw boom",
	"# a throwing some callback closes the source",
	"m.next",
	"m.next",
	"m.return",
	"threw boom",
	"# a throwing source next is not closed",
	"n.next",
	"n.next",
	"threw nx",
	"# a finished source is not closed",
	"d.next",
	"d.next",
	"d.next",
	"result 1,2",
	"# take negative fails before a pull and closes the receiver",
	"e.return",
	"threw -1 must be positive",
	"# drop negative fails before a pull and closes the receiver",
	"e.return",
	"threw -1 must be positive",
	"# take NaN fails before a pull and closes the receiver",
	"e.return",
	"threw NaN must be positive",
	"# take truncates a fraction",
	"g.next",
	"g.return",
	"result 1",
	"# take zero closes without a pull",
	"z.return",
	"result 0",
	"# take infinity never closes a short source",
	"w.next",
	"w.next",
	"w.next",
	"w.next",
	"result 1,2,3",
	"# reduce with an initial value starts at index 0",
	"r.next",
	"cb 10+1@0",
	"r.next",
	"cb 11+2@1",
	"r.next",
	"cb 13+3@2",
	"r.next",
	"reduce 16",
	"# reduce without an initial value starts at index 1",
	"r.next",
	"r.next",
	"cb 1+2@1",
	"r.next",
	"cb 3+3@2",
	"r.next",
	"reduce 6",
	"# reduce of one element never calls back",
	"r.next",
	"r.next",
	"reduce 1",
	"# reduce of an empty source without an initial value fails",
	"r.next",
	"threw Reduce of a done iterator with no initial value",
	"# reduce of an empty source with an initial value returns it",
	"r.next",
	"reduce 7",
	"# forEach passes the index and finishes",
	"h.next",
	"each 1@0",
	"h.next",
	"each 2@1",
	"h.next",
	"forEach done",
	"# a consumer break closes the chain",
	"k.next",
	"body 1",
	"k.next",
	"body 2",
	"k.return",
	"# a consumer break over take closes before the limit",
	"k.next",
	"body 1",
	"k.next",
	"body 2",
	"k.return",
	"# a helper is single pass",
	"p.next",
	"p.next",
	"p.next",
	"first 1,2",
	"again 0",
];
if (trace.length != expected.length) {
	throw new Error(`trace has ${trace.length} lines, expected ${expected.length}\n${trace.join("\n")}`);
}
for (let i = 0; i < expected.length; i += 1) {
	if (trace[i] != expected[i]) {
		throw new Error(`line ${i}: got "${trace[i]}", expected "${expected[i]}"`);
	}
}
console.log("ok");
