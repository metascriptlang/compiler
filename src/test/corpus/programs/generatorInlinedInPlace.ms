let trace: string = "";

function note(s: string): void {
	trace = trace + s + ";";
}

function* count(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i++) {
		yield i;
	}
}

function* guarded(tag: string, n: int32): Iterator<int32> {
	try {
		for (let i: int32 = 0; i < n; i++) {
			yield i;
		}
	} finally {
		note(tag + " fin");
	}
}

function* returnsMidway(limit: int32): Iterator<int32> {
	let i: int32 = 0;
	while (true) {
		if (i == limit) return;
		yield i;
		i = i + 1;
	}
}

function* countdown(n: int32): Iterator<int32> {
	while (n > 0) {
		yield n;
		n = n - 1;
	}
}

function* mapped(n: int32, f: (x: int32) => int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i++) {
		yield f(i);
	}
}

function* twice<T>(x: T): Iterator<T> {
	yield x;
	yield x;
}

function* pairs(): Iterator<[int32, string]> {
	yield [1, "one"];
	if (trace.length > 1000) return;
	yield [2, "two"];
}

function* branching(n: int32): Iterator<string> {
	for (let i: int32 = 0; i < n; i++) {
		if (i == 0) {
			yield "first";
		} else if (i == n - 1) {
			yield "last";
		} else {
			yield "mid" + i.toString();
		}
	}
}

function* catching(): Iterator<int32> {
	try {
		yield 1;
		yield 2;
	} catch (e) {
		note("generator caught");
	}
}

function* recursive(n: int32): Iterator<int32> {
	if (n > 0) {
		for (const x of recursive(n - 1)) {
			yield x;
		}
		yield n;
	}
}

function* tail(this xs: int32[], from: int32): Iterator<int32> {
	for (let i: int32 = from; i < xs.length; i++) {
		yield xs[i];
	}
}

function breakAt(limit: int32): void {
	for (const x of guarded("break", 10)) {
		if (x == limit) break;
		note("saw " + x.toString());
	}
	note("after break");
}

function returnFrom(limit: int32): int32 {
	for (const x of guarded("return", 10)) {
		if (x == limit) return x * 10;
	}
	return -1;
}

function throwFrom(limit: int32): void {
	try {
		for (const x of guarded("throw", 10)) {
			if (x == limit) throw new Error("boom " + x.toString());
		}
	} catch (e) {
		note("caught " + (e as Error).message);
	}
}

breakAt(2);
note("ret " + returnFrom(3).toString());
throwFrom(1);

for (const x of count(6)) {
	if (x % 2 == 0) continue;
	note("odd " + x.toString());
	if (x == 3) break;
}

for (const x of count(3)) {
	for (let j: int32 = 0; j < 5; j++) {
		if (j == 1) continue;
		if (j == 3) break;
		note("x" + x.toString() + "j" + j.toString());
	}
}

for (const x of count(4)) {
	switch (x) {
		case 1:
			break;
		default:
			note("switch " + x.toString());
	}
}

for (const x of returnsMidway(3)) {
	note("mid " + x.toString());
}
for (const x of guarded("whole", 2)) {
	note("whole " + x.toString());
}

for (const a of count(2)) {
	for (const b of count(3)) {
		if (b == 2) break;
		note("nest " + a.toString() + b.toString());
	}
}
for (const a of count(2)) {
	for (const b of guarded("inner", 3)) {
		if (a == 1 && b == 1) break;
		note("nest " + a.toString() + b.toString());
	}
}
for (const a of count(2)) {
	note("seq a" + a.toString());
}
for (const a of count(2)) {
	note("seq b" + a.toString());
}

let k: int32 = 3;
for (const x of countdown(k)) {
	k = 100;
	note("down " + x.toString());
}

for (const x of mapped(3, (v: int32): int32 => v * 10)) {
	note("mapped " + x.toString());
}
let offset: int32 = 5;
for (const x of mapped(2, (v: int32): int32 => v + offset)) {
	offset = offset + 1;
	note("closure " + x.toString());
}

for (const n of twice<int32>(7)) {
	note("int " + n.toString());
}
for (const s of twice<string>("ab")) {
	note("str " + s);
}

for (const [a, b] of pairs()) {
	note("pair " + a.toString() + b);
}
for (const s of branching(4)) {
	note(s);
}

const fns: (() => int32)[] = [];
for (const x of count(3)) {
	fns.push((): int32 => x * 100);
}
let held: string = "";
for (const f of fns) {
	held = held + f().toString() + ",";
}
note("held " + held);

const stored = count(4);
stored.next();
for (const x of stored) {
	note("resumed " + x.toString());
}

try {
	for (const x of catching()) {
		throw new Error("consumer " + x.toString());
	}
} catch (e) {
	note("caught " + (e as Error).message);
}

for (const x of recursive(3)) {
	note("rec " + x.toString());
}

const arr: int32[] = [10, 20, 30];
for (const x of arr.tail(1)) {
	note("tail " + x.toString());
}

const expected = "saw 0;saw 1;break fin;after break;return fin;ret 30;throw fin;caught boom 1;odd 1;odd 3;x0j0;x0j2;x1j0;x1j2;x2j0;x2j2;"
	+ "switch 0;switch 2;switch 3;mid 0;mid 1;mid 2;whole 0;whole 1;whole fin;nest 00;nest 01;nest 10;nest 11;nest 00;nest 01;nest 02;inner fin;"
	+ "nest 10;inner fin;seq a0;seq a1;seq b0;seq b1;down 3;down 2;down 1;mapped 0;mapped 10;mapped 20;closure 5;closure 7;int 7;int 7;str ab;str ab;"
	+ "pair 1one;pair 2two;first;mid1;mid2;last;held 0,100,200,;resumed 1;resumed 2;resumed 3;caught consumer 1;rec 1;rec 2;rec 3;tail 20;tail 30;";
console.log(trace);
if (trace != expected) throw new Error("trace differs from TS: " + expected);
