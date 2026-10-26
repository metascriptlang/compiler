import { consumedCount, count, firsts, tally, total } from "./gens";

let trace: string = "";
function note(s: string): void {
	trace = trace + s + ";";
}

let closed: int32 = 0;
function* quiet(n: int32): Iterator<int32> {
	try {
		for (let i: int32 = 0; i < n; i++) {
			yield i;
		}
	} finally {
		closed += 1;
	}
}

function mk(tag: string): (v: int32, i: number) => int32 {
	note(tag);
	return (v: int32, i: number): int32 => v + 1;
}

function logged(it: Iterator<int32>): Iterator<int32> {
	note("logged");
	return it.map(mk("inner"));
}

function anyBig(n: int32): boolean {
	return quiet(n).map((v: int32, i: number): int32 => v * 3).some((v: int32, i: number): boolean => v > 4);
}

function firstOdd(n: int32): int32 | null {
	const found = count(n).filter((v: int32, i: number): boolean => v % 2 == 1).find((v: int32, i: number): boolean => v > 2);
	return found;
}

function upTo(stop: int32): string {
	let seen: string = "";
	for (const x of count(5)) {
		if (x == stop) return seen;
		seen = seen + x.toString();
	}
	return seen + "!";
}

function stopEarly(): void {
	for (const x of count(5)) {
		if (x == 2) return;
		note("se" + x.toString());
	}
}

function run(): void {
	const r = count(10).map((v: int32, i: number): number => v * 2).reduce((acc: number, v: number, i: number): number => acc + v, 0);
	note("reduce " + r.toString());
	const s = count(5).sum();
	note("sum " + s.toString());
	const xs = count(4).map((v: int32, i: number): string => "x" + v.toString()).toArray();
	note("arr " + xs.join(","));
	note("some " + anyBig(4).toString() + " closed " + closed.toString());
	let every = false;
	every = count(3).every((v: int32, i: number): boolean => v < 3);
	note("every " + every.toString());
	note("find " + (firstOdd(8) ?? -1).toString());
	count(3).forEach((v: int32, i: number): void => { note("fe " + v.toString()); });

	for (const x of count(10).take(3)) note("t" + x.toString());
	const dropped = count(10).map((v: int32, i: number): int32 => v * 2).drop(7).sum();
	note("drop " + dropped.toString());
	for (const x of quiet(5).take(0)) note("never " + x.toString());
	note("closed " + closed.toString());
	for (const x of quiet(5).take(2)) note("q" + x.toString());
	note("closed " + closed.toString());
	try {
		for (const x of quiet(5).take(-1)) note("never " + x.toString());
	} catch (e) {
		note("caught " + (e as Error).message);
	}
	note("closed " + closed.toString());
	const parts = count(7).chunks(3).toArray();
	note("chunks " + parts.length.toString() + " " + parts[2].length.toString());
	for (const x of count(5).stepBy(2)) note("s" + x.toString());
	try {
		for (const x of count(5).stepBy(1.5)) note("never " + x.toString());
	} catch (e) {
		note("caught " + (e as Error).message);
	}
	const odd = (v: int32, i: number): boolean => v % 2 == 1;
	const sq = (v: int32, i: number): int32 => v * v;
	const t35 = count(20).filter(odd).take(3).map(sq).reduce((a: int32, v: int32, i: number): int32 => a + v, 0);
	note("total " + t35.toString());
	for (const x of logged(count(2)).map(mk("outer"))) note("l" + x.toString());
	for (const w of count(4).windows(2)) note("w" + w.join(""));
	const nested = count(3).map((v: int32, i: number): int32 => v + 1).map((v: int32, i: number): int32 => v * 10).sum();
	note("nested " + nested.toString());
	let acc: int32 = 5;
	acc += count(4).map((v: int32, i: number): int32 => {
		acc = 100;
		return v;
	}).sum();
	let words = "a";
	words += count(2).map((v: int32, i: number): string => "b" + v.toString()).reduce((s: string, v: string, i: number): string => s + v, "");
	note("compound " + acc.toString() + " " + words);

	note("up " + upTo(3) + " " + upTo(9));
	stopEarly();

	const fw = total(firsts(count(9), 3));
	note("fw " + fw.toString());
	try {
		const bad = total(firsts(quiet(4), -2));
		note("never " + bad.toString());
	} catch (e) {
		note("caught " + (e as Error).message);
	}
	note("closed " + closed.toString());
	const n = tally(count(4));
	note("tally " + n.toString() + " " + consumedCount().toString());
}
run();

const top = total(firsts(count(6), 4));
const topWords = count(3).map((v: int32, i: number): string => "m" + v.toString()).toArray();
note("top " + top.toString() + " " + topWords.join(","));

const expected = "reduce 90;sum 10;arr x0,x1,x2,x3;some true closed 1;every true;find 3;fe 0;fe 1;fe 2;"
	+ "t0;t1;t2;drop 48;closed 1;q0;q1;closed 2;caught -1 must be positive;closed 2;chunks 3 1;"
	+ "s0;s2;s4;caught step must be an integer;total 35;logged;inner;outer;l2;l3;w01;w12;w23;nested 60;compound 11 ab0b1;"
	+ "up 012 01234!;se0;se1;fw 3;caught negative -2;closed 2;tally 4 4;top 6 m0,m1,m2;";
console.log(trace);
if (trace != expected) throw new Error("trace differs from TS: " + expected);
