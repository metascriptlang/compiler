import { counting, evens, labelled, madeCount } from "./gens";

let trace: string = "";
function note(s: string): void {
	trace = trace + s + ";";
}

function* count(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i++) {
		yield i;
	}
}

let closed: int32 = 0;
function* quietClose(n: int32): Iterator<int32> {
	try {
		for (let i: int32 = 0; i < n; i++) {
			yield i;
		}
	} finally {
		closed += 1;
	}
}

function* raisingClose(n: int32): Iterator<int32> {
	try {
		for (let i: int32 = 0; i < n; i++) {
			yield i;
		}
	} finally {
		note("raising fin");
	}
}

let pulled: int32 = 0;
function* counted(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i++) {
		pulled += 1;
		yield i;
	}
}

function* twiceOver(it: Iterator<int32>): Iterator<int32> {
	for (const x of it) {
		yield x;
		yield x;
	}
}

function* peekFirst(it: Iterator<int32>): Iterator<int32> {
	const first = it.next();
	if (!first.done) yield first.value * 100;
	for (const x of it) {
		yield x;
	}
}

let order: string = "";
function arg(tag: string, n: int32): int32 {
	order = order + tag;
	return n;
}

let total: number = 0;
for (const x of count(10).map((v: int32, i: number): number => v * 2).filter((v: number, i: number): boolean => v > 4)) {
	total += x;
}
note("total " + total.toString());

for (const s of count(10).map((v: int32, i: number): string => "m" + i.toString())) {
	note(s);
	if (s == "m2") break;
}

for (const x of quietClose(5).map((v: int32, i: number): int32 => v + 100)) {
	if (x == 101) break;
	note("q " + x.toString());
}
note("closed " + closed.toString());

for (const x of raisingClose(5).map((v: int32, i: number): int32 => v + 200)) {
	if (x == 201) break;
	note("r " + x.toString());
}

for (const x of evens(6).map((v: int32, i: number): int32 => v * 10)) {
	note("e " + x.toString());
}

for (const s of count(3).labelled("n")) {
	note(s);
}
for (const s of evens(5).map((v: int32, i: number): number => v + 0.5).labelled("f")) {
	note(s);
}

for (const x of twiceOver(counted(3))) {
	note("tw " + x.toString());
	if (x == 1) break;
}
note("pulled " + pulled.toString());

for (const x of peekFirst(count(3))) {
	note("pk " + x.toString());
}

for (const x of count(arg("a", 2)).map((v: int32, i: number): number => v + arg("f", 0)).filter((v: number, i: number): boolean => arg("g", 1) > 0)) {
	order = order + "|";
}
note("order " + order);

try {
	for (const x of quietClose(4).map((v: int32, i: number): int32 => v)) {
		if (x == 2) throw new Error("consumer " + x.toString());
	}
} catch (e) {
	note("caught " + (e as Error).message);
}
note("closed " + closed.toString());

for (const x of counting(3)) {
	note("c " + x.toString());
}
note("made " + madeCount().toString());

const expected = "total 84;m0;m1;m2;q 100;closed 1;r 200;raising fin;e 0;e 20;e 40;n0;n1;n2;f0.5;f2.5;f4.5;"
	+ "tw 0;tw 0;tw 1;pulled 2;pk 0;pk 1;pk 2;order afg|fg|;caught consumer 2;closed 2;c 0;c 1;c 2;made 3;";
console.log(trace);
if (trace != expected) throw new Error("trace differs from TS: " + expected);
