// @stdout: 3000 3000 250750 250750 2425
// note: a call that picks an overload signature runs the body with each argument converted to the body's parameter type, as a direct call to the body does: a record arm into a union parameter (sink and borrowed), a sized integer into a `number | string` parameter (sink and borrowed), and an argument of an extension method called through its signatures.
class Leaf { name: string = ""; constructor(n: string) { this.name = n; } }
type DA = { kind: "a", x: Leaf };
type DB = { kind: "b", y: Leaf[] };
type D = DA | DB;
class N { d: D; constructor(d: D) { this.d = d; } }

function mkSink(kind: "a", data: DA): N;
function mkSink(kind: "b", data: DB): N;
function mkSink(kind: string, sink data: D): N {
	return new N(data);
}

function mkBorrow(kind: "a", data: DA): N;
function mkBorrow(kind: "b", data: DB): N;
function mkBorrow(kind: string, data: D): N {
	return new N(data);
}

function buildA(i: number): DA { return { kind: "a", x: new Leaf("l" + i) }; }
function buildB(i: number): DB { return { kind: "b", y: [new Leaf("m" + i)] }; }

function halfSink(x: int32): number;
function halfSink(x: string): number;
function halfSink(sink x: number | string): number {
	if (typeof x == "string") return x.length / 2;
	return x / 2;
}

function halfBorrow(x: int32): number;
function halfBorrow(x: string): number;
function halfBorrow(x: number | string): number {
	if (typeof x == "string") return x.length / 2;
	return x / 2;
}

class Acc { total: number = 0; }
function put(this a: Acc, v: int32): void;
function put(this a: Acc, v: string): void;
function put(this a: Acc, v: number | string): void {
	if (typeof v == "string") a.total += v.length;
	else a.total += v;
}

let sinkTotal = 0;
let borrowTotal = 0;
for (let i = 0; i < 2000; i += 1) {
	const s = i % 2 == 0 ? mkSink("a", buildA(i)) : mkSink("b", buildB(i));
	sinkTotal += s.d.kind == "a" ? 1 : 2;
	const b = i % 2 == 0 ? mkBorrow("a", buildA(i)) : mkBorrow("b", buildB(i));
	borrowTotal += b.d.kind == "a" ? 1 : 2;
}

let hs: number = 0;
let hb: number = 0;
const acc = new Acc();
for (let i = 0; i < 1000; i += 1) {
	const k: int32 = i;
	hs += halfSink(k) + halfSink("ab");
	hb += halfBorrow(k) + halfBorrow("ab");
	if (i < 70) acc.put(k);
}
acc.put("abcdefghij");
console.log(`${sinkTotal} ${borrowTotal} ${hs} ${hb} ${acc.total}`);
