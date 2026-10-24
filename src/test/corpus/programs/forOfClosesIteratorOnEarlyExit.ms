let trace: string = "";

function note(s: string): void {
	trace = trace + s + ";";
}

function* counting(tag: string): Iterator<int32> {
	try {
		let i: int32 = 0;
		while (true) {
			yield i;
			i = i + 1;
		}
	} finally {
		note(tag + " fin");
	}
}

function* deferred(tag: string): Iterator<int32> {
	defer note(tag + " defer");
	yield 1;
	yield 2;
}

function* finite(tag: string): Iterator<int32> {
	try {
		yield 1;
	} finally {
		note(tag + " fin");
	}
}

function* yieldInFinally(): Iterator<int32> {
	try {
		yield 1;
		yield 2;
	} finally {
		note("fin start");
		yield 99;
		note("fin end");
	}
}

function* nested(): Iterator<int32> {
	try {
		try {
			yield 1;
			yield 2;
		} finally {
			note("inner fin");
		}
	} finally {
		note("outer fin");
	}
}

function* doFirst(): Iterator<int32> {
	let i: int32 = 0;
	try {
		do {
			i = i + 1;
			yield i;
		} while (i < 5);
	} finally {
		note("do fin " + i.toString());
	}
}

function* inner(): Iterator<int32> {
	try {
		yield 10;
		yield 20;
		yield 30;
	} finally {
		note("inner gen fin");
	}
}

function* outer(): Iterator<int32> {
	try {
		for (const x of inner()) {
			yield x + 1;
		}
	} finally {
		note("outer gen fin");
	}
}

function* breaksInside(): Iterator<int32> {
	for (const x of counting("gen-break")) {
		if (x == 2) break;
		yield x;
	}
	yield 7;
}

function* failingFinally(): Iterator<int32> {
	try {
		yield 1;
	} finally {
		throw new Error("fin threw");
	}
}

function* pairs(): Iterator<[int32, int32]> {
	try {
		yield [1, 2];
		yield [3, 4];
	} finally {
		note("pairs fin");
	}
}

function counter(n: int32, closable: boolean): Iterator<int32> {
	let i: int32 = 0;
	if (!closable) {
		return { next: () => { i = i + 1; return { value: i, done: i > n }; } };
	}
	return {
		next: () => { i = i + 1; return { value: i, done: i > n }; },
		return: () => { note("close at " + i.toString()); return { value: 0, done: true }; },
	};
}

function viaReturn(): int32 {
	for (const x of counting("return")) {
		if (x == 1) return x;
	}
	return -1;
}

function handViaReturn(): int32 {
	for (const x of counter(9, true)) {
		if (x > 3) return x;
	}
	return -1;
}

for (const x of counting("break")) {
	if (x == 1) break;
}
note("ret " + viaReturn().toString());
try {
	for (const x of counting("throw")) {
		if (x == 1) throw new Error("boom");
	}
} catch (e) {
	note("caught " + (e as Error).message);
}
for (const x of counting("continue")) {
	if (x < 2) continue;
	note("continued to " + x.toString());
	break;
}
for (const x of deferred("defer")) {
	if (x == 1) break;
}
for (const x of finite("complete")) {
	note("got " + x.toString());
}
note("after complete");
for (const x of yieldInFinally()) {
	if (x == 1) break;
}
for (const x of nested()) {
	if (x == 2) break;
}
for (const x of doFirst()) {
	if (x == 3) break;
}
for (const x of outer()) {
	note("outer " + x.toString());
	if (x == 21) break;
}
for (const x of breaksInside()) {
	note("inside " + x.toString());
}
for (const [a, b] of pairs()) {
	note("pair " + (a + b).toString());
	break;
}
try {
	for (const x of failingFinally()) {
		break;
	}
} catch (e) {
	note("caught " + (e as Error).message);
}
try {
	for (const x of failingFinally()) {
		throw new Error("body threw");
	}
} catch (e) {
	note("caught " + (e as Error).message);
}
for (const x of counter(5, true)) {
	if (x == 2) break;
}
for (const x of counter(3, true)) {
	if (x == 2) continue;
	note("hand " + x.toString());
}
note("hand ret " + handViaReturn().toString());
try {
	for (const x of counter(5, true)) {
		if (x == 3) throw new Error("hand boom");
	}
} catch (e) {
	note("caught " + (e as Error).message);
}
for (const x of counter(5, false)) {
	if (x == 2) break;
}

const expected = "break fin;return fin;ret 1;throw fin;caught boom;continued to 2;continue fin;defer defer;got 1;complete fin;after complete;"
	+ "fin start;inner fin;outer fin;do fin 3;outer 11;outer 21;inner gen fin;outer gen fin;inside 0;inside 1;gen-break fin;inside 7;"
	+ "pair 3;pairs fin;caught fin threw;caught body threw;close at 2;hand 1;hand 3;close at 4;hand ret 4;close at 3;caught hand boom;";
console.log(trace);
if (trace != expected) throw new Error("trace differs from TS: " + expected);
